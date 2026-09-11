<#
.SYNOPSIS
    Simple, dependency-free load test for OpsBridge.
.DESCRIPTION
    Fires a configurable number of concurrent requests at an endpoint and
    reports the status code distribution and latency stats (min/avg/p95/max).
.EXAMPLE
    .\scripts\load-test.ps1
.EXAMPLE
    .\scripts\load-test.ps1 -BaseUrl http://localhost:9000 -Path /api/v1/windows/services -TotalRequests 500 -Concurrency 25
#>
[CmdletBinding()]
# InjectionHunter flags $using: inside ForEach-Object -Parallel as a generic
# property-injection risk - correct when the value crosses a trust boundary,
# but $Url here is a parameter the operator running this script supplies
# themselves (a load-test target), never data from an inbound request.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('InjectionRisk.ForeachObjectInjection', '', Justification = 'Operator-supplied CLI parameter, not request/network data.')]
param(
    [string]$BaseUrl = 'http://localhost:8080',
    [string]$Path = '/health/live',
    [int]$TotalRequests = 200,
    [int]$Concurrency = 10
)

$url = "$BaseUrl$Path"
Write-Host "Load testing $url" -ForegroundColor Cyan
Write-Host "   Requests: $TotalRequests - Concurrency: $Concurrency" -ForegroundColor Cyan
Write-Host ""

$results = 1..$TotalRequests | ForEach-Object -Parallel {
    $target = $using:url
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-WebRequest -Uri $target -UseBasicParsing -TimeoutSec 10
        $sw.Stop()
        [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            ElapsedMs  = $sw.Elapsed.TotalMilliseconds
            Error      = $null
        }
    }
    catch {
        $sw.Stop()
        $statusCode = $null
        if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
        [pscustomobject]@{
            StatusCode = $statusCode
            ElapsedMs  = $sw.Elapsed.TotalMilliseconds
            # A non-2xx status (404/500/...) is a real HTTP response, not a
            # failure - only flag it as an error when there was no response at
            # all (connection refused, timeout, DNS failure, ...).
            Error      = if ($statusCode) { $null } else { $_.Exception.Message }
        }
    }
} -ThrottleLimit $Concurrency

Write-Host "Status codes" -ForegroundColor Cyan
Write-Host "============" -ForegroundColor Cyan
$results | Group-Object StatusCode | Sort-Object Name | ForEach-Object {
    $label = if ($_.Name) { $_.Name } else { 'ERROR (no response)' }
    Write-Host ("   {0,-24} {1,5} requests" -f $label, $_.Count)
}

$latencies = $results.ElapsedMs | Sort-Object
$p95Index = [Math]::Max(0, [Math]::Ceiling($latencies.Count * 0.95) - 1)
$stats = $latencies | Measure-Object -Minimum -Maximum -Average

Write-Host ""
Write-Host "Latency (ms)" -ForegroundColor Cyan
Write-Host "============" -ForegroundColor Cyan
Write-Host ("   min: {0:N1}   avg: {1:N1}   p95: {2:N1}   max: {3:N1}" -f `
        $stats.Minimum, $stats.Average, $latencies[$p95Index], $stats.Maximum)

$errorCount = ($results | Where-Object { $_.Error }).Count
if ($errorCount -gt 0) {
    Write-Host ""
    Write-Host "$errorCount request(s) failed outright (connection errors, timeouts)" -ForegroundColor Yellow
}
