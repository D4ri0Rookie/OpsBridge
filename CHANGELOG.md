# Changelog

## 0.5.2 - 2026-09-13

Bug fix: graceful shutdown's drain-wait could silently never run. Found by
noticing a stray error log entry, root-caused by reading Pode 2.14.1's own
source and reproducing it directly against a live server (not just from
test suite behavior, which never caught it).

- Root cause: `Register-PodeEvent -Type Terminate`'s scriptblock is invoked
  by Pode via its own `GetNewClosure()` at *fire* time, not at
  registration time - so a variable closed over when the scriptblock was
  originally written (`$root`) is already out of scope by the time
  Terminate actually fires. This intermittently made `Wait-AppShutdownDrain`
  "not recognized" there (`CommandNotFoundException`), silently skipping
  the drain wait entirely - in-flight requests could be cut off exactly
  like the ungraceful-SIGTERM problem this mechanism exists to prevent.
  The process still exited `0` regardless, so no existing test noticed
- Fix: extracted the Terminate event's body into
  `Invoke-AppShutdownTerminateHandler` (`src/middleware/Shutdown.ps1`) -
  unit-testable now, same reasoning as `New-WrappedRouteScriptBlock` - which
  re-sources every dependency it needs from a freshly called
  `Get-PodeServerPath` (reads Pode's own server context, immune to the
  closure problem) instead of trusting ambient availability
- Separate, lower-severity finding along the way, documented rather than
  worked around: Pode's own file-log-writer runspace polls the *same*
  cancellation token that fires the Terminate event, with no ordering
  guarantee between the two - so `application.shutdown.started`/
  `.completed`/`.stopped` can still be delayed or lost on a real shutdown
  even now that the drain-wait itself runs correctly. A synthetic delay
  was tried and rejected (unreliable, adds shutdown latency for uncertain
  benefit) - see `docs/logging.md`'s "Known gap" note. The two Application-
  log events this uncovered as previously undocumented
  (`application.shutdown.started`/`.completed`) are now listed in the
  event taxonomy there too
- 2 new unit tests (`tests/unit/middleware/Shutdown.Tests.ps1`): one proves
  the handler runs correctly end-to-end, one runs it in a genuinely empty
  PowerShell process (`Start-Job`, no Pode, nothing pre-loaded) with only
  bare Pode-cmdlet stubs - the closest a unit test gets to the real
  cross-runspace scenario the bug came from
- Removed one integration test added earlier in this same investigation
  that asserted on the (necessarily unreliable, per the finding above)
  shutdown log content - it failed consistently for a reason unrelated to
  correctness, so it would have been permanent noise, not signal
- 216 unit + integration tests (219 total, 216 passing + 3 pre-existing
  Windows-only skips on this non-Windows dev host); 0 PSScriptAnalyzer
  findings

## 0.5.1 - 2026-09-13

Middleware pipeline reorder: authentication now runs between rate limiting
and the concurrency gate, not after both. Prompted by external review of
v0.5.0 - a deliberate ordering decision, not a bug fix, recorded here with
its reasoning per the same "no silent architectural choices" standard the
rest of the runtime already holds itself to.

- New order: Correlation ID -> Security Headers -> Shutdown gate -> Rate
  limit -> **Authentication** -> **Concurrency limit** -> route (previously
  Rate limit -> Concurrency limit -> Authentication)
- Why rate limit still precedes authentication: it is a volumetric,
  identity-blind defense - if it ran after authentication, a flood of
  unauthenticated traffic would bypass it entirely, since every one of
  those requests would be rejected before ever reaching the rate limiter
- Why authentication now precedes concurrency: a request rejected for
  missing/invalid credentials does no real work, so it must never occupy a
  concurrency slot a legitimate, authenticated request might need under
  load - previously it briefly did (correctly released afterward, but still
  consumed while held)
- 2 new integration tests proving the new order directly: an unauthenticated
  request never triggers `503 OVERLOADED` even when concurrent load exceeds
  the concurrency limit (always `401` instead), and unauthenticated requests
  still trigger `429 RATE_LIMIT_EXCEEDED` once the rate-limit budget is
  spent (rate limiting is not bypassed by lacking credentials)
- 214 unit + integration tests (217 total, 214 passing + 3 pre-existing
  Windows-only skips on this non-Windows dev host); 0 PSScriptAnalyzer
  findings
- No behavior change for a request that IS authenticated, and no change to
  `/health/live`/`/health/ready` (still exempt from authentication, still
  subject to rate limiting like every other path)

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
