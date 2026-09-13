# Configuration

All configuration is centralized in [src/config/Config.ps1](../src/config/Config.ps1)
(`Get-AppConfig`). Every value has a default and can be overridden by an
`API_*` environment variable. No secrets are stored in code or in this
repository.

| Environment variable      | Default       | Description |
|----------------------------|---------------|-------------|
| `API_ENVIRONMENT`          | `Development` | `Development`, `Test`, or `Production` - reported in every log line, changes nothing else in code |
| `API_HOST`                 | `0.0.0.0`     | Address the endpoint binds to |
| `API_PORT`                 | `8080`        | Port (integer 1-65535) |
| `API_PROTOCOL`             | `Http`        | `Http` or `Https` |
| `API_CERT_SELF_SIGNED`     | `false`       | `true`/`false` - with `API_PROTOCOL=Https`, use a Pode-generated self-signed certificate instead of a certificate file. Development/test only - browsers and most HTTP clients reject it by default |
| `API_CERT_PATH`            | *(none)*      | Path to a `.pfx` certificate file. Required when `API_PROTOCOL=Https` and `API_CERT_SELF_SIGNED` is not `true` |
| `API_CERT_PASSWORD`        | *(none)*      | Password for `API_CERT_PATH`, if it has one. A secret: read directly by `src/App.ps1`, never stored in `Get-AppConfig`'s output (see below) |
| `API_THREADS`              | `3`           | Pode worker runspaces (integer >= 1) |
| `API_DAEMON`               | `false`       | `true`/`false` - run Pode headless (`-Daemon`). Set to `true` by the Windows service installer (`scripts/install-service.ps1`) |
| `API_LOG_LEVEL`            | `Info`        | `Debug`, `Info`, `Warning`, or `Error` |
| `API_LOG_FORMAT`           | `json`        | Only `json` is supported today |
| `API_LOG_DESTINATION`      | `stdout`      | `stdout`, `file`, or `both` - stdout is preferred for containers (see [logging.md](logging.md)) |
| `API_LOG_PATH`             | `<repo>/logs` | Directory for log files, only used when `API_LOG_DESTINATION` includes `file` |
| `API_LOG_RETENTION_DAYS`   | `7`           | Days of log files to keep (integer >= 1), only used when `API_LOG_DESTINATION` includes `file` |
| `API_MAX_BODY_BYTES`       | `1048576` (1MB) | Maximum request body size in bytes (integer >= 1). Over the limit: `413` |
| `API_MAX_IN_FLIGHT_REQUESTS` | `100`       | Maximum number of requests processed concurrently (integer >= 1). Over the limit: `503` |
| `API_REQUEST_TIMEOUT_SECONDS` | `30`       | Soft budget for route handler execution time (integer >= 1) - see below |
| `API_SHUTDOWN_TIMEOUT_SECONDS` | `30`      | Grace period for in-flight requests to finish during shutdown (integer >= 1) before the process terminates - see [Graceful shutdown](#graceful-shutdown) |
| `API_RATE_LIMIT_ENABLED`   | `false`       | `true`/`false` - enable the in-process rate limiter |
| `API_RATE_LIMIT_REQUESTS`  | `300`         | Requests allowed per window, across all clients (integer >= 1), only enforced when `API_RATE_LIMIT_ENABLED=true` |
| `API_RATE_LIMIT_WINDOW_SECONDS` | `60`     | Rate limit window length in seconds (integer >= 1), only enforced when `API_RATE_LIMIT_ENABLED=true` |
| `API_AUTH_ENABLED`         | `false`       | `true`/`false` - require `X-Api-Key` on every request except `/health/live` and `/health/ready` (see [api.md](api.md#authentication)) |
| `API_AUTH_KEYS`            | *(none)*      | Comma-separated list of valid API keys. Required when `API_AUTH_ENABLED=true`. A secret: read directly by `src/middleware/Authentication.ps1`, never stored in `Get-AppConfig`'s output - same treatment as `API_CERT_PASSWORD` below |

**Fail-fast settings**: `API_MAX_BODY_BYTES`, `API_MAX_IN_FLIGHT_REQUESTS`,
`API_REQUEST_TIMEOUT_SECONDS`, `API_SHUTDOWN_TIMEOUT_SECONDS`, the three
`API_RATE_LIMIT_*` settings, and `API_AUTH_ENABLED`/`API_AUTH_KEYS` work
differently from everything else on this page: an invalid value aborts
startup immediately (exit code `1`) instead of falling back with a warning,
because they guard process stability or security. This applies even when
the related feature is disabled - e.g. a bad `API_RATE_LIMIT_REQUESTS`
still fails startup with `API_RATE_LIMIT_ENABLED=false`. `API_AUTH_KEYS` is
the one exception in the other direction: it is only required - and only
checked - when `API_AUTH_ENABLED=true`; leaving it unset while auth is
disabled is fine.

The application version is **not** an environment variable - it is defined once
as `AppVersion` in `src/config/Config.ps1` and reported by `/health/ready`.

## Promoting the same artifact across environments

The goal is to run the identical container image / codebase in Development,
Test and Production, changing only environment variables:

```
Development  (API_ENVIRONMENT=Development, API_LOG_LEVEL=Debug)
    |
    v
Test         (API_ENVIRONMENT=Test)
    |
    v
Production   (API_ENVIRONMENT=Production, API_LOG_LEVEL=Info)
```

Nothing under `src/` should ever branch on `API_ENVIRONMENT` directly - it
exists for observability (it appears in every log line) and to let future
environment-specific *configuration* (not code) vary.

## Invalid overrides

An override that fails validation (wrong type, out of range, not in the
allowed set) is **discarded** - the default is kept - and a warning is
emitted. `src/App.ps1` captures those warnings and re-logs them through the
structured Application log once logging is up, as an
`application.startup.warning` event, e.g.:

```json
{ "event": "application.startup.warning", "message": "Configuration: API_PORT '70000' is not an integer in 1-65535; keeping default 8080." }
```

so a bad value is diagnosable from the logs without attaching to the process.
The server still starts.

## HTTPS

Set `API_PROTOCOL=Https` to serve over TLS. Two ways to provide a certificate:

- **Development/test**: `API_CERT_SELF_SIGNED=true` - Pode generates a
  self-signed certificate at startup. No file to manage, but browsers and most
  HTTP clients reject it by default (`curl -k`, or PowerShell's
  `-SkipCertificateCheck`, to talk to it anyway).
- **Production**: `API_CERT_PATH=/path/to/cert.pfx` (and `API_CERT_PASSWORD`
  if the file needs one) - a real certificate, from an internal CA or a public
  one.

`API_CERT_PASSWORD` is the one deliberate exception to "no secrets in
`Get-AppConfig`'s output": `src/App.ps1` reads it directly from the
environment at the single point it hands it to Pode, so it never enters the
config object that is stored as shared Pode state and partly written to the
Application log.

`API_PROTOCOL=Https` without `API_CERT_SELF_SIGNED=true` and without a
`API_CERT_PATH` that points to an existing file fails startup immediately with
a clear message (the HTTPS counterpart of the port-in-use check below), rather
than a certificate-loading exception from deep inside Pode.

## Startup port check

Before starting Pode, `src/App.ps1` tries to bind the configured
address/port. If it is already in use, startup fails with a clear message
(`... is already in use. Set API_PORT to a free port ...`) and exit code `1`,
instead of a raw Pode socket exception. A bind address that can't be resolved
locally (a hostname) skips the check and lets Pode be the authority.

## Request handler timeout (`API_REQUEST_TIMEOUT_SECONDS`)

A **soft** budget, not a preemptive cutoff. Every route handler runs inside
`src/App.ps1`'s wrapper (`Add-AppRoute`), which times the handler and, if it
ran longer than `API_REQUEST_TIMEOUT_SECONDS`, logs an `application.timeout`
warning and marks the request-log entry (`timedOut: true`, see
[logging.md](logging.md)). The client still gets whatever the handler
produced.

It does not abort a running handler - that needs a runspace per request,
which is real overhead on every request to guard against a hang no current
route can hit (every handler today is fast and synchronous). If a future
service adds a slow external call, give that call its own timeout at the
point it's made - that's the right fix for a hanging dependency, not a
generic wrapper around every route.

## Graceful shutdown

OpsBridge handles SIGTERM and SIGINT (`docker stop`, Ctrl+C) itself. Neither
Pode nor plain PowerShell does by default - an unpatched process exits within
a fraction of a second, nothing flushed to the logs, any in-flight request
cut off. `src/middleware/Shutdown.ps1` fixes that:

1. The signal is caught immediately by a compiled static field, not a
   PowerShell scriptblock - .NET runs the callback on a thread with no
   Runspace attached, which can't run script code. This cancels the default
   action (immediate termination).
2. From that instant, every *new* request gets `503 SHUTTING_DOWN`
   immediately - it never reaches rate limiting, the concurrency gate, or a
   route (see [api.md](api.md)).
3. A Pode timer notices the signal within ~1 second and calls
   `Close-PodeServer`, which fires Pode's `Terminate` event.
4. The `Terminate` handler waits for every in-flight request to finish, or
   for `API_SHUTDOWN_TIMEOUT_SECONDS` to elapse - whichever comes first -
   logging `application.shutdown.started`/`application.shutdown.completed`
   (with `drained: true/false`).
5. Pode then closes its listeners/runspaces and the process exits - `0` on a
   clean shutdown.

This is a single fixed sequence, not a configurable lifecycle system - only
the drain deadline (`API_SHUTDOWN_TIMEOUT_SECONDS`) varies.

## Pode-native settings

[server.psd1](../server.psd1) holds Pode-native server settings that are not
part of the `API_*` surface (no per-value environment overrides - edit the
file and restart):

- `Server.Request.Timeout = 30` - seconds; a client that exceeds it gets `408`.
  Unrelated to `API_REQUEST_TIMEOUT_SECONDS` above, which bounds route
  *handler* execution time, not how long Pode waits to receive the request.
- `Server.Request.BodySize = 1MB` - bytes; a body over the limit gets `413`
  (`errors/413.json`, no `correlationId` - Pode enforces this at the listener
  level, before any application code runs, which is also why it's correct
  for chunked bodies with no `Content-Length` to pre-check). Overridable
  per-run via `API_MAX_BODY_BYTES`: `src/App.ps1`'s `New-RuntimeServerConfigFile`
  writes a copy of this file with `BodySize` swapped, only when the override
  is set - with no override, this static file loads unchanged.
- `Web.ErrorPages.Default = 'application/json'` - any status Pode raises
  directly (`408`, `413`, an exotic method) is served as JSON from `errors/`
  (`default.json` is the fallback). `404`, `422`, `503` and `500` are produced
  by the application (`Send-ApiError`), not these pages.
- `Web.ErrorPages.ShowExceptions = $false` - exception detail is never
  rendered into an error response.

## Example

```powershell
$env:API_PORT = '9000'
$env:API_LOG_LEVEL = 'Debug'
$env:API_ENVIRONMENT = 'Development'
.\server.ps1
```

When running as a Windows service the same values are baked into the service
environment by `scripts/install-service.ps1 -Environment @{ ... }`.
