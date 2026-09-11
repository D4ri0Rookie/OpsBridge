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

## Pode-native settings

[server.psd1](../server.psd1) holds Pode-native server settings that are not
part of the `API_*` surface (no per-value environment overrides - edit the
file and restart):

- `Server.Request.Timeout = 30` - seconds; a client that exceeds it gets `408`.
- `Server.Request.BodySize = 1MB` - bytes; a request body over the limit gets
  `413`. Both checks run before the request reaches a route. Raise `BodySize`
  here if an endpoint needs to accept a larger payload.
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
