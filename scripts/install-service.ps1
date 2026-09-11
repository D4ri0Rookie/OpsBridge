<#
.SYNOPSIS
    Install OpsBridge as a Windows service using NSSM.
.DESCRIPTION
    Follows Pode's recommended hosting approach (NSSM). Requires an elevated
    prompt and nssm on PATH ('choco install nssm -y').
.PARAMETER ServiceName
    Windows service name. Default 'OpsBridge'.
.PARAMETER Environment
    Extra API_* values baked into the service environment, e.g.
    @{ API_PORT = '8080'; API_LOG_LEVEL = 'Info' }.
.PARAMETER Start
    Start the service immediately after installing.
.EXAMPLE
    .\scripts\install-service.ps1 -Environment @{ API_PORT = '8080' } -Start
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]
    $ServiceName = 'OpsBridge',

    [hashtable]
    $Environment = @{},

    [switch]
    $Start
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ServiceCommon.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not $IsWindows) {
    Write-Host 'This installer is Windows-only.'
    exit 1
}
if (-not (Test-IsAdministrator)) {
    Write-Host 'Run this from an elevated (Administrator) PowerShell prompt.'
    exit 1
}
if (-not (Test-NssmAvailable)) {
    Write-Host "NSSM not found on PATH. Install it with 'choco install nssm -y'."
    exit 1
}
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Write-Host "Service '$ServiceName' already exists. Remove it first: .\scripts\uninstall-service.ps1 -ServiceName $ServiceName"
    exit 1
}

$def = Get-PodeServiceDefinition -ServiceName $ServiceName -RepoRoot $repoRoot -Environment $Environment

if ($PSCmdlet.ShouldProcess($ServiceName, 'Install Windows service via NSSM')) {
    New-Item -ItemType Directory -Path (Join-Path $repoRoot 'logs') -Force | Out-Null

    & nssm install $ServiceName $def.Application $def.AppParameters
    & nssm set $ServiceName AppDirectory $def.AppDirectory
    & nssm set $ServiceName AppStdout $def.AppStdout
    & nssm set $ServiceName AppStderr $def.AppStderr
    & nssm set $ServiceName AppEnvironmentExtra @($def.AppEnvironmentExtra)
    & nssm set $ServiceName AppExit Default $def.AppExitAction
    & nssm set $ServiceName AppRestartDelay $def.AppRestartDelayMs
    & nssm set $ServiceName Start SERVICE_AUTO_START
    & nssm set $ServiceName DisplayName 'OpsBridge'
    & nssm set $ServiceName Description 'Lightweight internal REST API runtime for SysOps/DevOps automation (PowerShell + Pode).'

    Write-Host "Service '$ServiceName' installed:"
    Write-Host "  Application:  $($def.Application) $($def.AppParameters)"
    Write-Host "  Directory:    $($def.AppDirectory)"
    Write-Host "  Environment:  $($def.AppEnvironmentExtra -join '; ')"
    Write-Host "  On failure:   restart after $($def.AppRestartDelayMs) ms"

    if ($Start) {
        & nssm start $ServiceName
        Write-Host "Service started. Verify: Invoke-RestMethod http://localhost:<port>/health/ready"
    }
    else {
        Write-Host "Start it with:  Start-Service $ServiceName"
    }
}
