# Changelog

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
