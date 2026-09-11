<div align="center">

# OpsBridge

**Lightweight internal REST API runtime for SysOps/DevOps automation**, built on [Pode](https://badgerati.github.io/Pode/).

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-7.6%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![Pode](https://img.shields.io/badge/Pode-2.14.1-orange)](https://github.com/Badgerati/Pode)
[![Tests](https://img.shields.io/badge/tests-Pester%206-brightgreen)](https://github.com/pester/Pester)

</div>

OpsBridge exposes infrastructure automation over a plain REST API (HTTP or
HTTPS). Windows today, with Active Directory, VMware vCenter, Azure and
Exchange Online planned as `/api/v1/<area>/*` additions on top of the same
pattern — REST-first, no UI dependency, one consistent way to add a new
capability.

```mermaid
flowchart LR
    Client(["Client"]) -->|HTTP / HTTPS| Endpoint(["Pode endpoint"])

    subgraph API["OpsBridge"]
        direction LR
        Endpoint --> MW["Correlation ID<br/>+ Security Headers"]
        MW --> Routes["Routes<br/>/api/v1/*"]
        Routes --> Services["Services"]
    end

    MW -.->|structured JSON| Logs[("Logs")]
    Services --> Ext[("Windows · AD · vCenter<br/>Azure · Exchange")]
```

## Quick start

**1. Clone & run**

```powershell
git clone https://github.com/D4ri0Rookie/OpsBridge.git
cd OpsBridge
.\scripts\setup.ps1
.\server.ps1
```

**2. Try it**

```console
$ curl http://localhost:8080/health/live
{"checks":{"application":"healthy"},"status":"healthy"}

$ curl http://localhost:8080/api/v1/windows/services?name=wuauserv
{"data":[{"name":"wuauserv","displayName":"Windows Update","status":"Running","startType":"Automatic"}]}
```

**3. Or with Docker** — built on Pode's own official image, PowerShell included, nothing to install:

```bash
docker build -t opsbridge .
docker run --rm -p 8080:8080 opsbridge
```

## Why

- **HTTP or HTTPS** — same code path, `API_PROTOCOL=Https` with a self-signed cert for dev or a real `.pfx` in production
- **Structured JSON logs**, correlation ID on every request/response/log line
- **One error shape everywhere** — `{ "error": { "code", "message", "correlationId" } }`, no stack traces ever leaked to a client
- **Thin routes, real services** — automation logic has zero Pode dependency, so it's unit-testable on its own
- **Nothing hidden** — adding an endpoint means adding a route file + a service file, not learning an internal framework

## Tests

**88 unit + integration tests passing, 0 PSScriptAnalyzer findings** (Pester 6).
Integration tests start a real server process and check the actual HTTP
contract — status codes, headers, JSON shape, correlation id — not just
isolated functions.

```powershell
Invoke-Pester -Configuration (./PesterConfiguration.ps1)
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

**Load**: a local sanity check with `scripts/load-test.ps1` — same machine, not a network
benchmark, just proof it holds up under concurrent load with the default 3 Pode worker threads.

| Requests | Concurrency | Result | Latency (min / avg / p95 / max) |
|---|---|---|---|
| 1000 | 50 | 1000/1000 `200` | 6.3 / 11.3 / 16.7 / 139.9 ms |

```powershell
.\scripts\load-test.ps1 -TotalRequests 1000 -Concurrency 50
```

## Documentation

| | |
|---|---|
| [Architecture](docs/architecture.md) | Layers, request flow, how to add a new capability |
| [API](docs/api.md) | Endpoints, request/response contracts, error format |
| [Configuration](docs/configuration.md) | Every `API_*` environment variable |
| [Logging](docs/logging.md) | JSON log format, event taxonomy, sensitive data policy |
| [Development](docs/development.md) | Prerequisites, tests, static analysis, Docker |

## Status

Early stage. Health endpoints and one reference API
(`GET /api/v1/windows/services`) are implemented end-to-end — route, service,
unit + integration tests, docs — as the template every future integration
follows. Authentication, authorization and rate limiting are deliberately out
of scope for now (see [architecture.md](docs/architecture.md)).

## License

MIT — see [LICENSE](LICENSE).
