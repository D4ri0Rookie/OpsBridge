# Development

## Prerequisites

- PowerShell **7.6+** (Pester 6 needs 7.4+; 7.6 is the standardized floor for
  this project, matching the reference development environment).
- [Pode](https://www.powershellgallery.com/packages/Pode) **2.14.1+**
- [Pester](https://www.powershellgallery.com/packages/Pester) **6.2.0+**
- [PSScriptAnalyzer](https://www.powershellgallery.com/packages/PSScriptAnalyzer) **1.25.0+**
- [InjectionHunter](https://www.powershellgallery.com/packages/InjectionHunter) **1.0.0+** - optional, only needed for `scripts/analyze.ps1` (see [Static analysis](#static-analysis))

Install the modules:

```powershell
Install-Module -Name Pode -RequiredVersion 2.14.1 -Scope CurrentUser
Install-Module -Name Pester -RequiredVersion 6.2.0 -Scope CurrentUser
Install-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser
Install-Module -Name InjectionHunter -RequiredVersion 1.0.0 -Scope CurrentUser
```

`scripts/setup.ps1` checks/installs Pode automatically and does a few other
one-time local-machine chores (see below).

## First run

```powershell
.\scripts\setup.ps1   # checks PS/Pode versions, unblocks files, reports port availability
.\server.ps1           # foreground
```

Then:

```powershell
Invoke-RestMethod http://localhost:8080/health/live
Invoke-RestMethod http://localhost:8080/api/v1/windows/services
```

Override configuration with `API_*` environment variables - see
[configuration.md](configuration.md). For HTTPS with a throwaway self-signed
certificate:

```powershell
$env:API_PROTOCOL = 'Https'
$env:API_CERT_SELF_SIGNED = 'true'
.\server.ps1
Invoke-RestMethod https://localhost:8080/health/live -SkipCertificateCheck
```

## Running in the background

```powershell
.\scripts\start-background.ps1
```

Returns a PowerShell job you can `Receive-Job` / `Stop-Job` / `Remove-Job`.

## Unit tests

Fast, no HTTP server, no Pode dependency - pure functions and mocked external
calls (e.g. `Get-Service` is mocked in
`tests/unit/services/Windows/Get-WindowsServices.Tests.ps1`):

```powershell
Invoke-Pester -Path tests/unit
```

## Integration tests

Start a real `server.ps1` process on a free port and exercise the actual HTTP
contract (status codes, headers, JSON bodies, correlation id):

```powershell
Invoke-Pester -Path tests/integration
```

## Both, with the shared configuration

```powershell
Invoke-Pester -Configuration (./PesterConfiguration.ps1)
```

Writes `testResults.xml` (NUnit format) for CI consumption.

> **Pester 6 note:** discovery and run happen per file, not globally up front
> as in Pester 5 - do not rely on one test file's discovery-time side effects
> from another file. Every test file here imports what it needs in its own
> `BeforeAll`.

## Static analysis

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

The project targets zero `Error`/`Warning` findings. Every excluded rule in
`PSScriptAnalyzerSettings.psd1` carries a one-line justification - don't add a
suppression without one.

With [InjectionHunter](https://www.powershellgallery.com/packages/InjectionHunter)
installed, `scripts/analyze.ps1` runs the same rule set plus InjectionHunter's
injection-focused rules (`[scriptblock]::Create`, `Add-Type`, `ForEach-Object
-Parallel $using:`, ...) - relevant here because request data eventually
reaches PowerShell code paths (route handlers, `Get-Service` calls):

```powershell
.\scripts\analyze.ps1
```

Two legitimate hits exist today, both suppressed inline with
`[Diagnostics.CodeAnalysis.SuppressMessageAttribute(...)]` and a justification
- `New-WrappedRouteScriptBlock` (`src/App.ps1`) recompiles a route file's own
source, not request data, and `scripts/load-test.ps1`'s `-Parallel $using:`
carries an operator-supplied CLI parameter, not network input. Same rule as
above: don't add a new suppression without a one-line reason.

## Adding an endpoint

See [architecture.md](architecture.md#adding-a-new-capability). In short: one
file under `src/services/<Area>/`, one thin file under `src/routes/v1/`, one
unit test file, one integration test file. Neither `src/App.ps1` nor any
other framework file needs to change.

Every new endpoint should satisfy the Definition of Done before it's
considered complete - see the project's `MASTER PROMPT` checklist (route,
version, validation, service, standard success/error responses, structured
logging, correlation id, security headers, unit tests, integration tests, API
docs, and - for external integrations - failure/timeout handling with no
sensitive data in logs).

## Docker

Built on Pode's own official image (`badgerati/pode:2.14.1-alpine`), which
already ships the exact Pode version `server.ps1` requires - no
`Install-Module` at build time. Keep the tag in the `Dockerfile`'s `FROM` line
in sync with the `#Requires -Modules` version in `server.ps1`.

```powershell
docker build -t opsbridge .
docker run --rm -p 8080:8080 -e API_ENVIRONMENT=Production opsbridge
```

The container binds `0.0.0.0:8080` by default and logs structured JSON to
stdout - no volume or persistent filesystem is required to run.

## CI-readiness

There is no CI pipeline configured yet (out of scope for this version), but
every step above is a single, scriptable command - `Invoke-ScriptAnalyzer`,
`Invoke-Pester -Configuration (./PesterConfiguration.ps1)`, `docker build` -
so wiring them into GitHub Actions/Azure DevOps/GitLab CI later is a matter of
calling them from a workflow file, not restructuring the project.
