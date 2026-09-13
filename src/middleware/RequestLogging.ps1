<#
.SYNOPSIS
    HTTP request/response logging endware.
.DESCRIPTION
    Registers a Pode endware that writes one structured entry per request to the
    'RequestLog' log type (see src/logging/Logging.ps1) - method, path, status, duration,
    correlation id. The endware runs at the end of every request, including a 404
    (handled by the catch-all route src/routes/NotFound.ps1), so every response is
    logged consistently regardless of how it was produced.

    Get-ClientIp lives here (not a separate file) because request logging is its
    only consumer - OpsBridge does not do IP-based rate limiting or access
    control. Not X-Forwarded-For-aware: behind a reverse proxy this returns the
    proxy's address, not the real client's.
#>

function Get-ClientIp {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # $WebEvent is read from the surrounding scope, as at runtime inside a Pode
    # request (the same pattern as Get-CorrelationId). Read from
    # Request.Handler.RemoteEndPoint, which Pode populates at connection-accept
    # time - unlike $WebEvent.Request.RemoteEndPoint, which can be null for a
    # request short-circuited before it reached a route.
    if ($null -eq $WebEvent -or $null -eq $WebEvent.Request) {
        return $null
    }

    $endPoint = $WebEvent.Request.Handler.RemoteEndPoint
    if ($endPoint -and $endPoint.Address) {
        return $endPoint.Address.IPAddressToString
    }

    return $null
}

function Add-RequestLoggingEndware {
    Add-PodeEndware -ScriptBlock {
        try {
            if ($null -eq $WebEvent) {
                return
            }

            $durationMs = $null
            if ($WebEvent.Timestamp) {
                try {
                    $durationMs = [math]::Round(([datetime]::UtcNow - $WebEvent.Timestamp).TotalMilliseconds, 2)
                }
                catch {
                    $durationMs = $null
                }
            }

            $statusCode = $WebEvent.Response.StatusCode
            $failed = $statusCode -ge 500

            $item = @{
                Timestamp     = (Get-AppTimestamp)
                Event         = if ($failed) { 'http.request.failed' } else { 'http.request.completed' }
                CorrelationId = (Get-CorrelationId)
                Method        = "$($WebEvent.Method)"
                Path          = "$($WebEvent.Path)"
                StatusCode    = $statusCode
                DurationMs    = $durationMs
                ClientIp      = (Get-ClientIp)
            }
            if ($WebEvent.Data.ErrorType) {
                # Set by Send-ApiError (src/errors/Errors.ps1) - present on every
                # non-2xx response, absent on success.
                $item.ErrorType = $WebEvent.Data.ErrorType
            }
            if ($WebEvent.Data.TimedOut) {
                # Set by src/App.ps1's route wrapper when a handler ran past
                # API_REQUEST_TIMEOUT_SECONDS - a soft budget, so this marks a
                # slow request in the log without changing its status code.
                $item.TimedOut = $true
            }

            Write-PodeLog -Name 'RequestLog' -Level $(if ($failed) { 'Error' } else { 'Informational' }) -InputObject $item
        }
        catch {
            # Never let request logging affect the response.
            $null = $_
        }
    }
}
