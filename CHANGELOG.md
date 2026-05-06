# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

> These changes have been merged but not yet released, so the version they will
> ship in is not yet decided. Note that this section contains a **breaking
> change** (see below); under SemVer that implies the next release will be a new
> major version.

### Breaking

- 429 responses now raise `Xeroizer::OAuth::RateLimitExceeded` instead of the
  raw `OAuth2::Error` for consumers running the OAuth2 client with
  `raise_errors: true`. Update any rescue chains accordingly.
  Non-429 `OAuth2::Error`s are unaffected and still propagate unchanged.

### Added

- `company_number` attribute on Contact. (#559)
- `edition` attribute on Organisation. (#564)
- `batch_payment_id` attribute on Payment. (#568)

### Changed

- `LineItem#line_item_id` is now a guid, producing `LineItemID` in XML to match Xero's case-sensitive parsing. (#562)
- `rate_limit_sleep: true` now respects the `Retry-After` response header. (#569)
- `rate_limit_sleep` now also works under `raise_errors: true`.
- A numeric `rate_limit_sleep` is now clamped to a non-negative number.
  Fractional values are preserved (`2.5` sleeps 2.5 seconds). Negative values
  sleep 0 seconds rather than raising.
- Under `raise_errors: true`, the `before_request`/`after_request` and response
  logging hooks now fire for 429 responses (they previously could not, because
  the `oauth2` gem raised before xeroizer's response layer ran). This keeps
  observability consistent across both `raise_errors` modes.

### Fixed

- `#attributes=` now raises the same clear `undefined method` error as `.build` when given an invalid attribute name. (#570)
- Avoid an extra API call when accessing allocations from a credit note. (#554)
- A `raw_body: true` request body is now computed once before the retry loop, so
  a retried request re-sends the same raw body instead of falling back to the
  `xml=`-wrapped form, and `:raw_body` is no longer serialized into the request
  query string.

## 3.0.1

See the Git history for changes up to and including 3.0.1.
