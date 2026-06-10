require "test_helper"
require "securerandom"

# =============================================================================
# MANUAL, OPT-IN live exploration of Xero's real Idempotency-Key behaviour.
# =============================================================================
#
# WHY THIS EXISTS
# ---------------
# Xero documents the idempotency feature only as "safely retry requests without
# the risk of duplicate processing" + a "128 character max". The *behavioural*
# specifics that xeroizer's batch design depends on are NOT published anywhere,
# in particular:
#   * what status/body you get when the SAME key is reused on a DIFFERENT request
#     (the gem assumes Xero rejects it — this is the load-bearing assumption);
#   * whether a 4xx validation error is cached against the key;
#   * how a partial-success batch (summarizeErrors=false) replays on retry;
#   * key scoping (per-app? per-tenant? per-endpoint?) and TTL.
#
# This test probes the REAL API so those assumptions can be confirmed now and
# re-checked years from now if idempotency issues resurface. It prints a report;
# where the correct behaviour is genuinely known (same request + same key must
# not create a duplicate) it also asserts the invariant, so a future change on
# Xero's side fails loudly.
#
# IT IS NOT PART OF THE NORMAL SUITE
# ----------------------------------
#   * The unit runner globs test/unit/** only, so it is never picked up there.
#   * Even under `rake test` / `rake test:acceptance` it OMITS unless you opt in
#     with XERO_LIVE_IDEMPOTENCY=1.
#
# IT MAKES REAL, DATA-CREATING CALLS — run it ONLY against a disposable / Demo
# Company tenant you control. It creates Contacts (and best-effort archives them
# in teardown). Contacts cannot be hard-deleted via the API, only archived.
#
# HOW TO RUN
# ----------
#   export XERO_CLIENT_ID=...      XERO_CLIENT_SECRET=...
#   export XERO_ACCESS_TOKEN=...   XERO_TENANT_ID=...      # current, unexpired
#   XERO_LIVE_IDEMPOTENCY=1 bundle exec ruby -I lib -I test \
#     test/acceptance/idempotency_exploration_test.rb
#
# STATUS: run against a live tenant on 2026-06-04 — all five automatable
# scenarios (1-5) passed. Confirmed:
#   * same key + identical request replays (HTTP 200, same id, no duplicate);
#   * a key is locked to its first body — reusing it with a different body (or a
#     corrected body after a 4xx) returns HTTP 400 and creates nothing;
#   * keys are scoped per-application and collide across endpoints;
#   * a single-request batch (summarizeErrors=false) partial success replays
#     correctly on an identical retry (the valid record is not duplicated).
# Xero's guide says a key is stored for only 6 MINUTES from the first call, after
# which a repeat is processed as NEW. THE 6-MINUTE CLAIM DID NOT HOLD LIVE: a full
# 2026-06-04 run measured the real lifetime at ~20 MINUTES (cached replay HTTP 200
# through t=19m, reprocessed 400 from t=20m), anchored to the first call — it did
# NOT reset on the 14 same-key retries in between, so the TTL is absolute, not
# sliding. Scenario 6 MEASURES this — it re-sends the same-key create once a
# minute from t=6m to t=30m and reports the first minute the cached 200 stops
# replaying (or that none did, which would mean the TTL is > 30 min). It is SLOW
# (~30 min) and behind a second flag, XERO_LIVE_IDEMPOTENCY_TTL=1:
#   XERO_LIVE_IDEMPOTENCY=1 XERO_LIVE_IDEMPOTENCY_TTL=1 bundle exec ruby \
#     -I lib -I test test/acceptance/idempotency_exploration_test.rb
# A Xero access token lasts only ~30 min, so for the full 30-min range also
# export XERO_REFRESH_TOKEN=... — the probe self-renews on a 401. Without it the
# probe stops cleanly when the token expires (reported, not failed).
# =============================================================================
class IdempotencyExplorationTest < Minitest::Test
  RUN_FLAG = "XERO_LIVE_IDEMPOTENCY".freeze
  # Scenario 6 (the TTL probe) runs ~30 minutes (one same-key retry per minute
  # from t=6m to t=30m), so it is behind its own opt-in flag and does not slow
  # the fast scenarios 1-5.
  TTL_FLAG = "XERO_LIVE_IDEMPOTENCY_TTL".freeze

  def setup
    skip "Set #{RUN_FLAG}=1 (and XERO_* creds) to run the live idempotency probe" unless ENV[RUN_FLAG] == "1"

    # Capture the raw HTTP status/headers/body of each request so we can observe
    # replay status codes and any replay-indicator header. #after_request is
    # read-only on the application, so the hook is passed at construction.
    @responses = []
    capture = lambda do |request_info, response|
      @responses << {
        method:  request_info.method,
        url:     request_info.url,
        code:    (response.respond_to?(:code) ? response.code : nil),
        headers: extract_headers(response),
        body:    (response.respond_to?(:plain_body) ? response.plain_body.to_s[0, 600] : nil)
      }
    end

    missing = %w[XERO_CLIENT_ID XERO_CLIENT_SECRET XERO_ACCESS_TOKEN XERO_TENANT_ID].reject { |v| ENV[v] }
    skip "Missing required env var(s): #{missing.join(', ')}" unless missing.empty?

    # A Xero access token lasts only ~30 min. The long TTL probe (scenario 6)
    # can run ~30 min, so it self-renews on a 401 IF a refresh token is supplied.
    # Optional for every other scenario.
    @refresh_token = ENV["XERO_REFRESH_TOKEN"].to_s
    @can_refresh   = !@refresh_token.empty?

    client_options = {
      access_token:  ENV["XERO_ACCESS_TOKEN"],
      tenant_id:     ENV["XERO_TENANT_ID"],
      after_request: capture
    }
    # Wiring refresh_token through enables OAuth2::AccessToken#refresh! (Xero
    # rotates the refresh token on use; the gem chains subsequent renewals off
    # the in-memory token, so one env seed is enough for a single run).
    client_options[:refresh_token] = @refresh_token if @can_refresh

    @client = Xeroizer::OAuth2Application.new(
      ENV["XERO_CLIENT_ID"], ENV["XERO_CLIENT_SECRET"], client_options
    )

    @run = "XEROIZER-IDEMP-#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(3)}"
    @created_contact_ids = []

    # Preflight: a Xero access token lasts ~30 min. If it has expired, every call
    # 401s and the scenarios would assert against garbage ("INVARIANT BROKEN"),
    # which is misleading. Detect that here and OMIT with a clear message so a
    # dead token reads as "skipped — refresh your token", not a real failure.
    begin
      @client.Organisation.first
    rescue => e
      if e.class.name =~ /TokenExpired|Unauthor/ || e.message.to_s =~ /token.?expired|unauthor|\b401\b/i
        skip "Live probe skipped: Xero auth failed (#{e.class}: #{e.message}). Refresh XERO_ACCESS_TOKEN and re-run."
      else
        raise
      end
    end
  end

  def teardown
    # Best-effort cleanup: archive every contact we created so reruns stay clean.
    return if @client.nil?
    @created_contact_ids.uniq.each do |id|
      begin
        c = @client.Contact.find(id)
        next unless c
        c.contact_status = "ARCHIVED" # the attribute is contact_status, not status
        c.save
      rescue => e
        puts "  [teardown] could not archive #{id}: #{e.class}: #{e.message}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 1 — same key + identical request => replay, no duplicate.
  # This is the one behaviour we DO expect; assert it so a regression on Xero's
  # side (or in the gem) fails loudly.
  # ---------------------------------------------------------------------------
  def test_1_same_request_same_key_replays_without_duplicate
    name = "#{@run}-S1"
    key  = "#{@run}-s1"

    banner "1. Same key + identical request (expect replay, exactly one record)"

    first = create_contact(name, key)
    track(first)
    report_last("first create")

    second = create_contact(name, key) # byte-identical retry, same key
    track(second)
    report_last("retry (same key)")

    matches = contacts_named(name)
    puts "  contacts found with name #{name.inspect}: #{matches.size}"
    puts "  first.id=#{id_of(first).inspect}  retry.id=#{id_of(second).inspect}"

    assert_equal 1, matches.size,
      "INVARIANT BROKEN: a same-key identical retry created #{matches.size} contacts (expected 1). " \
      "Xero idempotency may have changed, or the gem stopped sending the key."
    assert_equal id_of(first), id_of(second),
      "Retry returned a different id than the original — replay did not return the cached resource."
  end

  # ---------------------------------------------------------------------------
  # Scenario 2 — same key + DIFFERENT body. THE load-bearing unknown: the gem
  # requires a distinct key per distinct request because it assumes Xero rejects
  # a reused key on a different payload. Observe and report; do not assert a
  # guessed status, but do flag if Xero silently created the second record.
  # ---------------------------------------------------------------------------
  def test_2_same_key_different_body
    key   = "#{@run}-s2"
    name1 = "#{@run}-S2-A"
    name2 = "#{@run}-S2-B"

    banner "2. Same key + DIFFERENT body (probes the 'reused key rejected' assumption)"

    track(create_contact(name1, key)) # succeeds, key now used for body A
    report_last("create A")
    a_code = last_code

    track(create_contact(name2, key)) # same key, different body B (gem swallows a 4xx)
    report_last("create B (same key, different body)")
    b_code = last_code

    a_count = contacts_named(name1).size
    b_count = contacts_named(name2).size
    puts "  create A -> HTTP #{a_code} (count #{a_count}); create B reusing key -> HTTP #{b_code} (count #{b_count})"
    notify "Reused key on a DIFFERENT body: A HTTP #{a_code}, B HTTP #{b_code}; B created? #{b_count.positive?}"

    # CONFIRMED 2026-06 against the live API: B comes back 4xx and is NOT created,
    # i.e. Xero rejects a reused key on a different request — the assumption the
    # gem's multi-request design rests on. Assert the invariant so a future change
    # (Xero accepting key reuse on a new body) fails loudly here.
    assert_equal 0, b_count,
      "Reused key on a different body created a record (B count #{b_count}). Xero previously " \
      "rejected this (4xx); the gem's 'distinct request needs a distinct key' premise may no longer hold."
  end

  # ---------------------------------------------------------------------------
  # Scenario 3 — same key on a DIFFERENT endpoint. Probes whether key scope is
  # per-endpoint or per-app. Uses Contact then Account.
  # ---------------------------------------------------------------------------
  def test_3_same_key_different_endpoint
    contact_key = "#{@run}-s3c"
    fresh_key   = "#{@run}-s3a"

    banner "3. Same key on a different endpoint (probes per-endpoint vs per-app scope)"
    puts "  NOTE: this creates up to two Accounts that this harness does NOT clean up; archive them by hand."

    track(create_contact("#{@run}-S3", contact_key))
    contact_code = last_code

    # Baseline: a valid Account with its OWN fresh key. This tells us the Account
    # body is acceptable in THIS tenant, so a failure on the reused-key Account
    # below can be attributed to the key, not to an invalid Account.
    create_account("#{@run}-S3-ACCa", fresh_key)
    baseline_code = last_code

    # Same Account shape (new code), but reuse the CONTACT's key.
    create_account("#{@run}-S3-ACCb", contact_key)
    reuse_code = last_code

    puts "  Contact create -> HTTP #{contact_code}"
    puts "  Account (fresh key)         -> HTTP #{baseline_code}"
    puts "  Account (reused Contact key) -> HTTP #{reuse_code}"

    if baseline_code.to_i != 200
      notify "INCONCLUSIVE: baseline Account create failed (HTTP #{baseline_code}) — the Account body " \
             "is invalid in this tenant. Adjust create_account, then re-run, to test cross-endpoint scope."
    elsif reuse_code.to_i >= 400
      notify "Key scope is PER-APP (cross-endpoint): reusing a Contact's key for an Account was rejected " \
             "(HTTP #{reuse_code}) even though the Account itself is valid. Keys collide across endpoints."
    else
      notify "Cross-endpoint reuse was NOT rejected (baseline #{baseline_code}, reuse #{reuse_code}); the key " \
             "may be scoped per-endpoint."
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 4 — after a 4xx on a key, can that key be reused for a corrected
  # request? Practically this answers "must I rotate the key after a validation
  # failure?" — whether the cause is 4xx-caching or key-locking, the guidance is
  # the same. Uses a DUPLICATE contact name (Xero rejects it server-side, but it
  # passes the gem's client-side valid?, unlike a blank name which never sends).
  # ---------------------------------------------------------------------------
  def test_4_reuse_key_after_validation_error
    key = "#{@run}-s4"
    dup = "#{@run}-S4-dup"

    banner "4. Reuse a key after a 4xx (duplicate-name) — does a corrected body go through?"

    # Pre-create so a second create with the same name is a server-side dup error.
    track(create_contact(dup, "#{@run}-s4-seed"))

    track(create_contact(dup, key)) # duplicate body under key K => expect Xero 4xx
    invalid_code = last_code

    fixed = "#{@run}-S4-fixed"
    track(create_contact(fixed, key)) # corrected body, SAME key K
    corrected_code = last_code
    fixed_count = contacts_named(fixed).size

    puts "  duplicate create (key K) -> HTTP #{invalid_code}"
    puts "  corrected create (same key K) -> HTTP #{corrected_code}; '#{fixed}' count: #{fixed_count}"
    notify "Reuse-after-4xx: dup HTTP #{invalid_code}, corrected(same key) HTTP #{corrected_code}, fixed-count #{fixed_count}."
    notify "If corrected HTTP is 2xx and fixed-count is 1, the key can be reused after a 4xx. If corrected " \
           "is 4xx / fixed-count 0, the key is locked to the failure => rotate the key when retrying a " \
           "corrected body (see README caveats)."
  end

  # ---------------------------------------------------------------------------
  # Scenario 5 — batch partial-success replay (summarizeErrors=false). Send an
  # array with one valid + one invalid contact under a key; re-send identically.
  # Observe whether Xero replays the mixed body verbatim or reprocesses, and
  # whether the valid record gets duplicated. This is the highest-risk gap.
  # ---------------------------------------------------------------------------
  def test_5_batch_partial_success_replay
    ok_name  = "#{@run}-S5-ok"
    dup_name = "#{@run}-S5-dup"
    key      = "#{@run}-s5"

    banner "5. Batch partial-success replay under summarizeErrors=false"

    # Pre-create the contact the batch will duplicate. Both batch records have a
    # name, so they pass the gem's client-side valid? and the batch IS sent;
    # Xero then rejects only the duplicate, yielding a mixed 200 response. (A
    # blank name would fail valid? and abort the whole batch before any request.)
    track(create_contact(dup_name, "#{@run}-s5-seed"))

    # save_records sends summarizeErrors=false; [ok, dup] are both creates, so a
    # single PUT — a plain String key is valid. Fresh record objects each attempt
    # model a faithful retry of the identical batch.
    run_batch = lambda do
      ok  = @client.Contact.build(name: ok_name)
      dup = @client.Contact.build(name: dup_name)
      begin
        @client.Contact.save_records([ok, dup], 50, idempotency_key: key)
      rescue => e
        puts "  batch raised #{e.class}: #{e.message}"
      end
      [ok, dup]
    end

    ok1, dup1 = run_batch.call
    code1 = last_code
    puts "  attempt 1 -> HTTP #{code1}; ok.id=#{id_of(ok1).inspect}, ok.errors=#{ok1.errors.inspect}, dup.errors=#{dup1.errors.inspect}"

    ok2, _dup2 = run_batch.call # identical retry, same key
    code2 = last_code
    puts "  attempt 2 (same key) -> HTTP #{code2}; ok.id=#{id_of(ok2).inspect}"

    track_by_name(ok_name)
    count = contacts_named(ok_name).size
    puts "  contacts named #{ok_name.inspect}: #{count}"
    notify "Batch partial replay: attempt1 HTTP #{code1}, attempt2(same key) HTTP #{code2}, ok-count #{count} " \
           "(1 = replayed correctly; 2 = reprocessed => the valid record was duplicated)."
    assert_operator count, :<=, 1,
      "INVARIANT BROKEN: the valid record in a partial-success batch was created #{count} times on a same-key " \
      "retry — Xero did not replay the mixed response, so batch idempotency does not protect partial successes."
  end

  # ---------------------------------------------------------------------------
  # Scenario 6 — MEASURE the real key TTL (does not assume a value). Xero's guide
  # says a key is stored "6 minutes from the time of the first call", after which
  # a repeat is processed as NEW. A 2026-06-04 run CONTRADICTED that: the real
  # lifetime measured ~20 min (200 through t=19m, 400 from t=20m), absolute not
  # sliding. So this probe measures the lifetime instead of asserting it: it
  # creates a contact at t=0, then re-sends the IDENTICAL create
  # with the same key once a minute from t=6m through t=30m. While the key is
  # alive Xero replays the cached 200; once it expires the create is reprocessed,
  # the name already exists, and Xero returns a duplicate-name 4xx. The first
  # 200 -> 4xx minute is the observed TTL. If every probe stays 200 through
  # t=30m, the TTL is either > 30 min or SLIDING (reset on each access) — itself
  # a finding worth recording.
  #
  # SLOW (~30 min) and behind TTL_FLAG. A Xero access token lasts only ~30 min,
  # so the probe self-renews on a 401 IF XERO_REFRESH_TOKEN is set; without it a
  # mid-run token expiry ends the probe early (reported, not failed). Probes are
  # anchored to absolute wall-clock minutes from t=0 so per-request latency does
  # not drift the schedule. Self-cleaning: post-expiry creates are rejected
  # (4xx), so no duplicate accumulates.
  # ---------------------------------------------------------------------------
  def test_6_key_ttl_expiry
    skip "Set #{TTL_FLAG}=1 to run the ~30-minute TTL probe (in addition to #{RUN_FLAG}=1)" unless ENV[TTL_FLAG] == "1"

    name = "#{@run}-S6-ttl"
    key  = "#{@run}-s6"

    banner "6. key TTL (SLOW ~30 min): same-key create every minute, t=6m..t=30m, until it stops replaying"

    track(create_contact(name, key)) # first call: creates the contact AND caches key K at t=0
    t0 = Time.now
    puts "  t=0   first create -> HTTP #{last_code} (name created; key K caches this create)"

    c_immediate = ttl_probe("t=0   immediate retry", name, key)
    assert_equal 200, c_immediate,
      "Immediate same-key retry should replay the cached 200 — the TTL probe is meaningless otherwise."

    timeline    = {} # minute => HTTP code
    expired_at  = nil
    auth_died   = nil

    (6..30).each do |minute|
      sleep_until(t0 + minute * 60)
      code = ttl_probe("t=#{minute}m  retry", name, key)
      timeline[minute] = code

      if auth_failure?(code)
        auth_died = minute
        puts "  !! auth failed at t=#{minute}m and could not be refreshed — ending probe early."
        break
      end

      expired_at ||= minute if code != 200
    end

    curve = timeline.map { |m, c| "t#{m}=#{c}" }.join(" ")
    if auth_died
      notify "TTL probe ENDED EARLY at t=#{auth_died}m on an auth failure (access token expired and no usable " \
             "XERO_REFRESH_TOKEN). Partial curve: #{curve}. Set XERO_REFRESH_TOKEN and re-run for the full range."
    elsif expired_at
      notify "Observed key TTL ~= #{expired_at} min: the cached create replayed 200 through t=#{expired_at - 1}m and " \
             "was reprocessed (HTTP #{timeline[expired_at]}, duplicate name) at t=#{expired_at}m. Curve: #{curve}."
    else
      notify "NO expiry observed through t=30m — every same-key retry replayed 200. Xero's real TTL is either " \
             "> 30 min or SLIDING (reset on each access), which contradicts the documented '6 minutes from the " \
             "first call'. Curve: #{curve}."
    end
  end

  private

  def banner(title)
    puts "\n=== #{title} ==="
  end

  def create_contact(name, key)
    @client.Contact.create({ name: name }, idempotency_key: key)
  rescue => e
    # A Xero 4xx is usually swallowed (create returns a nil-id record); guard
    # against anything that does raise so a scenario can still report.
    puts "  [create_contact #{name.inspect}] #{e.class}: #{e.message}"
    nil
  end

  def create_account(name, key)
    @client.Account.create(
      { code: "Z#{rand(100_000)}", name: name, type: "EXPENSE" },
      idempotency_key: key
    )
  rescue => e
    puts "  [create_account #{name.inspect}] #{e.class}: #{e.message}"
    nil
  end

  # HTTP status code of the most recent request (captured via after_request),
  # so scenarios can observe a 4xx even when the gem swallows it.
  def last_code
    @responses.last && @responses.last[:code]
  end

  # Sleep until an absolute wall-clock Time, printing a ~30s heartbeat so a long
  # wait visibly progresses rather than looking hung. Anchoring probes to a fixed
  # target (rather than relative naps) keeps the t=Nm schedule from drifting as
  # per-request latency accumulates. No-op if the target has already passed.
  def sleep_until(target)
    return if Time.now >= target
    puts "  …sleeping until #{target.strftime('%H:%M:%S')} (#{(target - Time.now).ceil}s)"
    while (remaining = target - Time.now) > 0
      sleep [30, remaining].min
      left = (target - Time.now).ceil
      puts "    …#{Time.now.strftime('%H:%M:%S')} (#{[left, 0].max}s left)" if left > 0
    end
  end

  # Send the IDENTICAL create with the same key and return the HTTP status the
  # after_request hook saw (a 4xx is swallowed by create, so read it via
  # last_code). On a 401 — the ~30-min access token expiring mid-probe — try to
  # renew once via XERO_REFRESH_TOKEN and re-send, so a ~30-min probe can outlive
  # a single token. Returns the final status code (Integer, 0 if none captured).
  def ttl_probe(label, name, key)
    create_contact(name, key)
    code = last_code.to_i

    if auth_failure?(code) && refresh_auth!
      create_contact(name, key)
      code = last_code.to_i
      puts "  #{label} -> HTTP #{code} (after token refresh)"
      return code
    end

    state = if auth_failure?(code) then "AUTH FAIL #{code} (token expired; set XERO_REFRESH_TOKEN to self-renew)"
            elsif code == 200       then "replayed (key ALIVE)"
            else                         "reprocessed -> #{code} (key EXPIRED)"
            end
    puts "  #{label} -> HTTP #{code} (#{state})"
    code
  end

  def auth_failure?(code)
    code == 401 || code == 403
  end

  # Renew the access token mid-run via the configured refresh token. Xero rotates
  # refresh tokens on use; the gem chains subsequent renewals off the in-memory
  # token, so one env seed covers a single run. No-op (returns false) without a
  # refresh token or if renewal fails.
  def refresh_auth!
    return false unless @can_refresh
    @client.renew_access_token
    puts "  …access token renewed via XERO_REFRESH_TOKEN"
    true
  rescue => e
    puts "  …token refresh failed: #{e.class}: #{e.message}"
    false
  end

  def contacts_named(name)
    @client.Contact.all(where: %{Name=="#{name}"}) || []
  rescue => e
    puts "  [query] contacts_named(#{name.inspect}) failed: #{e.class}: #{e.message}"
    []
  end

  def id_of(record)
    record.respond_to?(:id) ? record.id : nil
  end

  def track(record)
    id = id_of(record)
    @created_contact_ids << id if id
  end

  def track_by_name(name)
    contacts_named(name).each { |c| @created_contact_ids << c.id if c.respond_to?(:id) && c.id }
  end

  def report_last(label)
    r = @responses.last
    return puts("  [#{label}] no response captured") unless r
    puts "  [#{label}] #{r[:method].to_s.upcase} -> HTTP #{r[:code]}"
    replay = r[:headers] && r[:headers].find { |k, _| k.to_s.downcase.include?("idempot") }
    puts "    replay header: #{replay.inspect}" if replay
  end

  def extract_headers(response)
    if response.respond_to?(:headers)
      response.headers
    elsif response.respond_to?(:response) && response.response.respond_to?(:headers)
      response.response.headers
    end
  rescue
    nil
  end
end
