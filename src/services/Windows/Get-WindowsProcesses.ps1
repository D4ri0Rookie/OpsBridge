<#
.SYNOPSIS
    Process enumeration - the automation logic behind
    GET /api/v1/windows/processes.
.DESCRIPTION
    Get-OpsBridgeWindowsProcesses has no Pode/HTTP dependency: it takes a
    plain optional name filter and returns a plain result object, so it is
    unit testable independently of any running server - same shape as
    src/services/Windows/Get-WindowsServices.ps1.

    Unlike Get-Service, Get-Process is genuinely cross-platform (reads
    /proc on Linux) - there is no "unsupported platform" branch here, that
    would be speculative for a cmdlet that already works everywhere this
    runtime runs.
#>

function Invoke-OpsBridgeGetProcess {
    <#
        Thin wrapper around the built-in Get-Process, kept only so it can be
        mocked in tests - same reasoning as Invoke-OpsBridgeGetService.
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter()]
        [string]
        $Name
    )

    $params = @{ ErrorAction = 'SilentlyContinue' }
    if ($Name) { $params.Name = $Name }

    return @(Get-Process @params)
}

function Get-OpsBridgeWindowsProcesses {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # Optional exact process name or wildcard filter, forwarded to
        # Get-Process -Name.
        [Parameter()]
        [string]
        $Name
    )

    $processes = @(Invoke-OpsBridgeGetProcess -Name $Name)

    # Id/ProcessName/WorkingSet64 only - .Path/.MainModule/.StartTime can
    # throw Win32Exception ("Access is denied") for a protected/system
    # process even when just reading, which Get-Service's shaping never has
    # to worry about; keeping to always-readable fields keeps this as
    # deterministic as the reference implementation.
    $shaped = @($processes | ForEach-Object {
            [ordered]@{
                id              = $_.Id
                name            = $_.ProcessName
                workingSetBytes = $_.WorkingSet64
            }
        })

    return [pscustomobject]@{ Processes = $shaped }
}
