<#
.SYNOPSIS
    GET /api/v1/windows/services - reference implementation for the
    Pode -> middleware -> route -> service pattern (docs/architecture.md).
.DESCRIPTION
    Optional query parameter: name (exact service name or wildcard, e.g. "wuau*").
    This route only validates input, calls the service, and maps its result to
    an HTTP response/error - all automation logic lives in
    src/services/Windows/Get-WindowsServices.ps1.

    Status codes:
      200 - services returned (possibly an empty array, when Name is a wildcard
            that matches nothing)
      404 - Name was a specific, non-wildcard service that does not exist
      422 - Name was supplied but blank, or longer than 256 characters
      503 - the Windows Service Control Manager is not available on this host
#>

Add-AppRoute -Method Get -Path '/api/v1/windows/services' -ScriptBlock {
    $name = $null
    if ($WebEvent.Query.ContainsKey('name')) {
        $name = $WebEvent.Query['name']
        if ([string]::IsNullOrWhiteSpace($name)) {
            Send-ApiError -StatusCode 422 -Code 'VALIDATION_ERROR' -Message 'The request contains invalid parameters.' -Details @(@{ field = 'name'; code = 'EMPTY' }) -Category 'validation' -Retryable $false
            return
        }
        # No legitimate Windows service name comes close to 256 characters;
        # checked here so an oversized query value fails fast with a clear
        # 422 instead of flowing into Get-Service and into the (reflected)
        # 404 message / logs. Mirrors the same fail-fast-on-length approach
        # the correlation id validator already uses.
        if ($name.Length -gt 256) {
            Send-ApiError -StatusCode 422 -Code 'VALIDATION_ERROR' -Message 'The request contains invalid parameters.' -Details @(@{ field = 'name'; code = 'TOO_LONG' }) -Category 'validation' -Retryable $false
            return
        }
    }

    Write-AppLog -Level Info -Event 'service.operation.started' -Data @{ service = 'Windows'; operation = 'GetServices' }
    $operationStart = [datetime]::UtcNow

    $result = Get-OpsBridgeWindowsServices -Name $name
    $durationMs = [math]::Round(([datetime]::UtcNow - $operationStart).TotalMilliseconds, 2)

    if (-not $result.Supported) {
        Write-AppLog -Level Warning -Event 'service.operation.failed' -Data @{ service = 'Windows'; operation = 'GetServices'; durationMs = $durationMs; reason = 'unsupported-platform' }
        Send-ApiError -StatusCode 503 -Code 'WINDOWS_SERVICE_MANAGER_UNAVAILABLE' -Message 'The Windows Service Control Manager is not available on this host.'
        return
    }

    if ($name -and $result.Services.Count -eq 0) {
        Write-AppLog -Level Info -Event 'service.operation.completed' -Data @{ service = 'Windows'; operation = 'GetServices'; durationMs = $durationMs; count = 0 }
        Send-ApiError -StatusCode 404 -Code 'SERVICE_NOT_FOUND' -Message "No service matching '$name' was found."
        return
    }

    Write-AppLog -Level Info -Event 'service.operation.completed' -Data @{ service = 'Windows'; operation = 'GetServices'; durationMs = $durationMs; count = $result.Services.Count }
    Write-PodeJsonResponse -StatusCode 200 -Value @{ data = $result.Services }
}

<#
.SYNOPSIS
    GET /api/v1/windows/processes - second capability, same
    Pode -> middleware -> route -> service pattern as the endpoint above.
.DESCRIPTION
    Optional query parameter: name (exact process name or wildcard).
    Status codes:
      200 - processes returned (possibly an empty array, when Name is a
            wildcard that matches nothing)
      404 - Name was a specific, non-wildcard process that does not exist
      422 - Name was supplied but blank, or longer than 256 characters
    No 503 branch: unlike Get-Service, Get-Process is cross-platform, so
    there is no "unsupported platform" outcome to report.
#>
Add-AppRoute -Method Get -Path '/api/v1/windows/processes' -ScriptBlock {
    $name = $null
    if ($WebEvent.Query.ContainsKey('name')) {
        $name = $WebEvent.Query['name']
        if ([string]::IsNullOrWhiteSpace($name)) {
            Send-ApiError -StatusCode 422 -Code 'VALIDATION_ERROR' -Message 'The request contains invalid parameters.' -Details @(@{ field = 'name'; code = 'EMPTY' }) -Category 'validation' -Retryable $false
            return
        }
        if ($name.Length -gt 256) {
            Send-ApiError -StatusCode 422 -Code 'VALIDATION_ERROR' -Message 'The request contains invalid parameters.' -Details @(@{ field = 'name'; code = 'TOO_LONG' }) -Category 'validation' -Retryable $false
            return
        }
    }

    Write-AppLog -Level Info -Event 'service.operation.started' -Data @{ service = 'Windows'; operation = 'GetProcesses' }
    $operationStart = [datetime]::UtcNow

    $result = Get-OpsBridgeWindowsProcesses -Name $name
    $durationMs = [math]::Round(([datetime]::UtcNow - $operationStart).TotalMilliseconds, 2)

    if ($name -and $result.Processes.Count -eq 0) {
        Write-AppLog -Level Info -Event 'service.operation.completed' -Data @{ service = 'Windows'; operation = 'GetProcesses'; durationMs = $durationMs; count = 0 }
        Send-ApiError -StatusCode 404 -Code 'PROCESS_NOT_FOUND' -Message "No process matching '$name' was found."
        return
    }

    Write-AppLog -Level Info -Event 'service.operation.completed' -Data @{ service = 'Windows'; operation = 'GetProcesses'; durationMs = $durationMs; count = $result.Processes.Count }
    Write-PodeJsonResponse -StatusCode 200 -Value @{ data = $result.Processes }
}
