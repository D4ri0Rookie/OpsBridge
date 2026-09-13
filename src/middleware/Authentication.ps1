<#
.SYNOPSIS
    API key authentication (API_AUTH_*, docs/configuration.md).
.DESCRIPTION
    Disabled by default, same posture as rate limiting/concurrency limiting -
    an explicit opt-in (API_AUTH_ENABLED=true), fail-fast at startup if
    enabled with no keys configured (src/config/Config.ps1).

    A static, operator-configured list of API keys (API_AUTH_KEYS,
    comma-separated) checked against the X-Api-Key request header - no user
    accounts, no token issuance/expiry/refresh, no per-key identity or
    authorization: every valid key can call every endpoint. Authorization
    (differentiating what a caller may do) is a separate, still-reserved
    slot in the pipeline (docs/architecture.md) - not built here, because
    every capability today is equally "safe"/read-only; add it when a
    capability actually needs to differentiate callers, not before.

    Registered after Rate Limit but before Concurrency Limit and any route
    (docs/architecture.md): rate limiting must still apply to a request
    before its credentials are checked - otherwise a flood of unauthenticated
    traffic would bypass it entirely - but an unauthenticated request must
    never occupy a concurrency slot doing no real work, and never reaches a
    route handler either (including the catch-all, so it gets 401 rather than
    leaking whether a path exists). /health/live and /health/ready are
    exempt: liveness/readiness probes (load balancers, orchestrators)
    typically cannot be configured with a credential, and they reveal
    nothing sensitive.

    Unlike every sibling middleware in this pipeline, this one fails CLOSED:
    RateLimit/Concurrency/Shutdown all "fail open" on an internal error
    (their worst case is serving one extra request). For authentication the
    equivalent would silently disable the gate on a bug - the one failure
    mode that must never happen quietly - so an error here still returns 401.
#>

function Test-ApiKeyValid {
    <#
        Pure - no Pode/$WebEvent - so it is unit-testable directly, same
        shape as Test-CorrelationIdFormat.

        Uses a constant-time comparison per candidate key: a plain -eq/-ceq
        string compare short-circuits on the first mismatched character,
        which leaks - via response timing - how many leading characters of a
        guess were correct, enough to brute-force a key one character at a
        time. FixedTimeEquals removes that signal. The length check before
        it is safe to short-circuit on: key length is not secret information
        the way its content is.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]
        $PresentedKey,

        [Parameter()]
        [AllowNull()]
        [string[]]
        $ValidKeys
    )

    if ([string]::IsNullOrEmpty($PresentedKey) -or -not $ValidKeys -or $ValidKeys.Count -eq 0) {
        return $false
    }

    $presentedBytes = [System.Text.Encoding]::UTF8.GetBytes($PresentedKey)
    foreach ($validKey in $ValidKeys) {
        $validBytes = [System.Text.Encoding]::UTF8.GetBytes($validKey)
        if ($presentedBytes.Length -eq $validBytes.Length -and
            [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($presentedBytes, $validBytes)) {
            return $true
        }
    }

    return $false
}

function Get-ApiAuthKeys {
    <#
        Reads API_AUTH_KEYS directly from the environment - never from
        Get-PodeState 'AppConfig' - at the one point it is actually needed.
        See the fail-fast note in src/config/Config.ps1.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    if (-not $env:API_AUTH_KEYS) {
        return @()
    }

    return @($env:API_AUTH_KEYS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Add-AuthenticationMiddleware {
    Add-PodeMiddleware -Name 'Authentication' -ScriptBlock {
        try {
            $config = Get-PodeState -Name 'AppConfig'
            if (-not $config.AuthEnabled) {
                return $true
            }

            if ($WebEvent.Path -in @('/health/live', '/health/ready')) {
                return $true
            }

            $presentedKey = $null
            if (Test-PodeHeader -Name 'X-Api-Key') {
                $presentedKey = Get-PodeHeader -Name 'X-Api-Key'
            }

            if (Test-ApiKeyValid -PresentedKey $presentedKey -ValidKeys (Get-ApiAuthKeys)) {
                return $true
            }

            Write-AppLog -Level Warning -Event 'application.unauthorized' -Data @{ path = "$($WebEvent.Path)" }
            Set-PodeHeader -Name 'WWW-Authenticate' -Value 'ApiKey'
            Send-ApiError -StatusCode 401 -Code 'UNAUTHORIZED' -Message 'A valid API key is required.' -Category 'auth' -Retryable $false
            return $false
        }
        catch {
            Write-AppErrorLog -Exception $_.Exception
            Send-ApiError -StatusCode 401 -Code 'UNAUTHORIZED' -Message 'A valid API key is required.' -Category 'auth' -Retryable $false
            return $false
        }
    }
}
