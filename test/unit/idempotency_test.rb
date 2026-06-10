# frozen_string_literal: true

require 'unit_test_helper'

# Tests for Idempotency-Key support.
#
# Xero honours an `Idempotency-Key` request header on mutating requests so that
# a retried request (e.g. after a transient network failure) is not processed
# twice. See:
# https://developer.xero.com/documentation/guides/idempotent-requests/idempotency/
class IdempotencyTest < UnitTestCase
  include TestHelper

  OK_RESPONSE = '<Response><Status>OK</Status></Response>'

  def setup
    super
    @uri = 'https://api.xero.com/path'
    # Application with credentials for end-to-end WebMock tests (real headers).
    @application = Xeroizer::OAuth2Application.new(
      CLIENT_ID, CLIENT_SECRET, tenant_id: TENANT_ID, access_token: ACCESS_TOKEN
    )
  end

  # --------------------------------------------------------------------------
  # Core HTTP layer: the Idempotency-Key header is set from :idempotency_key.
  # --------------------------------------------------------------------------
  context 'HTTP layer' do
    should 'set the Idempotency-Key header on a POST' do
      stub_request(:post, @uri).to_return(status: 200, body: OK_RESPONSE)
      @application.http_post(@application.client, @uri, '<Body/>', idempotency_key: 'key-post')
      assert_requested(:post, @uri, headers: { 'Idempotency-Key' => 'key-post' })
    end

    should 'set the Idempotency-Key header on a PUT' do
      stub_request(:put, @uri).to_return(status: 200, body: OK_RESPONSE)
      @application.http_put(@application.client, @uri, '<Body/>', idempotency_key: 'key-put')
      assert_requested(:put, @uri, headers: { 'Idempotency-Key' => 'key-put' })
    end

    should 'omit the Idempotency-Key header on a GET even when explicitly given' do
      # Xero honours the key for POST/PUT/PATCH only, so we never set it on a GET.
      stub_request(:get, @uri).to_return(status: 200, body: OK_RESPONSE)
      @application.http_get(@application.client, @uri, idempotency_key: 'key-get')
      assert_requested(:get, @uri) { |req| !req.headers.key?('Idempotency-Key') }
    end

    should 'not serialize idempotency_key into the query string' do
      stub_request(:post, @uri).to_return(status: 200, body: OK_RESPONSE)
      @application.http_post(@application.client, @uri, '<Body/>', idempotency_key: 'key-qs')
      assert_requested(:post, @uri) { |req| !req.uri.to_s.include?('idempotency_key') }
    end

    should 'omit the header when no idempotency_key is given' do
      stub_request(:post, @uri).to_return(status: 200, body: OK_RESPONSE)
      @application.http_post(@application.client, @uri, '<Body/>')
      assert_requested(:post, @uri) { |req| !req.headers.key?('Idempotency-Key') }
    end

    should 'raise when idempotency_key is an empty string' do
      error = assert_raises(ArgumentError) do
        @application.http_post(@application.client, @uri, '<Body/>', idempotency_key: '')
      end
      assert_match(/must not be blank/, error.message)
    end

    should 'raise when idempotency_key is only whitespace' do
      error = assert_raises(ArgumentError) do
        @application.http_post(@application.client, @uri, '<Body/>', idempotency_key: '   ')
      end
      assert_match(/must not be blank/, error.message)
    end

    should 'raise when idempotency_key is not a String on a mutating request' do
      error = assert_raises(ArgumentError) do
        @application.http_post(@application.client, @uri, '<Body/>', idempotency_key: [1, 2])
      end
      assert_match(/must be a String/, error.message)
    end

    should "accept an idempotency_key of exactly 128 characters (Xero's limit)" do
      key = 'k' * 128
      stub_request(:post, @uri).to_return(status: 200, body: OK_RESPONSE)
      @application.http_post(@application.client, @uri, '<Body/>', idempotency_key: key)
      assert_requested(:post, @uri, headers: { 'Idempotency-Key' => key })
    end

    should 'raise when idempotency_key exceeds 128 characters' do
      key = 'k' * 129
      error = assert_raises(ArgumentError) do
        @application.http_post(@application.client, @uri, '<Body/>', idempotency_key: key)
      end
      assert_match(/at most 128 characters/, error.message)
    end

    should 'ignore a callable key on a GET, since the key is irrelevant there' do
      stub_request(:get, @uri).to_return(status: 200, body: OK_RESPONSE)
      @application.http_get(@application.client, @uri, idempotency_key: ->(_r, _m) { 'k' })
      assert_requested(:get, @uri) { |req| !req.headers.key?('Idempotency-Key') }
    end

    should 'reuse the same Idempotency-Key across an internal 429 retry' do
      application = Xeroizer::OAuth2Application.new(
        CLIENT_ID, CLIENT_SECRET,
        tenant_id: TENANT_ID, access_token: ACCESS_TOKEN, rate_limit_sleep: true
      )
      stub_request(:post, @uri).with(headers: { 'Idempotency-Key' => 'retry-key' }).to_return(
        status: 429, body: '', headers: { 'retry-after' => '1', 'x-daylimit-remaining' => '328' }
      ).then.to_return(status: 200, body: OK_RESPONSE)

      application.expects(:sleep_for).with(1)
      result = application.http_post(@application.client, @uri, '<Body/>', idempotency_key: 'retry-key')

      assert_equal OK_RESPONSE, result
      assert_requested(:post, @uri, headers: { 'Idempotency-Key' => 'retry-key' }, times: 2)
    end
  end

  # --------------------------------------------------------------------------
  # Record#save threads :idempotency_key down to the create/update request.
  # --------------------------------------------------------------------------
  context 'Record#save' do
    should 'thread idempotency_key into the create (PUT) request' do
      captured = nil
      @application.expects(:http_put).with do |_c, _u, _b, ep|
        captured = ep
        true
      end.returns(OK_RESPONSE)

      contact = @application.Contact.build(name: 'Idempotent Contact')
      contact.save(idempotency_key: 'contact-create-key')

      assert_equal 'contact-create-key', captured[:idempotency_key]
    end

    should 'thread idempotency_key into the update (POST) request' do
      captured = nil
      @application.expects(:http_post).with do |_c, _u, _b, ep|
        captured = ep
        true
      end.returns(OK_RESPONSE)

      contact = @application.Contact.build(
        contact_id: '00000000-0000-0000-0000-000000000001', name: 'Existing'
      )
      contact.save(idempotency_key: 'contact-update-key')

      assert_equal 'contact-update-key', captured[:idempotency_key]
    end

    should 'send no idempotency_key when none is given' do
      captured = nil
      @application.expects(:http_put).with do |_c, _u, _b, ep|
        captured = ep
        true
      end.returns(OK_RESPONSE)

      @application.Contact.build(name: 'No Key').save

      assert_nil captured[:idempotency_key]
    end

    should 'be passed through save! as well' do
      captured = nil
      @application.expects(:http_put).with do |_c, _u, _b, ep|
        captured = ep
        true
      end.returns(OK_RESPONSE)

      @application.Contact.build(name: 'Bang').save!(idempotency_key: 'bang-key')

      assert_equal 'bang-key', captured[:idempotency_key]
    end
  end

  # --------------------------------------------------------------------------
  # BaseModel#create (build + save) forwards :idempotency_key.
  # --------------------------------------------------------------------------
  context 'BaseModel#create' do
    should 'thread idempotency_key into the request' do
      captured = nil
      @application.expects(:http_put).with do |_c, _u, _b, ep|
        captured = ep
        true
      end.returns(OK_RESPONSE)

      @application.Contact.create({ name: 'Built' }, idempotency_key: 'create-key')

      assert_equal 'create-key', captured[:idempotency_key]
    end

    should 'accept attributes as bare keywords without an idempotency_key' do
      captured_attrs = nil
      @application.expects(:http_put).with do |_c, _u, body, _ep|
        captured_attrs = body
        true
      end.returns(OK_RESPONSE)

      @application.Contact.create(name: 'Acme Ltd', email_address: 'info@example.com')

      assert_match(/Acme Ltd/, captured_attrs)
    end

    should 'raise an actionable ArgumentError when idempotency_key is passed as a bare keyword' do
      @application.expects(:http_put).never

      error = assert_raises(ArgumentError) do
        @application.Contact.create(name: 'Acme', idempotency_key: 'k')
      end
      assert_match(/wrap the attributes in braces/, error.message)
    end

    should 'raise an actionable ArgumentError when idempotency_key is a String key in the attributes' do
      @application.expects(:http_put).never

      error = assert_raises(ArgumentError) do
        @application.Contact.create('name' => 'Acme', 'idempotency_key' => 'k')
      end
      assert_match(/wrap the attributes in braces/, error.message)
    end
  end

  # --------------------------------------------------------------------------
  # Batch saves: a key may be a String (single request) or a per-request
  # callable. A reused String across multiple requests is rejected up front.
  # --------------------------------------------------------------------------
  context 'BaseModel#save_records' do
    should 'apply a String key to a single-request batch' do
      captured = nil
      @application.expects(:http_put).with do |_c, _u, _b, ep|
        captured = ep
        true
      end.returns(OK_RESPONSE)

      records = [@application.Contact.build(name: 'A'), @application.Contact.build(name: 'B')]
      @application.Contact.save_records(records, 50, idempotency_key: 'batch-key')

      assert_equal 'batch-key', captured[:idempotency_key]
      assert_equal false, captured[:summarizeErrors]
    end

    should 'raise ArgumentError when a String key would span multiple requests' do
      records = [@application.Contact.build(name: 'A'), @application.Contact.build(name: 'B')]

      error = assert_raises(ArgumentError) do
        @application.Contact.save_records(records, 1, idempotency_key: 'static-key')
      end
      assert_match(/unique key per request/, error.message)
    end

    should 'not send any request when the static-key guard trips' do
      @application.expects(:http_put).never
      @application.expects(:http_post).never

      records = [@application.Contact.build(name: 'A'), @application.Contact.build(name: 'B')]
      assert_raises(ArgumentError) do
        @application.Contact.save_records(records, 1, idempotency_key: 'static-key')
      end
    end

    should 'invoke a callable with (records, http_method) to produce a key per request' do
      keys = []
      @application.expects(:http_put).twice.with do |_c, _u, _b, ep|
        keys << ep[:idempotency_key]
        true
      end.returns(OK_RESPONSE)

      records = [@application.Contact.build(name: 'A'), @application.Contact.build(name: 'B')]
      @application.Contact.save_records(records, 1, idempotency_key: ->(recs, _method) { "key-#{recs.map { |r| r.attributes[:name] }.join}" })

      assert_equal %w[key-A key-B], keys
    end

    should 'leave the request untouched when no key is given' do
      captured = nil
      @application.expects(:http_put).with do |_c, _u, _b, ep|
        captured = ep
        true
      end.returns(OK_RESPONSE)

      records = [@application.Contact.build(name: 'A')]
      @application.Contact.save_records(records)

      assert_nil captured[:idempotency_key]
      assert_equal false, captured[:summarizeErrors]
    end

    # An invalid chunk_size must raise up front, before any request is built or sent.
    should 'raise ArgumentError when chunk_size is zero' do
      @application.expects(:http_put).never
      records = [@application.Contact.build(name: 'A')]
      error = assert_raises(ArgumentError) { @application.Contact.save_records(records, 0) }
      assert_match(/positive integer/, error.message)
    end

    should 'raise ArgumentError when chunk_size is negative' do
      records = [@application.Contact.build(name: 'A')]
      error = assert_raises(ArgumentError) { @application.Contact.save_records(records, -1) }
      assert_match(/positive integer/, error.message)
    end

    should 'raise ArgumentError when chunk_size is not an integer' do
      records = [@application.Contact.build(name: 'A')]
      error = assert_raises(ArgumentError) { @application.Contact.save_records(records, 1.5) }
      assert_match(/positive integer/, error.message)
    end
  end

  # --------------------------------------------------------------------------
  # Other discrete mutating write paths.
  # --------------------------------------------------------------------------
  context 'attachments' do
    should 'set Idempotency-Key on an attachment upload' do
      base_url = 'https://api.xero.com/api.xro/2.0/Invoices'
      stub_request(:put, %r{Attachments/file\.pdf}).to_return(status: 200, body: OK_RESPONSE)

      @application.Attachment.attach_data(
        base_url, 'INV-1', 'file.pdf', 'the-data', 'application/pdf', idempotency_key: 'att-key'
      )

      assert_requested(:put, %r{Attachments/file\.pdf}) { |req| req.headers['Idempotency-Key'] == 'att-key' }
    end

    should 'set Idempotency-Key on a record-level attach_data with content_type omitted' do
      stub_request(:put, %r{Attachments/file\.pdf}).to_return(status: 200, body: OK_RESPONSE)

      invoice = @application.Invoice.build(invoice_id: '99999999-9999-9999-9999-999999999999')
      invoice.attach_data('file.pdf', 'the-data', idempotency_key: 'att-rec-key')

      assert_requested(:put, %r{Attachments/file\.pdf}) do |req|
        req.headers['Idempotency-Key'] == 'att-rec-key' &&
          # content_type kept its default; never set to a stringified Hash.
          req.headers['Content-Type'] == 'application/octet-stream'
      end
    end

    should 'set Idempotency-Key on an attach_file upload' do
      base_url = 'https://api.xero.com/api.xro/2.0/Invoices'
      stub_request(:put, %r{Attachments/file\.pdf}).to_return(status: 200, body: OK_RESPONSE)
      File.stubs(:read).with('/tmp/attachment-source.pdf').returns('the-data')

      @application.Attachment.attach_file(
        base_url, 'INV-1', 'file.pdf', '/tmp/attachment-source.pdf', 'application/pdf', idempotency_key: 'att-file-key'
      )

      assert_requested(:put, %r{Attachments/file\.pdf}) { |req| req.headers['Idempotency-Key'] == 'att-file-key' }
    end

    should 'accept a positional options hash with content_type (README form)' do
      stub_request(:put, %r{Attachments/file\.pdf}).to_return(status: 200, body: OK_RESPONSE)

      invoice = @application.Invoice.build(invoice_id: '12121212-1212-1212-1212-121212121212')
      invoice.attach_data('file.pdf', 'the-data', 'application/pdf', { include_online: true })

      assert_requested(:put, %r{Attachments/file\.pdf}) do |req|
        req.headers['Content-Type'] == 'application/pdf' && req.uri.to_s.include?('IncludeOnline=true')
      end
    end

    # The silent-corruption case: content_type omitted AND a positional options
    # hash given. The hash must shift into options, not bind to content_type
    # (which would set Content-Type to a stringified Hash and drop include_online).
    should 'not corrupt Content-Type when content_type is omitted with a positional options hash' do
      stub_request(:put, %r{Attachments/file\.pdf}).to_return(status: 200, body: OK_RESPONSE)

      invoice = @application.Invoice.build(invoice_id: '13131313-1313-1313-1313-131313131313')
      invoice.attach_data('file.pdf', 'the-data', { include_online: true })

      assert_requested(:put, %r{Attachments/file\.pdf}) do |req|
        req.headers['Content-Type'] == 'application/octet-stream' && req.uri.to_s.include?('IncludeOnline=true')
      end
    end
  end

  context 'invoice email' do
    should 'set Idempotency-Key when emailing an invoice' do
      invoice = @application.Invoice.build(invoice_id: '11111111-1111-1111-1111-111111111111')
      email_url = 'https://api.xero.com/api.xro/2.0/Invoices/11111111-1111-1111-1111-111111111111/Email'
      stub_request(:post, email_url).to_return(status: 200, body: '')

      invoice.email(idempotency_key: 'email-key')

      assert_requested(:post, email_url, headers: { 'Idempotency-Key' => 'email-key' })
    end
  end

  # void!/approve!/delete! all route through the protected change_status! -> save,
  # so threading the key through one entry point exercises the shared plumbing.
  context 'invoice status changes' do
    should 'thread idempotency_key through void! into the status-change request' do
      invoice = @application.Invoice.build(invoice_id: '44444444-4444-4444-4444-444444444444')
      invoice.stubs(:payments).returns([])
      invoice.stubs(:valid?).returns(true)
      captured = nil
      @application.expects(:http_post).with do |_c, _u, _b, ep|
        captured = ep
        true
      end.returns(OK_RESPONSE)

      invoice.void!(idempotency_key: 'void-key')

      assert_equal 'void-key', captured[:idempotency_key]
    end

    should 'thread idempotency_key through approve! into the status-change request' do
      invoice = @application.Invoice.build(invoice_id: '55555555-5555-5555-5555-555555555555')
      invoice.stubs(:payments).returns([])
      invoice.stubs(:valid?).returns(true)
      captured = nil
      @application.expects(:http_post).with do |_c, _u, _b, ep|
        captured = ep
        true
      end.returns(OK_RESPONSE)

      invoice.approve!(idempotency_key: 'approve-key')

      assert_equal 'approve-key', captured[:idempotency_key]
    end

    should 'thread idempotency_key through delete! into the status-change request' do
      invoice = @application.Invoice.build(invoice_id: '77777777-7777-7777-7777-777777777777')
      invoice.stubs(:payments).returns([])
      invoice.stubs(:valid?).returns(true)
      captured = nil
      @application.expects(:http_post).with do |_c, _u, _b, ep|
        captured = ep
        true
      end.returns(OK_RESPONSE)

      invoice.delete!(idempotency_key: 'delete-key')

      assert_equal 'delete-key', captured[:idempotency_key]
    end

    should 'still delete! with no arguments (regression)' do
      invoice = @application.Invoice.build(invoice_id: '88888888-8888-8888-8888-888888888888')
      invoice.stubs(:payments).returns([])
      invoice.stubs(:valid?).returns(true)
      @application.expects(:http_post).with { |_c, _u, _b, _ep| true }.returns(OK_RESPONSE)

      invoice.delete!
    end

    should 'still change status with no arguments (regression)' do
      invoice = @application.Invoice.build(invoice_id: '66666666-6666-6666-6666-666666666666')
      invoice.stubs(:payments).returns([])
      invoice.stubs(:valid?).returns(true)
      @application.expects(:http_post).with { |_c, _u, _b, _ep| true }.returns(OK_RESPONSE)

      invoice.void!
    end
  end

  context 'history notes' do
    should 'set Idempotency-Key when adding a history note' do
      base_url = 'https://api.xero.com/api.xro/2.0/Invoices'
      stub_request(:put, %r{Invoices/INV-1/history}).to_return(status: 200, body: OK_RESPONSE)

      @application.HistoryRecord.add_note(base_url, 'INV-1', 'a note', idempotency_key: 'hist-key')

      assert_requested(:put, %r{Invoices/INV-1/history}) { |req| req.headers['Idempotency-Key'] == 'hist-key' }
    end
  end

  context 'branding theme payment services' do
    should 'set Idempotency-Key when adding a payment service' do
      ps_url = 'https://api.xero.com/api.xro/2.0/BrandingThemes/BT-1/PaymentServices'
      stub_request(:post, ps_url).to_return(status: 200, body: OK_RESPONSE)

      @application.BrandingTheme.add_payment_service(
        id: 'BT-1', payment_service_id: 'PS-1', idempotency_key: 'ps-key'
      )

      assert_requested(:post, ps_url, headers: { 'Idempotency-Key' => 'ps-key' })
    end

    should 'forward Idempotency-Key from a record-level add_payment_service' do
      ps_url = 'https://api.xero.com/api.xro/2.0/BrandingThemes/BT-2/PaymentServices'
      stub_request(:post, ps_url).to_return(status: 200, body: OK_RESPONSE)

      theme = @application.BrandingTheme.build(branding_theme_id: 'BT-2')
      theme.add_payment_service('PS-2', idempotency_key: 'ps-rec-key')

      assert_requested(:post, ps_url, headers: { 'Idempotency-Key' => 'ps-rec-key' })
    end
  end

  context 'credit note allocations' do
    should 'thread idempotency_key into an allocation request' do
      captured = nil
      @application.expects(:http_put).with do |_c, _u, _b, ep|
        captured = ep
        true
      end.returns(OK_RESPONSE)

      credit_note = @application.CreditNote.build(credit_note_id: '00000000-0000-0000-0000-0000000000cn')
      credit_note.allocate(idempotency_key: 'alloc-key')

      assert_equal 'alloc-key', captured[:idempotency_key]
    end
  end

  # --------------------------------------------------------------------------
  # The caller's options hash must not be mutated (so it can be reused on retry).
  # --------------------------------------------------------------------------
  context 'options hash hygiene' do
    should "not mutate the caller's options hash across saves" do
      stub_request(:put, /api\.xero\.com/).to_return(status: 200, body: OK_RESPONSE)

      opts = { idempotency_key: 'reused-key' }
      @application.Contact.build(name: 'First').save(opts)
      @application.Contact.build(name: 'Second').save(opts)

      assert_equal({ idempotency_key: 'reused-key' }, opts)
      assert_requested(:put, /api\.xero\.com/, headers: { 'Idempotency-Key' => 'reused-key' }, times: 2)
    end
  end

  # --------------------------------------------------------------------------
  # save_records: keyword arg, mixed create/update fan-out, key-generator guards.
  # --------------------------------------------------------------------------
  context 'BaseModel#save_records (additional)' do
    should 'accept idempotency_key without an explicit chunk_size' do
      captured = nil
      @application.expects(:http_put).with do |_c, _u, _b, ep|
        captured = ep
        true
      end.returns(OK_RESPONSE)

      @application.Contact.save_records([@application.Contact.build(name: 'A')], idempotency_key: 'short-key')

      assert_equal 'short-key', captured[:idempotency_key]
    end

    should 'pass (records, http_method) to the generator across create (PUT) and update (POST) groups' do
      calls = []
      @application.expects(:http_put).with do |_c, _u, _b, ep|
        calls << [:put, ep[:idempotency_key]]
        true
      end.returns(OK_RESPONSE)
      @application.expects(:http_post).with do |_c, _u, _b, ep|
        calls << [:post, ep[:idempotency_key]]
        true
      end.returns(OK_RESPONSE)

      new_contact = @application.Contact.build(name: 'New')
      existing_contact = @application.Contact.build(contact_id: '00000000-0000-0000-0000-0000000000ec', name: 'Existing')
      gen = ->(recs, http_method) { "k-#{http_method}-#{recs.map { |r| r.attributes[:name] }.join}" }
      @application.Contact.save_records([new_contact, existing_contact], 50, idempotency_key: gen)

      # The new record's create (PUT) and the existing record's update (POST) each
      # get a key derived from the record + verb in that request.
      assert_equal [[:put, 'k-http_put-New'], [:post, 'k-http_post-Existing']], calls
    end

    should 'reject a String key for a mixed create+update batch without sending anything' do
      @application.expects(:http_put).never
      @application.expects(:http_post).never

      new_contact = @application.Contact.build(name: 'New')
      existing_contact = @application.Contact.build(contact_id: '00000000-0000-0000-0000-0000000000ec', name: 'Existing')
      assert_raises(ArgumentError) do
        @application.Contact.save_records([new_contact, existing_contact], 50, idempotency_key: 'static')
      end
    end

    should 'raise without sending when the key generator returns a blank key' do
      @application.expects(:http_put).never

      records = [@application.Contact.build(name: 'A'), @application.Contact.build(name: 'B')]
      error = assert_raises(ArgumentError) do
        @application.Contact.save_records(records, 1, idempotency_key: ->(recs, _method) { recs.first.attributes[:name] == 'B' ? ' ' : 'k0' })
      end
      assert_match(/must not be blank/, error.message)
    end

    should 'raise without sending when the key generator returns duplicate keys' do
      @application.expects(:http_put).never

      records = [@application.Contact.build(name: 'A'), @application.Contact.build(name: 'B')]
      error = assert_raises(ArgumentError) do
        @application.Contact.save_records(records, 1, idempotency_key: ->(_recs, _method) { 'dup' })
      end
      assert_match(/duplicate keys/, error.message)
    end

    should 'raise without sending when a single-request String key is whitespace-only' do
      @application.expects(:http_put).never

      records = [@application.Contact.build(name: 'A')]
      error = assert_raises(ArgumentError) do
        @application.Contact.save_records(records, 50, idempotency_key: '   ')
      end
      assert_match(/must not be blank/, error.message)
    end

    should 'support a zero-argument key generator' do
      keys = []
      counter = 0
      @application.expects(:http_put).twice.with do |_c, _u, _b, ep|
        keys << ep[:idempotency_key]
        true
      end.returns(OK_RESPONSE)

      records = [@application.Contact.build(name: 'A'), @application.Contact.build(name: 'B')]
      @application.Contact.save_records(records, 1, idempotency_key: lambda {
        counter += 1
        "uuid-#{counter}"
      })

      assert_equal %w[uuid-1 uuid-2], keys
    end

    should 'support a custom callable object (without #arity) as a key generator' do
      keys = []
      @application.expects(:http_put).twice.with do |_c, _u, _b, ep|
        keys << ep[:idempotency_key]
        true
      end.returns(OK_RESPONSE)

      generator = Object.new
      def generator.call(records, _http_method)
        "obj-#{records.map { |r| r.attributes[:name] }.join}"
      end

      records = [@application.Contact.build(name: 'A'), @application.Contact.build(name: 'B')]
      @application.Contact.save_records(records, 1, idempotency_key: generator)

      assert_equal %w[obj-A obj-B], keys
    end

    should 'support a one-argument (records-only) generator' do
      keys = []
      @application.expects(:http_put).twice.with do |_c, _u, _b, ep|
        keys << ep[:idempotency_key]
        true
      end.returns(OK_RESPONSE)

      records = [@application.Contact.build(name: 'A'), @application.Contact.build(name: 'B')]
      @application.Contact.save_records(records, 1, idempotency_key: ->(recs) { "r-#{recs.first.attributes[:name]}" })

      assert_equal %w[r-A r-B], keys
    end

    should 'raise a clear error (without sending) for a keyword-parameter generator' do
      @application.expects(:http_put).never

      records = [@application.Contact.build(name: 'A'), @application.Contact.build(name: 'B')]
      error = assert_raises(ArgumentError) do
        @application.Contact.save_records(records, 1, idempotency_key: ->(_recs, http_method:) { "k-#{http_method}" })
      end
      assert_match(/keyword parameters are not supported/, error.message)
    end

    should 'raise a clear error (without sending) for an optional-keyword-parameter generator' do
      @application.expects(:http_put).never

      records = [@application.Contact.build(name: 'A'), @application.Contact.build(name: 'B')]
      error = assert_raises(ArgumentError) do
        @application.Contact.save_records(records, 1, idempotency_key: ->(_recs, http_method: nil) { "k-#{http_method}" })
      end
      assert_match(/keyword parameters are not supported/, error.message)
    end

    should 'raise a clear error (without sending) for a generator requiring more than two positionals' do
      @application.expects(:http_put).never

      records = [@application.Contact.build(name: 'A'), @application.Contact.build(name: 'B')]
      error = assert_raises(ArgumentError) do
        @application.Contact.save_records(records, 1, idempotency_key: ->(_recs, _http_method, extra) { "k-#{extra}" })
      end
      assert_match(/at most two/, error.message)
    end

    should 'raise (without sending) when the key generator returns a key longer than 128 characters' do
      @application.expects(:http_put).never

      records = [@application.Contact.build(name: 'A'), @application.Contact.build(name: 'B')]
      error = assert_raises(ArgumentError) do
        @application.Contact.save_records(records, 1, idempotency_key: ->(_recs, _method) { 'k' * 200 })
      end
      assert_match(/at most 128 characters/, error.message)
    end

    should 'raise without sending when the key generator returns a non-String key' do
      @application.expects(:http_put).never

      records = [@application.Contact.build(name: 'A'), @application.Contact.build(name: 'B')]
      error = assert_raises(ArgumentError) do
        # A generator returning a numeric/Symbol key is rejected, same as a single request.
        @application.Contact.save_records(records, 1, idempotency_key: ->(_recs, _method) { 0 })
      end
      assert_match(/must be a String/, error.message)
    end

    should 'be a no-op (no request, no error) for an empty batch even when a key is given' do
      @application.expects(:http_put).never
      @application.expects(:http_post).never

      assert_equal true, @application.Contact.save_records([], 50, idempotency_key: 'k')

      # An empty batch must resolve to no keys, never a key that is resolved but
      # never sent (which would break "resolved non-blank ⇒ sent").
      assert_nil @application.Contact.send(:resolve_batch_idempotency_keys, 'k', [])
    end

    should 'support a generator with an optional positional argument (arity -1, not a splat)' do
      keys = []
      @application.expects(:http_put).twice.with do |_c, _u, _b, ep|
        keys << ep[:idempotency_key]
        true
      end.returns(OK_RESPONSE)

      records = [@application.Contact.build(name: 'A'), @application.Contact.build(name: 'B')]
      @application.Contact.save_records(records, 1, idempotency_key: ->(recs = nil) { "opt-#{recs.first.attributes[:name]}" })

      assert_equal %w[opt-A opt-B], keys
    end

    should 'support a splat (*args) generator that still receives records and http_method' do
      calls = []
      @application.expects(:http_put).with do |_c, _u, _b, ep|
        calls << [:put, ep[:idempotency_key]]
        true
      end.returns(OK_RESPONSE)
      @application.expects(:http_post).with do |_c, _u, _b, ep|
        calls << [:post, ep[:idempotency_key]]
        true
      end.returns(OK_RESPONSE)

      new_contact = @application.Contact.build(name: 'New')
      existing_contact = @application.Contact.build(contact_id: '00000000-0000-0000-0000-0000000000ec', name: 'Existing')
      gen = lambda { |*args|
        recs, http_method = args
        "splat-#{http_method}-#{recs.map { |r| r.attributes[:name] }.join}"
      }
      @application.Contact.save_records([new_contact, existing_contact], 50, idempotency_key: gen)

      assert_equal [[:put, 'splat-http_put-New'], [:post, 'splat-http_post-Existing']], calls
    end

    should "preserve an unsaved chunk's key on retry when the batch realigns identically" do
      gen = ->(recs, m) { "#{m}-#{recs.map { |r| r.attributes[:name] }.join}" }
      puts_keys = []
      posts_keys = []
      @application.stubs(:http_put).with do |_c, _u, _b, ep|
        puts_keys << ep[:idempotency_key]
        true
      end.returns(OK_RESPONSE)
      @application.stubs(:http_post).with do |_c, _u, _b, ep|
        posts_keys << ep[:idempotency_key]
        true
      end.returns(OK_RESPONSE)

      # Attempt 1: A,B,C,D all new, chunk 2 => PUT[A,B], PUT[C,D].
      @application.Contact.save_records(
        [@application.Contact.build(name: 'A'), @application.Contact.build(name: 'B'),
         @application.Contact.build(name: 'C'), @application.Contact.build(name: 'D')],
        2, idempotency_key: gen
      )

      # Retry after PUT[A,B] fully succeeded (A,B now have ids => updates) and
      # PUT[C,D] network-failed (C,D still new => one create chunk again).
      @application.Contact.save_records(
        [@application.Contact.build(contact_id: '00000000-0000-0000-0000-0000000000a1', name: 'A'),
         @application.Contact.build(contact_id: '00000000-0000-0000-0000-0000000000b2', name: 'B'),
         @application.Contact.build(name: 'C'), @application.Contact.build(name: 'D')],
        2, idempotency_key: gen
      )

      # The [C,D] create request carries the SAME key on both attempts, so Xero
      # replays its original response instead of creating C,D twice.
      assert_equal %w[http_put-AB http_put-CD http_put-CD], puts_keys
      assert_equal %w[http_post-AB], posts_keys
    end

    # KNOWN LIMITATION: batch idempotency is only reliable when a retry reconstructs
    # IDENTICAL requests. When a *responded* chunk has mixed per-record outcomes — A
    # saved, B rejected by Xero's own validation (so B stays a create) — B shifts the
    # chunk boundaries of the records behind it on retry, changing their keys. A later
    # chunk that network-failed after Xero processed it is then re-created under a key
    # Xero has never seen => duplicates. Avoiding this needs request-level retry
    # (preserve each request's records/verb/key), which the current batch API does
    # not expose.
    should "(known limitation) shift a later request's key when an earlier record's status changes, breaking dedupe" do
      gen = ->(recs, m) { "#{m}-#{recs.map { |r| r.attributes[:name] }.join}" }
      all_puts = []
      @application.stubs(:http_put).with do |_c, _u, _b, ep|
        all_puts << ep[:idempotency_key]
        true
      end.returns(OK_RESPONSE)
      @application.stubs(:http_post).returns(OK_RESPONSE)

      # Attempt 1: A,B,C,D all new, chunk 2 => PUT[A,B], PUT[C,D]. C rides in "CD".
      @application.Contact.save_records(
        [@application.Contact.build(name: 'A'), @application.Contact.build(name: 'B'),
         @application.Contact.build(name: 'C'), @application.Contact.build(name: 'D')],
        2, idempotency_key: gen
      )

      # Retry after a PARTIAL response on PUT[A,B]: A saved (update), B rejected
      # (still a create). Creates are now [B,C,D] => PUT[B,C], PUT[D].
      @application.Contact.save_records(
        [@application.Contact.build(contact_id: '00000000-0000-0000-0000-0000000000a1', name: 'A'),
         @application.Contact.build(name: 'B'), @application.Contact.build(name: 'C'), @application.Contact.build(name: 'D')],
        2, idempotency_key: gen
      )

      # C's create request was "http_put-CD" on attempt 1 but "http_put-BC" on
      # retry: the key it would need to dedupe against is gone.
      assert_equal %w[http_put-AB http_put-CD http_put-BC http_put-D], all_puts
    end
  end

  # --------------------------------------------------------------------------
  # Single-request paths only accept a String key, not a callable.
  # --------------------------------------------------------------------------
  context 'single-request callable guard' do
    should 'raise when a callable is passed to a single save' do
      contact = @application.Contact.build(name: 'X')
      error = assert_raises(ArgumentError) do
        contact.save!(idempotency_key: ->(i) { "k-#{i}" })
      end
      assert_match(/must be a string/, error.message)
    end

    # Argument misuse is a programmer error, not a save failure, so non-bang #save
    # raises ArgumentError too (it does not rescue it into a false return, which
    # would hide the bug).
    should 'raise (not return false) when a callable is passed to a non-bang save' do
      contact = @application.Contact.build(name: 'X')
      error = assert_raises(ArgumentError) do
        contact.save(idempotency_key: ->(i) { "k-#{i}" })
      end
      assert_match(/must be a string/, error.message)
    end

    should 'raise when a blank key is passed to a single save' do
      contact = @application.Contact.build(name: 'X')
      error = assert_raises(ArgumentError) do
        contact.save(idempotency_key: '   ')
      end
      assert_match(/must not be blank/, error.message)
    end

    should 'raise when a non-String key is passed to a single save' do
      contact = @application.Contact.build(name: 'X')
      error = assert_raises(ArgumentError) do
        contact.save(idempotency_key: 12_345)
      end
      assert_match(/must be a String/, error.message)
    end
  end

  # --------------------------------------------------------------------------
  # Compound-op overrides (CreditNote, ContactGroup) must still accept save args
  # and thread the key into the primary create/update (regression guard).
  # --------------------------------------------------------------------------
  context 'CreditNote#save override' do
    # CreditNote overrides save! (a compound create + allocate operation); these
    # guard that the override still accepts save's options and threads the key
    # into the credit-note create. valid? is stubbed to isolate the override from
    # CreditNote's own validation requirements (contact/line items).
    should 'thread idempotency_key into the credit note create' do
      captured = nil
      @application.expects(:http_put).with do |_c, _u, _b, ep|
        captured = ep
        true
      end.returns(OK_RESPONSE)

      credit_note = @application.CreditNote.build(type: 'ACCRECCREDIT')
      credit_note.stubs(:valid?).returns(true)
      credit_note.save(idempotency_key: 'cn-key')

      assert_equal 'cn-key', captured[:idempotency_key]
    end

    should 'still save with no arguments (regression)' do
      @application.expects(:http_put).with { |_c, _u, _b, _ep| true }.returns(OK_RESPONSE)
      credit_note = @application.CreditNote.build(type: 'ACCRECCREDIT')
      credit_note.stubs(:valid?).returns(true)
      credit_note.save
    end
  end

  context 'ContactGroup#save override' do
    should 'thread idempotency_key into the group create' do
      captured = nil
      @application.expects(:http_put).with do |_c, _u, _b, ep|
        captured = ep
        true
      end.returns(OK_RESPONSE)

      @application.ContactGroup.build(name: 'Group B').save(idempotency_key: 'cg-key')

      assert_equal 'cg-key', captured[:idempotency_key]
    end

    should 'still save with no arguments (regression)' do
      @application.expects(:http_put).with { |_c, _u, _b, _ep| true }.returns(OK_RESPONSE)
      @application.ContactGroup.build(name: 'Group A').save
    end
  end

  context 'history notes (record-level)' do
    should "forward idempotency_key from a record's #add_note" do
      invoice = @application.Invoice.build(invoice_id: '33333333-3333-3333-3333-333333333333')
      stub_request(:put, %r{Invoices/33333333-3333-3333-3333-333333333333/history}).to_return(status: 200, body: OK_RESPONSE)

      invoice.add_note('a note', idempotency_key: 'rec-hist-key')

      assert_requested(:put, %r{Invoices/33333333-3333-3333-3333-333333333333/history}) { |req| req.headers['Idempotency-Key'] == 'rec-hist-key' }
    end
  end

  # --------------------------------------------------------------------------
  # batch_save threads the key through to save_records (separate entry point).
  # --------------------------------------------------------------------------
  context 'BaseModel#batch_save' do
    should 'thread idempotency_key through to the underlying request' do
      captured = nil
      @application.expects(:http_put).with do |_c, _u, _b, ep|
        captured = ep
        true
      end.returns(OK_RESPONSE)

      @application.Contact.batch_save(50, idempotency_key: 'batch-save-key') do
        @application.Contact.build(name: 'Batched')
      end

      assert_equal 'batch-save-key', captured[:idempotency_key]
    end
  end

  # --------------------------------------------------------------------------
  # Compound ops derive a DISTINCT key for their secondary request from the
  # caller's key (a reused key on a different request is a 400), so the whole
  # operation is idempotent under a single caller-supplied key.
  # --------------------------------------------------------------------------
  context 'compound-op secondary request derives a distinct key' do
    should "send a derived '-contacts' Idempotency-Key on the ContactGroup membership PUT" do
      membership_put = %r{/ContactGroups/[^/]+/Contacts}
      stub_request(:put, membership_put).to_return(status: 200, body: OK_RESPONSE)

      group = @application.ContactGroup.build(contact_group_id: '00000000-0000-0000-0000-0000000000cg')
      group.add_contact(@application.Contact.build(contact_id: '11111111-1111-1111-1111-111111111111'))
      group.save(idempotency_key: 'cg-key')

      assert_requested(:put, membership_put, headers: { 'Idempotency-Key' => 'cg-key-contacts' })
    end

    should 'not send any Idempotency-Key on the membership PUT when no key is given' do
      membership_put = %r{/ContactGroups/[^/]+/Contacts}
      stub_request(:put, membership_put).to_return(status: 200, body: OK_RESPONSE)

      group = @application.ContactGroup.build(contact_group_id: '00000000-0000-0000-0000-0000000000cg')
      group.add_contact(@application.Contact.build(contact_id: '11111111-1111-1111-1111-111111111111'))
      group.save

      assert_requested(:put, membership_put) { |req| !req.headers.key?('Idempotency-Key') }
    end

    should 'raise (not send a Proc-derived key) when a callable is passed to a compound ContactGroup save' do
      @application.expects(:http_put).never

      group = @application.ContactGroup.build(contact_group_id: '00000000-0000-0000-0000-0000000000cg')
      group.add_contact(@application.Contact.build(contact_id: '11111111-1111-1111-1111-111111111111'))
      error = assert_raises(ArgumentError) { group.save!(idempotency_key: ->(i) { "k-#{i}" }) }
      assert_match(/must be a string/, error.message)
    end

    should 'raise (not send a malformed derived key) when a non-String key is passed to a compound save' do
      @application.expects(:http_put).never

      group = @application.ContactGroup.build(contact_group_id: '00000000-0000-0000-0000-0000000000cg')
      group.add_contact(@application.Contact.build(contact_id: '11111111-1111-1111-1111-111111111111'))
      error = assert_raises(ArgumentError) { group.save!(idempotency_key: [1, 2]) }
      assert_match(/must be a String/, error.message)
    end

    # A 128-char base key is valid on its own but overflows once "-contacts"/
    # "-allocate" is appended. The derived key is validated BEFORE the primary
    # request, so the whole compound save fails atomically — no request is sent.
    should 'fail a compound ContactGroup save up front (no request) when the derived key would exceed 128 chars' do
      @application.expects(:http_put).never

      group = @application.ContactGroup.build(contact_group_id: '00000000-0000-0000-0000-0000000000cg')
      group.add_contact(@application.Contact.build(contact_id: '11111111-1111-1111-1111-111111111111'))
      error = assert_raises(ArgumentError) { group.save!(idempotency_key: 'k' * 128) }
      assert_match(/128/, error.message)
    end

    should 'fail a compound CreditNote save up front (no primary request) when the derived key would exceed 128 chars' do
      @application.expects(:http_put).never

      credit_note = @application.CreditNote.build(type: 'ACCRECCREDIT')
      credit_note.complete_record_downloaded = true
      credit_note.stubs(:valid?).returns(true)
      credit_note.add_allocation(applied_amount: 10)
      error = assert_raises(ArgumentError) { credit_note.save!(idempotency_key: 'k' * 128) }
      assert_match(/128/, error.message)
    end

    should "send a derived '-allocate' key, distinct from the create key, on the CreditNote allocations PUT" do
      create_response = '<Response><Status>OK</Status><CreditNotes><CreditNote>' \
                        '<CreditNoteID>00000000-0000-0000-0000-0000000000cn</CreditNoteID></CreditNote></CreditNotes></Response>'
      calls = []
      @application.expects(:http_put).twice.with do |_c, url, _b, ep|
        calls << [url, ep[:idempotency_key]]
        true
      end.returns(create_response)

      credit_note = @application.CreditNote.build(type: 'ACCRECCREDIT')
      credit_note.complete_record_downloaded = true
      credit_note.stubs(:valid?).returns(true)
      credit_note.add_allocation(applied_amount: 10)
      credit_note.save(idempotency_key: 'cn-key')

      create_call   = calls.find { |url, _| !url.include?('Allocations') }
      allocate_call = calls.find { |url, _|  url.include?('Allocations') }
      assert_equal 'cn-key', create_call.last
      assert_equal 'cn-key-allocate', allocate_call.last
    end

    should 'not send any Idempotency-Key on the allocations PUT when no key is given' do
      create_response = '<Response><Status>OK</Status><CreditNotes><CreditNote>' \
                        '<CreditNoteID>00000000-0000-0000-0000-0000000000cn</CreditNoteID></CreditNote></CreditNotes></Response>'
      calls = []
      @application.expects(:http_put).twice.with do |_c, url, _b, ep|
        calls << [url, ep[:idempotency_key]]
        true
      end.returns(create_response)

      credit_note = @application.CreditNote.build(type: 'ACCRECCREDIT')
      credit_note.complete_record_downloaded = true
      credit_note.stubs(:valid?).returns(true)
      credit_note.add_allocation(applied_amount: 10)
      credit_note.save

      allocate_call = calls.find { |url, _| url.include?('Allocations') }
      assert_nil allocate_call.last
    end
  end
end
