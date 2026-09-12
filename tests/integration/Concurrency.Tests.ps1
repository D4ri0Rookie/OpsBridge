<#
.SYNOPSIS
    Integration tests for the in-flight concurrency limit (API_MAX_IN_FLIGHT_REQUESTS).
.DESCRIPTION
    src/middleware/Concurrency.ps1 releases a slot in an endware that runs
    unconditionally after every request (success, a business error like 404,
    or a route exception turned into 500 by src/App.ps1's route wrapper) -
    there is no separate release path per outcome, so exercising success and
    an error status (404) below covers the same release code an exception
    would hit; OpsBridge has no route that deliberately throws to exercise
    that literal case without adding one for the sole purpose of this test.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $PSScriptRoot 'TestServer.ps1')   # brings in Invoke-ConcurrentGetRequests
}

Describe 'Concurrency limit - under/at capacity' {
    BeforeAll {
        $env:API_MAX_IN_FLIGHT_REQUESTS = '2'
        $script:Server = Start-TestServer -RepoRoot $script:RepoRoot
    }

    AfterAll {
        Stop-TestServer -Server $script:Server
        Remove-Item Env:\API_MAX_IN_FLIGHT_REQUESTS -ErrorAction SilentlyContinue
        Clear-TestServerEnv
    }

    It 'serves a request under capacity normally' {
        $r = Invoke-WebRequest -Uri "$($script:Server.BaseUrl)/health/live" -UseBasicParsing
        $r.StatusCode | Should -Be 200
    }

    It 'releases the slot after success - many sequential requests never exhaust capacity' {
        # One at a time, well beyond the limit of 2: only proves "no permanent
        # loss" if each request's slot is actually freed before the next fires.
        1..20 | ForEach-Object {
            $r = Invoke-WebRequest -Uri "$($script:Server.BaseUrl)/health/live" -UseBasicParsing
            $r.StatusCode | Should -Be 200
        }
    }

    It 'releases the slot after a non-exception error response (404) - capacity still available afterwards' {
        Invoke-WebRequest -Uri "$($script:Server.BaseUrl)/does-not-exist" -UseBasicParsing -SkipHttpErrorCheck | Out-Null
        $r = Invoke-WebRequest -Uri "$($script:Server.BaseUrl)/health/live" -UseBasicParsing
        $r.StatusCode | Should -Be 200
    }
}

Describe 'Concurrency limit - over capacity under real concurrent load' {
    BeforeAll {
        $env:API_MAX_IN_FLIGHT_REQUESTS = '1'
        $env:API_THREADS = '5'
        $script:Server = Start-TestServer -RepoRoot $script:RepoRoot
    }

    AfterAll {
        Stop-TestServer -Server $script:Server
        Remove-Item Env:\API_MAX_IN_FLIGHT_REQUESTS, Env:\API_THREADS -ErrorAction SilentlyContinue
        Clear-TestServerEnv
    }

    It 'rejects at least one request with 503 OVERLOADED when concurrent load exceeds the single-slot limit, while others still succeed' {
        $results = Invoke-ConcurrentGetRequests -BaseUrl $script:Server.BaseUrl -Path '/health/live' -Count 30

        ($results | Where-Object { $_.StatusCode -eq 200 }).Count | Should -BeGreaterThan 0
        $rejected = @($results | Where-Object { $_.StatusCode -eq 503 })
        $rejected.Count | Should -BeGreaterThan 0

        $body = $rejected[0].Body | ConvertFrom-Json
        $body.error.code | Should -Be 'OVERLOADED'
        $body.error.category | Should -Be 'overload'
        $body.error.retryable | Should -BeTrue
        $body.error.correlationId | Should -Not -BeNullOrEmpty
    }
}
