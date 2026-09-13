# Changelog

## 0.5.0 - 2026-09-13

Authentication: an optional API-key gate for the runtime, off by default.
No new dependencies, no framework - a static key list checked in one
middleware, reusing every existing pattern (fail-fast config validation,
secret handling, error envelope, correlation id).

- New middleware `src/middleware/Authentication.ps1` (`API_AUTH_ENABLED`,
  `API_AUTH_KEYS`): when enabled, every request except `/health/live` and
  `/health/ready` must carry a valid `X-Api-Key` header, checked with a
  constant-time comparison against a comma-separated list of configured
  keys (supports rotation - old and new key both valid during a migration).
  Runs last in the pipeline, before any route, so an unauthenticated
  request never reaches a route handler - an unmatched path also answers
  `401`, not `404`, when auth is on
- Fails startup (fail-fast) if `API_AUTH_ENABLED=true` with no
  `API_AUTH_KEYS` configured - same posture as every other hardening
  setting. The key list itself is a secret and is never stored in the
  shared `AppConfig` state, same treatment as `API_CERT_PASSWORD`
  (`src/config/Config.ps1`)
- New stable error code `UNAUTHORIZED` (`401`, `category: "auth"`,
  `retryable: false`), documented alongside the existing error taxonomy
  (`docs/api.md`)
- Deliberate difference from every sibling middleware: rate limit/
  concurrency/shutdown all fail *open* on an internal error (worst case,
  one extra request served); authentication fails *closed* instead - an
  error while checking a key still returns `401`, so a bug here can never
  silently disable the gate
- Authorization (a separate slot, reserved but still not built) is
  unaffected: every capability today is equally `safe`/read-only, so there
  is nothing yet to differentiate between authenticated callers
- 27 new unit + integration tests (215 total, 212 passing + 3 pre-existing
  Windows-only skips on this non-Windows dev host); 0 PSScriptAnalyzer
  findings

## 0.4.0 - 2026-09-13

Runtime hardening and capability contract pass: audited the existing request
lifecycle and route/service/error contracts (all already correct - only
gaps in test coverage and documentation were closed), formalized the
capability contract every future capability must satisfy, and added a
second real capability end-to-end to prove the model generalizes. No new
architecture, no new dependencies.

- `docs/api.md` gains a "Capability contract" section: every `/api/v1/*`
  capability documents input, output, error contract, idempotency
  (`safe`/`idempotent`/`non-idempotent`), timeout (reuses the existing soft
  budget, no per-capability timeout/retry), correlation id (reuses the
  request's own), and testing (unit + integration) - `windows/services` is
  checked against it and gains the one thing it was missing: an explicit
  idempotency declaration (`safe`)
- New capability: `GET /api/v1/windows/processes` - lists OS processes via
  `Get-Process` (`src/services/Windows/Get-WindowsProcesses.ps1`, second
  route in `src/routes/v1/Windows.ps1`), same thin-route/transport-agnostic-
  service pattern as `windows/services`. Unlike `Get-Service`, `Get-Process`
  is cross-platform, so this endpoint's success path works on any host, not
  Windows-only - dedicated docs: `docs/capabilities/windows-processes.md`
- 13 new unit + integration tests (188 total, 185 passing + 3 pre-existing
  Windows-only skips on this non-Windows dev host); 0 PSScriptAnalyzer
  findings - the new capability's own unit/validation/success/not-found/
  correlation-id tests, plus one closing a request-lifecycle gap (two
  separate requests always get different correlation ids - no accidental
  state reuse across requests, the exact class of bug
  `docs/architecture.md`'s "Gotcha" note describes)
- Route/service boundary, error contract and request lifecycle were
  audited task-by-task against `docs/architecture.md`/`docs/api.md` and
  found already correct - no source changes were needed for those three,
  only the test/documentation gaps above

## 0.3.0 - 2026-09-13

Test-hardening pass on the existing runtime - no new capabilities, no
architectural changes; the existing thin-route/service pattern and test
structure are unchanged, only strengthened.

- Request log gains two fields that were previously incomplete: `clientIp`
  (`Get-ClientIp` was defined but never wired in) and `errorType` (mirrors
  the error `code` onto every non-2xx response's log line, set once in
  `Send-ApiError` so every error source gets it for free) - see
  `docs/logging.md`
- 12 new unit + integration tests (175 total, 172 passing + 3 pre-existing
  Windows-only skips on this non-Windows dev host); 0 PSScriptAnalyzer/
  InjectionHunter findings - closing gaps in the existing suite:
  config validation (`API_LOG_LEVEL`, `API_THREADS`), Windows-service
  dependency-failure and single-element shaping, validation edge cases
  (whitespace-only `name`), wrong-HTTP-method-on-a-real-route falling
  through to the coherent 404 (not a raw 405), error-response `Content-Type`,
  the `category`/`retryable` contract on both new and intentionally-omitting
  error sources, and client-supplied correlation id round-tripping through a
  business-error body
- `tests/integration/TestServer.ps1`'s `Start-TestServer` no longer polls the
  health endpoint for the full 20s timeout when the server process already
  exited (a fail-fast config error, docs/configuration.md) - it now notices
  the exited process and fails immediately, cutting each of the two
  "fail-fast" integration tests from ~20s to ~2.5s
- An OpenAPI contract (`docs/openapi.yaml`) was drafted and then deliberately
  dropped before release: with only one real business endpoint today, a
  second, hand-maintained source of truth for the contract wasn't earning
  its keep yet - `docs/api.md`'s prose contract plus the integration suite
  already cover it. Worth revisiting once there are several `/api/v1/<area>/*`
  endpoints across multiple integrations.

## 0.2.0 - 2026-09-12

P0 core hardening: robustness/security limits for the existing runtime, no
new capabilities, no architectural changes - see `docs/architecture.md`,
`docs/configuration.md`, `docs/api.md`, `docs/logging.md` for full detail.

- Request body size limit (`API_MAX_BODY_BYTES`, default 1MB, `413`) -
  overrides Pode's static `server.psd1` `BodySize` dynamically only when set,
  so the default startup path is unchanged
- Global in-flight concurrency limit (`API_MAX_IN_FLIGHT_REQUESTS`, default
  100, `503 OVERLOADED`) via a shared `SemaphoreSlim`, released in an endware
  that runs regardless of how a request finished
- In-process rate limiting (`API_RATE_LIMIT_ENABLED`/`_REQUESTS`/`_WINDOW_SECONDS`,
  disabled by default, `429` with `Retry-After`) - a single global fixed
  window, not per-client
- Soft request handler timeout (`API_REQUEST_TIMEOUT_SECONDS`, default 30) -
  logs `application.timeout` and marks the request-log entry
  (`timedOut: true`) for a handler that runs long; deliberately not a
  preemptive per-request cutoff (see `docs/configuration.md`)
- Fail-fast validation for all of the above plus `API_SHUTDOWN_TIMEOUT_SECONDS`:
  an invalid value aborts startup immediately with a clear message, instead of
  the discard-and-warn behavior existing `API_*` settings use
- Graceful shutdown: SIGTERM/SIGINT now stop new requests immediately
  (`503 SHUTTING_DOWN`), then wait up to `API_SHUTDOWN_TIMEOUT_SECONDS` for
  in-flight requests to finish before the process exits - previously an
  unhandled SIGTERM (e.g. `docker stop`) killed the process within a fraction
  of a second, with nothing flushed to the logs and any in-flight request cut
  off
- Error taxonomy: optional `category`/`retryable` fields, additive to the
  existing envelope, set on the new runtime-protection errors above plus the
  existing `422`/`500`
- Centralized log redaction (`Protect-AppLogData`): any log field whose key
  name looks like a credential (`Authorization`, `Password`, `Token`,
  `ApiKey`, `Secret`, `Credential`, `Cookie`) has its value replaced before
  `Write-AppLog`/`Write-AppErrorLog` write anything, recursively
- 72 new unit + integration tests (163 total, 160 passing + 3 pre-existing
  Windows-only skips on this non-Windows dev host); 0 PSScriptAnalyzer/
  InjectionHunter findings

## 0.1.0 - 2026-09-12

Initial version of OpsBridge.

- Pode-based HTTP runtime with centralized `API_*` configuration
- Correlation ID middleware (`X-Correlation-ID`)
- Security response headers middleware
- Structured JSON logging (Application / Request / Error streams), stdout by
  default, optional file destination
- Standardized JSON error contract (`code`, `message`, `correlationId`,
  optional `details`)
- `GET /health/live`, `GET /health/ready`
- `GET /api/v1/windows/services` - reference implementation of the
  route/service pattern
- Project layout: `src/` organized as one dedicated folder per concern
  (`config/`, `errors/`, `logging/`, `middleware/`, `routes/`, `services/`),
  `tests/unit/` and `tests/integration/` mirroring it 1:1
- 88 unit + integration tests (Pester 6) - integration tests start a real
  server process, assert the actual HTTP contract, and (for logging) read the
  structured log files back and verify their JSON schema and ISO-8601
  timestamp format; 0 PSScriptAnalyzer findings
- `name` query parameter on `/api/v1/windows/services` now has an upper
  length bound (422 `TOO_LONG`), matching the same fail-fast approach already
  used for the correlation id
- Optional HTTPS (`API_PROTOCOL=Https`), either a Pode-generated self-signed
  certificate (dev/test, `API_CERT_SELF_SIGNED=true`) or a real `.pfx`
  (`API_CERT_PATH`/`API_CERT_PASSWORD`); a missing/invalid certificate file
  fails startup immediately with a clear message, and `Strict-Transport-Security`
  is set only on actual HTTPS responses
- Optional InjectionHunter integration (`scripts/analyze.ps1`) alongside
  PSScriptAnalyzer, for injection-focused rules default PSScriptAnalyzer does
  not cover
- Dockerfile built on Pode's own official image (`badgerati/pode:2.14.1-alpine`),
  non-root, with a healthcheck against `/health/ready`
- Windows service (NSSM) install/uninstall scripts
- Full documentation set (`docs/architecture.md`, `api.md`,
  `configuration.md`, `logging.md`, `development.md`)
