<#
.SYNOPSIS
    In-process rate limiting (API_RATE_LIMIT_*, docs/configuration.md).
.DESCRIPTION
    One global fixed-window counter - not per-client (see
    docs/architecture.md), and not a token bucket: a fixed window ("at
    most N requests per W seconds, then reset") is the simplest algorithm
    that is still deterministic. Disabled by default.

    State lives in one [hashtable]::Synchronized(...), created at startup and
    shared via Set-PodeState (src/App.ps1), same as the concurrency semaphore
    (src/middleware/Concurrency.ps1). A synchronized hashtable only makes a
    single read/write atomic, not the "check window, maybe reset, increment"
    sequence below - that whole sequence runs inside a Monitor lock on the
    hashtable's own SyncRoot.

    Registered after Correlation ID/Security Headers but before the
    concurrency gate (src/App.ps1): a request rejected here should not also
    take up a concurrency slot.
#>

function Add-RateLimitMiddleware {
    Add-PodeMiddleware -Name 'RateLimit' -ScriptBlock {
        try {
            $config = Get-PodeState -Name 'AppConfig'
            if (-not $config.RateLimitEnabled) {
                return $true
            }

            $state = Get-PodeState -Name 'RateLimitState'
            $allowed = $true
            $retryAfterSeconds = 0

            [System.Threading.Monitor]::Enter($state.SyncRoot)
            try {
                $now = [datetime]::UtcNow
                $windowSeconds = $config.RateLimitWindowSeconds

                if (($now - $state.WindowStart).TotalSeconds -ge $windowSeconds) {
                    $state.WindowStart = $now
                    $state.Count = 0
                }

                if ($state.Count -ge $config.RateLimitRequests) {
                    $allowed = $false
                    $elapsedSeconds = ($now - $state.WindowStart).TotalSeconds
                    $retryAfterSeconds = [Math]::Max(1, [Math]::Ceiling($windowSeconds - $elapsedSeconds))
                }
                else {
                    $state.Count++
                }
            }
            finally {
                [System.Threading.Monitor]::Exit($state.SyncRoot)
            }

            if (-not $allowed) {
                Write-AppLog -Level Warning -Event 'application.rate_limited' -Data @{ limit = $config.RateLimitRequests; windowSeconds = $config.RateLimitWindowSeconds }
                Set-PodeHeader -Name 'Retry-After' -Value "$retryAfterSeconds"
                Send-ApiError -StatusCode 429 -Code 'RATE_LIMIT_EXCEEDED' -Message 'Request rate limit exceeded.' -Category 'rate_limit' -Retryable $true
                return $false
            }

            return $true
        }
        catch {
            # Fail open: never let the limiter itself break every request.
            Write-AppErrorLog -Exception $_.Exception
            return $true
        }
    }
}
