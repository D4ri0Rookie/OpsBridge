# Architecture

OpsBridge is a lightweight internal REST API runtime for SysOps/DevOps
automation, built on [Pode](https://badgerati.github.io/Pode/). Pode is the
HTTP runtime only - it does not become a general web framework here.

## Request flow

```mermaid
%%{init: {"flowchart": {"curve": "basis"}}}%%
flowchart TB
    Client(["Client"]) --> Pode["Pode HTTP server"]
    Pode --> Corr["Correlation ID"]
    Corr --> Sec["Security headers"]
    Sec --> Gates{"Shutting down? Over the\nrate/concurrency limit? Unauthenticated?"}
    Gates -->|yes| Reject["Reject: 503 / 429 / 401"]
    Gates -->|no| Route{"Route matched?"}
    Route -->|yes| Handler["Route handler (src/routes)"]
    Route -->|no| NotFound["Catch-all route -> 404"]
    Handler --> Service["Service (src/services/<Area>)"]
    Service --> External["External system\n(Windows, AD, vCenter, Azure, Exchange, ...)"]
    Handler --> Log["Request-log endware"]
    NotFound --> Log
    Reject --> Log
    Log --> Response(["HTTP response"])

    classDef gate fill:#fff3cd,stroke:#b38600,color:#3a2e00
    classDef reject fill:#f8d7da,stroke:#b02a37,color:#4a0d13
    classDef external fill:#e2e3e5,stroke:#6c757d,color:#3a3d40,stroke-dasharray: 4 3
    class Gates gate
    class Reject reject
    class External external
```

Shutdown/rate limit/concurrency/authentication each run as their own
middleware, in that order, right after Security headers - drawn as one
decision above to keep the diagram simple; see
[Layer responsibilities](#layer-responsibilities) below for the exact order.
Authentication is skipped for `/health/live` and `/health/ready` regardless
of this diagram's simplification - see [api.md](api.md#authentication).

## Layer responsibilities

- **Pode** - HTTP server, lifecycle, routing dispatch, middleware pipeline.
  Configured in `server.psd1` (request timeout/body size, error page defaults)
  and started from `src/App.ps1`.
- **Middleware** (`src/middleware/`) - cross-cutting concerns only: correlation
  id, security headers, the shutdown gate, rate limiting, the in-flight
  concurrency gate, authentication, request logging. Runs in this order for
  every request: Correlation ID -> Security Headers -> Shutdown gate -> Rate
  limit -> Concurrency limit -> Authentication -> (future: Authorization) ->
  route -> Request Logging / Concurrency release (endware, always runs).
- **Routes** (`src/routes/`, `src/routes/v1/`) - thin: HTTP method + path,
  request validation, call one service function, map its result to an HTTP
  status code and body. No automation logic lives in a route file.
- **Services** (`src/services/<Area>/`) - the actual automation/business logic
  (PowerShell, SDKs, external API calls). No dependency on Pode or `$WebEvent`
  - a service function takes plain parameters and returns plain data, so it is
  unit-testable without a running server.

## Adding a new capability

Adding `GET /api/v1/vcenter/vms` should only require:

```
src/services/VCenter/Get-Vms.ps1                    # automation logic, no Pode dependency
src/routes/v1/VCenter.ps1                           # thin: validate, call service, respond
tests/unit/services/VCenter/Get-Vms.Tests.ps1       # service logic, mocked external calls
tests/integration/v1/VCenter.Tests.ps1              # real HTTP contract
docs/capabilities/vcenter-vms.md                    # operational doc - see api.md's Capability contract
```

`docs/` splits the same way: the fixed, closed set of runtime docs
(`architecture.md`, `api.md`, `configuration.md`, `logging.md`,
`development.md`) stays flat at the top; `docs/capabilities/` holds one file
per capability, an open set that grows with every new endpoint -
`docs/api.md` stays the index/overview and links out to each, never
duplicating it (see the Capability contract in api.md).

`tests/` mirrors `src/` one level down from `unit`/`integration`: a file under
`src/middleware/`, `src/services/<Area>/` or `src/routes/v1/` gets its test at
the same relative path under `tests/unit/` or `tests/integration/`. A file
that lives directly under `src/` (`Config.ps1`, `Errors.ps1`, `Logging.ps1`)
keeps its test directly under `tests/unit/` too - see
`tests/unit/services/Windows/Get-WindowsServices.Tests.ps1` and
`tests/integration/v1/Windows.Tests.ps1` for the reference pair.

`src/services/*.ps1` files are discovered and loaded automatically
(`Register-ApplicationServices` in `src/App.ps1`); route files under
`src/routes/` and `src/routes/v1/` are discovered and loaded automatically too
(`Register-ApplicationRoutes`). Neither needs touching to add an endpoint. See
`src/routes/v1/Windows.ps1` and `src/services/Windows/Get-WindowsServices.ps1`
for the reference implementation of this pattern - and
`src/services/Windows/Get-WindowsProcesses.ps1` (same route file, second
`Add-AppRoute` block) for a second, real capability built the same way,
nothing in `src/App.ps1` changed to add it.

### Gotcha: no `$script:`-scoped state in a service or route file

Pode's `Use-PodeScript` propagates **function definitions** from a dot-sourced
file into every runspace it manages (web/route, middleware, timers), but it
does **not** re-run arbitrary top-level statements in each of those runspaces
- so a top-level `$script:someCache = @{...}` is only ever populated in
whichever runspace happened to dot-source the file first. A route handler
that reads that variable in a *different* runspace sees `$null`, not the
value you set - and `$null[...]`/`$null.Method()` fails at request time only,
never in a unit test (which never touches Pode's runspace pools at all).

This bit `src/logging/Logging.ps1` in exactly this way during development: a
`$script:AppLogLevelMap` lookup table worked fine when read from the startup
scriptblock, but crashed every request that called `Write-AppLog` from inside
a route handler, with `Cannot index into a null array`. Fixed by turning the
lookup into a function (`Get-AppLogLevelMap`) instead of a shared variable -
functions propagate correctly, incidental script-scope state does not.

If a new service genuinely needs state shared across requests (a cache, a
counter), use Pode's own `Get-PodeState` / `Set-PodeState` (see
`AppConfig`/`AppReady` in `src/App.ps1` for the existing pattern) - never a
bare `$script:` variable.

`tests/integration/Logging.Tests.ps1` now reads the actual log files back and
asserts their JSON matches the schema in [logging.md](logging.md) - a
regression like this one would fail that test, not just a live request.

## What is deliberately not here

- **No `repositories/`, `controllers/`, `providers/`, `factories/`, `managers/`,
  `bootstrap/`, or `routing/` layer.** Configuration, logging and error
  handling each get a dedicated folder (`src/config/`, `src/logging/`,
  `src/errors/`) with exactly one file today, the same way `src/middleware/`,
  `src/routes/` and `src/services/` are organized - a consistent, predictable
  shape, not a sign that more files are expected there. Route loading and the
  per-route error-handling wrapper still live directly in `src/App.ps1`
  rather than a dedicated "routing" package, because the loader is a handful
  of lines that only `src/App.ps1` calls - `App.ps1` itself is the one file
  that stays flat at the top of `src/`, since it is the orchestrator, not a
  concern with its own boundary.
- **No per-identity or distributed rate limiting.** The rate limiter
  (`src/middleware/RateLimit.ps1`, `API_RATE_LIMIT_*`) is a single global
  in-process counter, disabled by default - it protects the process itself,
  not per-user/per-capability quotas. Redis-backed or per-client limiting is a
  distinct, later concern - do not fold it into this mechanism without a
  concrete, current requirement.
- **No UI dependency.** OpsBridge is REST-first: every route under `/api/v1/*`
  and `/health/*` works with no HTML surface at all. A `/` status page may be
  added later as a pure addition, not a dependency.
- **No authorization yet, and no identity system.** Authentication
  (`src/middleware/Authentication.ps1`, `API_AUTH_*`) is a single static
  list of API keys - disabled by default, no per-key identity, scoping, or
  expiry. Authorization (differentiating what a given caller may do) still
  has no implementation - the middleware order above reserves its slot,
  right after Authentication - because every capability today is equally
  `safe`/read-only (see the Capability contract in [api.md](api.md)); build
  it once a capability actually needs to restrict who can call it, not
  before.

## API versioning

`/api/v1/*` is the current contract. A breaking change gets `/api/v2/*`
alongside it, not a modification of `/api/v1/*`. `/health/live` and
`/health/ready` are intentionally outside versioning - they describe the
process, not an API contract.

## Environments

The same code and the same container image run in Development, Test and
Production; only `API_ENVIRONMENT` and the other `API_*` environment variables
change (see [configuration.md](configuration.md)). Nothing in `src/` branches
on environment except through `Get-AppConfig`.

## Target architecture

Direction only - nothing below is implemented, scheduled, or has code
written toward it. Recorded here so decisions made today (thin routes,
transport-agnostic services, no premature transport abstraction - see
[What is deliberately not here](#what-is-deliberately-not-here)) can be
read against where the project is actually headed, not guessed at.

**Near term** - the capability/service core stays exactly as it is; only the
target a capability acts on changes, from "this host" to "a remote host over
SSH" - the *only* transport for every target that exposes a shell (Windows,
Linux, a VMware/AD host), not one transport per target type. This
deliberately does not cover a cloud-only SaaS integration with its own REST
API and no host to SSH into (Azure, Exchange Online, both already listed as
planned areas in [README.md](../README.md)) - that capability would call
the vendor's API directly, the same way this project's services call local
PowerShell cmdlets today. SSH is the transport for infrastructure you can
reach with a shell, not a blanket rule for every future area:

```mermaid
flowchart LR
    Client(["Client / Automation / Agent"]) -->|REST| API["OpsBridge"]
    API --> Cap["Capability / Service<br/>(unchanged)"]
    Cap -->|SSH, pwsh| Win[("Windows target")]
    Cap -->|SSH, bash| Lin[("Linux target")]

    classDef future fill:#e2e3e5,stroke:#6c757d,color:#3a3d40,stroke-dasharray: 4 3
    class Win future
    class Lin future
```

`pwsh`/`bash` are the shell a capability runs its command through once
connected over SSH - not a second transport. A VMware or Active Directory
capability reaches its target the same way: SSH into a Windows or Linux host
that already has the right tooling available (PowerCLI, the AD module),
never a vendor SDK/API client bolted directly onto OpsBridge.

**Further out** - REST stays for direct/human/automation callers; MCP is an
*additional* interface in front of the same capability core, not a
replacement:

```mermaid
flowchart LR
    LLM(["LLM / Agent"]) -->|MCP| API["OpsBridge"]
    Client(["Client / Automation"]) -->|REST| API
    API --> Cap["Capability / Service<br/>(same core, either interface)"]
    Cap -->|SSH| Target[("Remote target")]

    classDef future fill:#e2e3e5,stroke:#6c757d,color:#3a3d40,stroke-dasharray: 4 3
    class Target future
```

The principle behind both steps, and the reason the capability/service layer
is kept transport-agnostic and deterministic today: **LLMs (or any caller)
should select and compose already-tested operations, not generate
infrastructure code.** REST today, MCP later, are interfaces onto the same
core - the capability/service layer is what stays deterministic and
testable regardless of which interface calls it.

None of this justifies building a transport abstraction now
(`ISshProvider`/`IRemoteExecutor`/`TransportFactory`-shaped code, or
anything similar): per
[What is deliberately not here](#what-is-deliberately-not-here) and the
project's whole approach so far, that gets built once at least two real
implementations exist to justify the shape it should take - guessed at in
advance, it would very likely be wrong. Authentication
(`src/middleware/Authentication.ps1`) already anticipates one real
consequence of this direction: a remote-execution capability changes the
blast radius of an unauthenticated caller far more than a local, read-only
one does, which is why it was built before any transport work started.
