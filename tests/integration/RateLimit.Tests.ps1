<#
.SYNOPSIS
    Integration tests for the in-process rate limiter (API_RATE_LIMIT_*).
.DESCRIPTION
    A single global fixed-window counter (src/middleware/RateLimit.ps1), not
    per-client - see docs/architecture.md. Each Describe below starts its own
    server since the limit is only configurable at startup.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $PSScriptRoot 'TestServer.ps1')
}

Describe 'Rate limiting - disabled (default)' {
    BeforeAll {
        $script:Server = Start-TestServer -RepoRoot $script:RepoRoot
    }

    AfterAll {
        Stop-TestServer -Server $script:Server
        Clear-TestServerEnv
    }

    It 'never rejects requests when API_RATE_LIMIT_ENABLED is not set' {
        1..20 | ForEach-Object {
            $r = Invoke-WebRequest -Uri "$($script:Server.BaseUrl)/health/live" -UseBasicParsing
            $r.StatusCode | Should -Be 200
        }
    }
}

Describe 'Rate limiting - enabled' {
    BeforeAll {
        $env:API_RATE_LIMIT_ENABLED = 'true'
        $env:API_RATE_LIMIT_REQUESTS = '5'
        $env:API_RATE_LIMIT_WINDOW_SECONDS = '3'
        $script:Server = Start-TestServer -RepoRoot $script:RepoRoot
        # Start-TestServer's own readiness poll against /health/live counts
        # against the same global counter it is about to test - the limiter
        # makes no exception for health checks. Let that window lapse before
        # any test below spends its own budget, so each starts clean.
        Start-Sleep -Seconds 4
    }

    AfterAll {
        Stop-TestServer -Server $script:Server
        Remove-Item Env:\API_RATE_LIMIT_ENABLED, Env:\API_RATE_LIMIT_REQUESTS, Env:\API_RATE_LIMIT_WINDOW_SECONDS -ErrorAction SilentlyContinue
        Clear-TestServerEnv
    }

    It 'allows requests within the limit' {
        1..5 | ForEach-Object {
            $r = Invoke-WebRequest -Uri "$($script:Server.BaseUrl)/health/live" -UseBasicParsing
            $r.StatusCode | Should -Be 200
        }
    }

    It 'rejects the next request over the limit with 429, Retry-After, and the standard error contract' {
        try {
            Invoke-WebRequest -Uri "$($script:Server.BaseUrl)/health/live" -UseBasicParsing
            throw 'Expected the request to fail with 429'
        }
        catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $resp = $_.Exception.Response
            $resp.StatusCode.value__ | Should -Be 429

            $retryAfter = $null
            $resp.Headers.TryGetValues('Retry-After', [ref]$retryAfter) | Out-Null
            $retryAfter | Should -Not -BeNullOrEmpty
            [int]($retryAfter -join '') | Should -BeGreaterThan 0

            $body = $_.ErrorDetails.Message | ConvertFrom-Json
            $body.error.code | Should -Be 'RATE_LIMIT_EXCEEDED'
            $body.error.category | Should -Be 'rate_limit'
            $body.error.retryable | Should -BeTrue
            $body.error.correlationId | Should -Not -BeNullOrEmpty
        }
    }

    It 'allows requests again once the window resets' {
        Start-Sleep -Seconds 4   # window is 3s
        $r = Invoke-WebRequest -Uri "$($script:Server.BaseUrl)/health/live" -UseBasicParsing
        $r.StatusCode | Should -Be 200
    }

    It 'enforces the limit correctly under real concurrent load (allows exactly up to the limit, rejects the rest)' {
        Start-Sleep -Seconds 4   # start from a fresh window
        $results = Invoke-ConcurrentGetRequests -BaseUrl $script:Server.BaseUrl -Path '/health/live' -Count 20

        ($results | Where-Object { $_.StatusCode -eq 200 }).Count | Should -Be 5
        ($results | Where-Object { $_.StatusCode -eq 429 }).Count | Should -Be 15
    }
}

Describe 'Rate limiting - invalid configuration' {
    It 'fails startup (fail-fast) on an invalid API_RATE_LIMIT_REQUESTS' {
        $env:API_RATE_LIMIT_ENABLED = 'true'
        $env:API_RATE_LIMIT_REQUESTS = '0'
        try {
            { Start-TestServer -RepoRoot $script:RepoRoot } | Should -Throw
        }
        finally {
            Remove-Item Env:\API_RATE_LIMIT_ENABLED, Env:\API_RATE_LIMIT_REQUESTS -ErrorAction SilentlyContinue
            Clear-TestServerEnv
        }
    }
}
