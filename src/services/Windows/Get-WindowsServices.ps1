<#
.SYNOPSIS
    Windows service enumeration - the automation logic behind
    GET /api/v1/windows/services.
.DESCRIPTION
    Get-OpsBridgeWindowsServices has no Pode/HTTP dependency: it takes a plain
    optional name filter and returns a plain result object, so it is unit
    testable independently of any running server. The route in
    src/routes/v1/Windows.ps1 only translates its result into an HTTP response
    - it contains no automation logic itself.

    "Not found" and "unsupported platform" are returned as data (Supported /
    Services), not thrown as exceptions: both are expected, common outcomes for
    this endpoint, not exceptional failures - the route decides the HTTP status
    for each.
#>

function Invoke-OpsBridgeGetService {
    <#
        Thin wrapper around the built-in Get-Service, kept only so it can be
        mocked in tests. Get-Service is a Windows-only cmdlet: on a host where
        it does not exist at all (as opposed to "installed but not imported"),
        Pester cannot create a mock for it directly - it can only mock a
        command that resolves to something. Wrapping it in a function we
        control, which always exists, makes the service testable on any OS
        that runs the test suite.
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

    return @(Get-Service @params)
}

function Get-OpsBridgeWindowsServices {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # Optional exact service name or wildcard filter, forwarded to
        # Get-Service -Name.
        [Parameter()]
        [string]
        $Name,

        # Defaults to the real platform check. Overridable so unit tests can
        # exercise both branches deterministically regardless of which OS runs
        # the test suite (see tests/unit/WindowsServices.Tests.ps1) - not meant
        # to be passed by route/production code.
        [Parameter()]
        [bool]
        $IsSupportedPlatform = $IsWindows
    )

    if (-not $IsSupportedPlatform) {
        return [pscustomobject]@{ Supported = $false; Services = @() }
    }

    $services = @(Invoke-OpsBridgeGetService -Name $Name)

    $shaped = @($services | ForEach-Object {
            [ordered]@{
                name        = $_.Name
                displayName = $_.DisplayName
                status      = "$($_.Status)"
                startType   = "$($_.StartType)"
            }
        })

    return [pscustomobject]@{ Supported = $true; Services = $shaped }
}
