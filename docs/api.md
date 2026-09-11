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

Internal detail (stack traces, file paths, exception text, infrastructure
names) is **never** included in a response body - it exists only in the
structured Error log, tagged with the same `correlationId` (see
[logging.md](logging.md)). Built with `New-ApiErrorBody` /
`Send-ApiError` ([src/errors/Errors.ps1](../src/errors/Errors.ps1)) - every
route uses this, no route invents its own error shape.

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

`server.psd1` caps request duration (`408` after 30s) and body size (`413`
above 1MB) before a request reaches any route.

## Authentication

Not implemented in this version. OpsBridge is intended for trusted internal
networks. See [architecture.md](architecture.md) for where authentication and
authorization will slot into the middleware pipeline later.
