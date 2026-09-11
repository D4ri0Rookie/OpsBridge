# Changelog

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
