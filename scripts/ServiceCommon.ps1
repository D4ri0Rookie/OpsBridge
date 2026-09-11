<#
.SYNOPSIS
    Shared helpers for the Windows-service install/uninstall scripts.
.DESCRIPTION
    Get-PodeServiceDefinition is pure (given inputs -> the NSSM parameter set)
    so it can be unit-tested without touching the service control manager. The
    install/uninstall scripts are thin wrappers that apply the definition with
    nssm and handle elevation / prerequisite checks.

    Hosting via NSSM follows Pode's own recommendation - Pode 2.14.1 has no
    native service cmdlet.
#>

function Get-PodeServiceDefinition {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $ServiceName,

        [Parameter(Mandatory = $true)]
        [string]
        $RepoRoot,

        [Parameter()]
        [string]
        $PwshPath,

        [Parameter()]
        [hashtable]
        $Environment = @{}
    )

    if (-not $PwshPath) {
        $PwshPath = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty Source
    }
    if (-not $PwshPath) {
        throw 'Could not locate pwsh on PATH; pass -PwshPath explicitly.'
    }

    $serverScript = Join-Path $RepoRoot 'server.ps1'
    $logDir = Join-Path $RepoRoot 'logs'

    # The service runs headless, so daemon mode is the default. An explicit
    # API_DAEMON passed in -Environment still wins (same key overwrites).
    $envVars = [ordered]@{ API_DAEMON = 'true' }
    foreach ($key in ($Environment.Keys | Sort-Object)) {
        $envVars[$key] = "$($Environment[$key])"
    }

    return @{
        ServiceName         = $ServiceName
        Application         = $PwshPath
        AppParameters       = "-NoProfile -File `"$serverScript`""
        AppDirectory        = $RepoRoot
        AppStdout           = (Join-Path $logDir 'service-stdout.log')
        AppStderr           = (Join-Path $logDir 'service-stderr.log')
        AppEnvironmentExtra = @($envVars.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
        AppExitAction       = 'Restart'
        AppRestartDelayMs   = 5000
    }
}

function Test-IsAdministrator {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not $IsWindows) {
        return $false
    }

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-NssmAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return [bool](Get-Command -Name 'nssm' -CommandType Application -ErrorAction SilentlyContinue)
}
