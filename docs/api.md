# API

Every response is JSON. Every error response shares the same shape. Every
response carries an `X-Correlation-ID` header (see below).

## Error contract

```json
{
  "error": {
    "code": "RESOURCE_NOT_FOUND",
    "message": "The requested resource was not found.",
    "correlationId": "7c8f2c..."
  }
}
```

A validation error additionally carries `details`:

```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "The request contains invalid parameters.",
    "correlationId": "7c8f2c...",
    "details": [
      { "field": "name", "code": "REQUIRED" }
    ]
  }
}
```

`category` and `retryable` are optional, additive fields set on the newer
runtime-protection errors - a client can use them to decide whether to retry:

```json
{
  "error": {
    "code": "RATE_LIMIT_EXCEEDED",
    "message": "Request rate limit exceeded.",
    "category": "rate_limit",
    "retryable": true,
    "correlationId": "7c8f2c..."
  }
}
```

| `category`   | Meaning                                   | Seen on |
|--------------|--------------------------------------------|---------|
| `validation` | The request itself is invalid              | `422`, `413` |
| `rate_limit` | Client sent too many requests              | `429` |
| `overload`   | The server is at capacity                  | `503` (concurrency limit) |
| `internal`   | Unexpected server-side failure             | `500` |

`timeout` is reserved by the taxonomy but not currently emitted on any
response: `API_REQUEST_TIMEOUT_SECONDS` is a soft, log-only budget (a slow
handler is logged, not turned into an error response) - see
[configuration.md](configuration.md#request-handler-timeout-api_request_timeout_seconds).

Older error sources (`404`, the Windows service-manager `503`) omit `category`
and `retryable` rather than being forced into a category that doesn't
describe them - this is additive, not a breaking change to the envelope.

Internal detail (stack traces, file paths, exception text, infrastructure
names) is **never** included in a response body - it exists only in the
structured Error log, tagged with the same `correlationId` (see
[logging.md](logging.md)). Built with `New-ApiErrorBody` /
`Send-ApiError` ([src/errors/Errors.ps1](../src/errors/Errors.ps1)) - every
route uses this, no route invents its own error shape.

**Exception**: a `413` (body too large) is served from a static file
(`errors/413.json`) by Pode itself, before the correlation id middleware runs
- it carries `code`/`message`/`category`/`retryable` but never a
`correlationId`. This is a deliberate, documented limitation (see
[configuration.md](configuration.md#pode-native-settings)), not an
inconsistency to fix by hand per request.

## Correlation ID

Header: `X-Correlation-ID`.

- If the client sends a well-formed value (1-128 url-safe characters), it is
  reused for the whole request.
- Otherwise a new one is generated.
- It is returned on every response (success or error) and used in every log
  line for that request.

See [src/middleware/CorrelationId.ps1](../src/middleware/CorrelationId.ps1).

## Versioning

`/api/v1/*` is the current, stable contract. A breaking change is introduced
as `/api/v2/*` alongside it, never as a silent change to `/api/v1/*`.
`/health/live` and `/health/ready` are outside versioning.

## Health

### `GET /health/live`

Liveness - the process is up. Never depends on external systems. Always `200`.

```json
{ "status": "healthy", "checks": { "application": "healthy" } }
```

### `GET /health/ready`

Readiness - the application finished starting. `200` once ready, `503` until
then.

```json
{ "status": "healthy", "checks": { "application": "healthy" } }
```

## `GET /api/v1/windows/services`

Reference implementation of the Pode -> middleware -> route -> service
pattern (see [architecture.md](architecture.md)). Lists Windows services via
`Get-Service`.

**Query parameters**

| Name | Required | Description |
|---|---|---|
| `name` | no | Exact service name or wildcard (e.g. `wuau*`), 1-256 characters. Omit to list every service. |

**Responses**

| Status | When | Body |
|---|---|---|
| `200` | Success (possibly an empty list, if `name` was a wildcard matching nothing) | `{ "data": [ { "name", "displayName", "status", "startType" }, ... ] }` |
| `422` | `name` was supplied but blank (`details[0].code = "EMPTY"`), or longer than 256 characters (`details[0].code = "TOO_LONG"`) | Standard validation error, `details[0].field = "name"` |
| `404` | `name` was a specific, non-wildcard value that matched no service | `{ "error": { "code": "SERVICE_NOT_FOUND", ... } }` |
| `503` | The Windows Service Control Manager is not available on this host (e.g. running on Linux/macOS, or a stripped-down Windows container) | `{ "error": { "code": "WINDOWS_SERVICE_MANAGER_UNAVAILABLE", ... } }` |

Example:

```
GET /api/v1/windows/services?name=wuauserv

200 OK
{
  "data": [
    { "name": "wuauserv", "displayName": "Windows Update", "status": "Running", "startType": "Automatic" }
  ]
}
```

## Unmatched routes

Any request that matches no route (any method, any path) returns a coherent
`404`:

```json
{ "error": { "code": "NOT_FOUND", "message": "Resource not found.", "correlationId": "..." } }
```

## Security headers

Set on every response (success or error) by
[src/middleware/SecurityHeaders.ps1](../src/middleware/SecurityHeaders.ps1):
`Content-Security-Policy`, `X-Content-Type-Options`, `X-Frame-Options`,
`Referrer-Policy`, `Permissions-Policy`, `Cross-Origin-Opener-Policy`,
`Cross-Origin-Resource-Policy`, `Cache-Control: no-store`, and a normalised
`Server: OpsBridge`.

## Request limits

`server.psd1` caps request duration (`408` after 30s, unrelated to the
handler timeout below) and body size (`413` above `API_MAX_BODY_BYTES`,
default 1MB) before a request reaches any route.

## Request handler timeout

`API_REQUEST_TIMEOUT_SECONDS` (default 30) is a **soft** budget: a handler
that runs longer is logged (`application.timeout`, `timedOut: true` on the
request-log entry - see [logging.md](logging.md)), not aborted - the response
is still whatever the handler produced. See
[configuration.md](configuration.md#request-handler-timeout-api_request_timeout_seconds)
for why this is deliberately not a preemptive cutoff.

## Rate limiting

Disabled by default. When `API_RATE_LIMIT_ENABLED=true`, OpsBridge allows at
most `API_RATE_LIMIT_REQUESTS` requests per rolling `API_RATE_LIMIT_WINDOW_SECONDS`-second
window - a single global counter, not per-client (see
[architecture.md](architecture.md)). Once the window's budget is used up:

```json
{
  "error": {
    "code": "RATE_LIMIT_EXCEEDED",
    "message": "Request rate limit exceeded.",
    "category": "rate_limit",
    "retryable": true,
    "correlationId": "7c8f2c..."
  }
}
```

Status `429`, with a `Retry-After` header (seconds until the window resets).

## Concurrency limit

OpsBridge caps the number of requests it processes at the same time
(`API_MAX_IN_FLIGHT_REQUESTS`, default 100) - a single, global, in-process
counter (no per-user/per-route limits, no distributed coordination; see
[architecture.md](architecture.md)). Once at capacity, a new request gets:

```json
{
  "error": {
    "code": "OVERLOADED",
    "message": "The server is at capacity. Try again later.",
    "category": "overload",
    "retryable": true,
    "correlationId": "7c8f2c..."
  }
}
```

Status `503`. A slot frees up as soon as the request it belongs to finishes
(success, error, or exception - see
[src/middleware/Concurrency.ps1](../src/middleware/Concurrency.ps1)).

## Shutting down

Once OpsBridge receives SIGTERM/SIGINT, every new request gets:

```json
{
  "error": {
    "code": "SHUTTING_DOWN",
    "message": "The server is shutting down and is not accepting new requests.",
    "category": "overload",
    "retryable": true,
    "correlationId": "7c8f2c..."
  }
}
```

Status `503`, immediately - a request already being handled is given up to
`API_SHUTDOWN_TIMEOUT_SECONDS` to finish normally. See
[configuration.md](configuration.md#graceful-shutdown).

## Authentication

Not implemented in this version. OpsBridge is intended for trusted internal
networks. See [architecture.md](architecture.md) for where authentication and
authorization will slot into the middleware pipeline later.
