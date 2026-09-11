<#
.SYNOPSIS
    Start OpsBridge in the background as a PowerShell job.
.DESCRIPTION
    Convenience wrapper for local use. Returns the job object.
#>

$repoRoot = Split-Path -Parent $PSScriptRoot

$job = Start-Job -Name 'OpsBridge' -ScriptBlock {
    Set-Location $using:repoRoot
    & (Join-Path $using:repoRoot 'server.ps1')
}

Write-Host "OpsBridge started in background (Job ID: $($job.Id))"
Write-Host ''
Write-Host 'Manage the job:'
Write-Host "  Get-Job    -Id $($job.Id)"
Write-Host "  Receive-Job -Id $($job.Id)"
Write-Host "  Stop-Job   -Id $($job.Id)"
Write-Host "  Remove-Job -Id $($job.Id)"

return $job
