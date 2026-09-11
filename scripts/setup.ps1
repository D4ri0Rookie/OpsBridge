<#
.SYNOPSIS
    Environment setup and validation for OpsBridge.
.DESCRIPTION
    Checks PowerShell and Pode versions, installs Pode if missing, unblocks
    project files (Mark of the Web) and reports port availability. Does not
    create a logs directory - file logging is optional (API_LOG_DESTINATION)
    and never a startup requirement.
#>

Write-Host 'OpsBridge setup'
Write-Host '================'
Write-Host ''

# PowerShell version
$psVersion = $PSVersionTable.PSVersion
Write-Host "PowerShell version: $psVersion"
if ($psVersion -lt [version]'7.6') {
    Write-Host 'ERROR: PowerShell 7.6 or higher is required.'
    exit 1
}

# Pode module
$minPodeVersion = [version]'2.14.1'
Write-Host "Checking Pode module (>= $minPodeVersion)..."
$podeModule = Get-Module -ListAvailable Pode | Sort-Object Version -Descending | Select-Object -First 1
if ($podeModule -and $podeModule.Version -ge $minPodeVersion) {
    Write-Host "  Pode $($podeModule.Version) found."
}
else {
    if ($podeModule) {
        Write-Host "  Pode $($podeModule.Version) found, but $minPodeVersion or higher is required. Installing..."
    }
    else {
        Write-Host '  Pode module not found. Installing...'
    }
    try {
        Install-Module -Name Pode -RequiredVersion $minPodeVersion -Scope CurrentUser -Force -AllowClobber
        Write-Host '  Pode installed.'
    }
    catch {
        Write-Host "ERROR: failed to install Pode: $($_.Exception.Message)"
        Write-Host "  Try: Install-Module -Name Pode -RequiredVersion $minPodeVersion -Scope CurrentUser"
        exit 1
    }
}

$rootPath = Split-Path $PSScriptRoot -Parent

# Remove any "downloaded from the internet" flag (Mark of the Web) Windows may
# have attached to extracted files - e.g. from a ZIP download. Left in place,
# PowerShell's RemoteSigned execution policy silently blocks those specific
# files from loading, which surfaces as routes/features mysteriously missing
# at runtime rather than as a clear error.
Write-Host 'Unblocking project files...'
Get-ChildItem -Path $rootPath -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

# Port availability (default port only - informational)
try {
    $portTest = Test-NetConnection -ComputerName localhost -Port 8080 -InformationLevel Quiet -WarningAction SilentlyContinue
    if ($portTest) {
        Write-Host 'Note: port 8080 is already in use (override with API_PORT).'
    }
    else {
        Write-Host 'Port 8080 is available.'
    }
}
catch {
    Write-Host 'Port 8080 appears to be available.'
}

Write-Host ''
Write-Host 'Setup complete. Start the server with:'
Write-Host '  .\server.ps1                    (foreground)'
Write-Host '  .\scripts\start-background.ps1  (background job)'
Write-Host ''
Write-Host 'Endpoints:'
Write-Host '  GET /health/live               - liveness probe (JSON)'
Write-Host '  GET /health/ready              - readiness probe (JSON)'
Write-Host '  GET /api/v1/windows/services    - list Windows services (JSON)'
Write-Host '  *   /*                          - coherent JSON 404'
