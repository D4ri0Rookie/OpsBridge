<#
.SYNOPSIS
    Stop and remove the OpsBridge Windows service (NSSM).
.PARAMETER ServiceName
    Windows service name. Default 'OpsBridge'.
.EXAMPLE
    .\scripts\uninstall-service.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]
    $ServiceName = 'OpsBridge'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ServiceCommon.ps1')

if (-not $IsWindows) {
    Write-Host 'This script is Windows-only.'
    exit 1
}
if (-not (Test-IsAdministrator)) {
    Write-Host 'Run this from an elevated (Administrator) PowerShell prompt.'
    exit 1
}
if (-not (Test-NssmAvailable)) {
    Write-Host 'NSSM not found on PATH.'
    exit 1
}
if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
    Write-Host "Service '$ServiceName' is not installed - nothing to do."
    exit 0
}

if ($PSCmdlet.ShouldProcess($ServiceName, 'Stop and remove the Windows service')) {
    & nssm stop $ServiceName
    & nssm remove $ServiceName confirm
    Write-Host "Service '$ServiceName' removed."
}
