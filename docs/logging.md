# Logging

Structured JSON logging is a core feature of OpsBridge, not an afterthought.
Every log line - Application, Request, or Error - is one JSON object per line,
in the same UTC ISO-8601 millisecond timestamp format, so the three streams
can be correlated by `correlationId` and, failing that, by time.

Implementation: [src/logging/Logging.ps1](../src/logging/Logging.ps1), on top of Pode
2.14.1's native Custom Log Types (`Add-PodeLogType`) and automatic error
capture (`Enable-PodeErrorLogging`).

## Destination

Controlled by `API_LOG_DESTINATION` (see [configuration.md](configuration.md)):

```
OpsBridge
   |
   v
Structured JSON
   |
   +--> stdout   (API_LOG_DESTINATION = stdout | both)   <- preferred for containers
   |
   +--> file     (API_LOG_DESTINATION = file | both)     <- optional, useful on Windows Server
```

The application never depends on log files existing or being writable to
start or run correctly. This is what lets logs be shipped to OpenSearch, Loki,
Elastic, Splunk or similar later by attaching to stdout, with no code change.

## Streams and schema

All three streams share these base fields:

| Field | Meaning |
|---|---|
| `timestamp` | UTC, ISO-8601, millisecond precision |
| `level` | `Debug`, `Informational`, `Warning`, `Error`, ... (Pode's native level names) |
| `application` | Always `"OpsBridge"` |
| `environment` | The running `API_ENVIRONMENT` |
| `correlationId` | The request's correlation id, or `null` outside a request (e.g. at startup) |

### Application log

One line per lifecycle/service/external-dependency event, written with
`Write-AppLog -Level ... -Event '<event>' -Data @{ ... }`. Extra fields from
`-Data` are merged flat into the line - use lowerCamelCase keys.

```json
{
  "timestamp": "2026-09-11T15:42:12.123Z",
  "level": "Informational",
  "event": "application.started",
  "application": "OpsBridge",
  "environment": "Production",
  "correlationId": null,
  "appVersion": "0.5.0",
  "listenAddress": "0.0.0.0",
  "port": 8080,
  "protocol": "Https"
}
```

Event categories in use (add new ones the same way, do not invent a
parallel taxonomy):

```
application.started
application.stopped
application.startup.warning
application.route.loaded
application.service.loaded
application.ready

service.operation.started
service.operation.completed
service.operation.failed
```

### Request log

One line per HTTP request/response, written by the endware in
[src/middleware/RequestLogging.ps1](../src/middleware/RequestLogging.ps1).
`event` is `http.request.completed` for status < 500 and
`http.request.failed` for status >= 500:

```json
{
  "timestamp": "2026-09-11T15:42:12.123Z",
  "level": "Informational",
  "event": "http.request.completed",
  "application": "OpsBridge",
  "environment": "Production",
  "correlationId": "abc123",
  "method": "GET",
  "path": "/api/v1/windows/services",
  "statusCode": 200,
  "durationMs": 143,
  "clientIp": "127.0.0.1"
}
```

`clientIp` is the remote socket address Pode accepted the connection from
(see `Get-ClientIp`, [src/middleware/RequestLogging.ps1](../src/middleware/RequestLogging.ps1))
- `null` if it could not be determined. Not `X-Forwarded-For`-aware: behind a
reverse proxy this is the proxy's address, not the original client's.

`errorType` is added on any non-2xx response - the same `code` already
returned in the error body (e.g. `VALIDATION_ERROR`, `OVERLOADED`,
`NOT_FOUND`), set once by `Send-ApiError`
([src/errors/Errors.ps1](../src/errors/Errors.ps1)) so every error source
(routes, middleware) gets it for free. Lets an error rate be queried straight
off the request log, without joining to the Error log.

`timedOut: true` is added when the handler ran past `API_REQUEST_TIMEOUT_SECONDS`
(default 30s) - a soft, log-only budget (see
[configuration.md](configuration.md)): the response is still whatever the
handler produced, this only flags that it was slow. Also logged as its own
`application.timeout` Application-log event, with `path`/`durationMs`.

### Error log

Unhandled exceptions, captured automatically by Pode
(`Enable-PodeErrorLogging`) - every route handler is wrapped for this by
`Add-AppRoute` (`src/App.ps1`), so a throwing handler always produces one of
these plus a generic `500` to the client:

```json
{
  "timestamp": "2026-09-11T15:42:12.500Z",
  "level": "Error",
  "application": "OpsBridge",
  "environment": "Production",
  "category": "Runtime Exception",
  "message": "...",
  "stackTrace": "...",
  "metadata": { "correlationId": "abc123", "route": "/api/v1/windows/services" }
}
```

`stackTrace` and `message` here are exactly the kind of detail that must
**never** appear in an HTTP response body (see the error contract in
[api.md](api.md)) - they exist only in this stream, tied to the request by
`metadata.correlationId`.

## Sensitive data policy

Never log:

- passwords, access/refresh tokens, client secrets, private keys
- the `Authorization` header
- credentials of any kind

Be careful specifically with: query strings, request bodies, PowerShell
command output, and exception messages - any of these can carry the values
above without the code obviously "logging a credential". When a future
service captures external command/API output for diagnostics, review it for
secrets before it reaches `Write-AppLog` / `Write-AppErrorLog`.

**Centralized redaction**: `Write-AppLog` and `Write-AppErrorLog`
(`src/logging/Logging.ps1`) run their data through `Protect-AppLogData`
before writing anything. Any key whose name contains `authorization`,
`password`, `token`, `api[-_]?key`, `secret`, `credential`, or `cookie`
(case-insensitive, checked recursively) has its value replaced with
`***REDACTED***`. This protects every call site automatically - but it's
key-name-based, not a DLP system: it won't catch a secret hiding inside an
innocuously-named value (e.g. an exception message), which still needs care
at the call site.

## Correlation id in logs

Every `Write-AppLog` and `Write-AppErrorLog` call picks up the current
request's correlation id automatically via `Get-CorrelationId` (see
[src/middleware/CorrelationId.ps1](../src/middleware/CorrelationId.ps1)); a
call made outside a request (startup, shutdown) logs `correlationId: null`,
which is expected and not an error.
