<#
.SYNOPSIS
    Global in-flight request limit (API_MAX_IN_FLIGHT_REQUESTS, docs/configuration.md).
.DESCRIPTION
    One process-wide counter, not per-route/per-identity - see
    docs/architecture.md for why this stops there.

    Uses a [System.Threading.SemaphoreSlim], not a plain counter: Pode runs
    requests across multiple runspaces (API_THREADS), so a plain "read,
    compare, write" counter would race. Wait(0)/Release() are atomic, so
    there is no locking to get wrong.

    One instance, created at startup and shared via Set-PodeState (src/App.ps1)
    - Get-PodeState returns the same object in every runspace, not a copy.

    Acquiring (this middleware) and releasing (the endware below) are
    separate, because Pode middleware can't wrap the route handler itself.
    The release endware runs after every request regardless of outcome - same
    as src/middleware/RequestLogging.ps1's - so a slot is always released
    exactly once, whether the request succeeded, errored, or threw.
#>

function Add-ConcurrencyLimitMiddleware {
    Add-PodeMiddleware -Name 'ConcurrencyLimit' -ScriptBlock {
        try {
            $semaphore = Get-PodeState -Name 'ConcurrencySemaphore'
            if ($semaphore.Wait(0)) {
                $WebEvent.Data.ConcurrencySlotAcquired = $true
                return $true
            }

            Write-AppLog -Level Warning -Event 'application.overloaded' -Data @{ maxInFlightRequests = $semaphore.CurrentCount }
            Send-ApiError -StatusCode 503 -Code 'OVERLOADED' -Message 'The server is at capacity. Try again later.' -Category 'overload' -Retryable $true
            return $false
        }
        catch {
            # Fail open: never let the limiter itself break every request.
            Write-AppErrorLog -Exception $_.Exception
            return $true
        }
    }
}

function Add-ConcurrencyReleaseEndware {
    Add-PodeEndware -ScriptBlock {
        if ($null -eq $WebEvent -or -not $WebEvent.Data.ConcurrencySlotAcquired) {
            return
        }

        try {
            $semaphore = Get-PodeState -Name 'ConcurrencySemaphore'
            $semaphore.Release() | Out-Null
        }
        catch {
            $null = $_
        }
    }
}
