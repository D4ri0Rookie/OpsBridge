<#
.SYNOPSIS
    Health endpoints - intentionally outside API versioning (docs/api.md).
.DESCRIPTION
    GET /health/live  - liveness: the process is up and serving. Always 200,
                        never depends on external systems.
    GET /health/ready - readiness: application bootstrap completed. Returns 503
                        until src/App.ps1 sets the 'AppReady' state.

    /health/ready is structured so real dependency checks (currently none) can be
    added later as extra entries under "checks" without changing the contract.

    HEAD is registered alongside GET: monitoring probes and load balancers often
    issue HEAD, and src/routes/NotFound.ps1's catch-all would otherwise answer
    HEAD /health/* with a 404 (Pode does not auto-serve HEAD from a GET route).
#>

Add-AppRoute -Method Get, Head -Path '/health/live' -ScriptBlock {
    Write-PodeJsonResponse -StatusCode 200 -Value @{
        status = 'healthy'
        checks = @{ application = 'healthy' }
    }
}

Add-AppRoute -Method Get, Head -Path '/health/ready' -ScriptBlock {
    $ready = [bool](Get-PodeState -Name 'AppReady')

    Write-PodeJsonResponse -StatusCode $(if ($ready) { 200 } else { 503 }) -Value @{
        status = if ($ready) { 'healthy' } else { 'unhealthy' }
        checks = @{ application = if ($ready) { 'healthy' } else { 'initializing' } }
    }
}
