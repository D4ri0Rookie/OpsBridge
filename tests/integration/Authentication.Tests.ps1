<#
.SYNOPSIS
    Integration tests for API key authentication (API_AUTH_*).
.DESCRIPTION
    Disabled by default (docs/configuration.md) - the first Describe proves
    existing behavior is unchanged when it is off. Each Describe below starts
    its own server since auth is only configurable at startup.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $PSScriptRoot 'TestServer.ps1')
}

Describe 'Authentication - disabled (default)' {
    BeforeAll {
        $script:Server = Start-TestServer -RepoRoot $script:RepoRoot
    }

    AfterAll {
        Stop-TestServer -Server $script:Server
        Clear-TestServerEnv
    }

    It 'serves a capability endpoint with no X-Api-Key header' {
        $r = Invoke-WebRequest -Uri "$($script:Server.BaseUrl)/api/v1/windows/processes" -UseBasicParsing
        $r.StatusCode | Should -Be 200
    }
}

Describe 'Authentication - enabled' {
    BeforeAll {
        $env:API_AUTH_ENABLED = 'true'
        $env:API_AUTH_KEYS = 'key-one, key-two'
        $script:Server = Start-TestServer -RepoRoot $script:RepoRoot
    }

    AfterAll {
        Stop-TestServer -Server $script:Server
        Remove-Item Env:\API_AUTH_ENABLED, Env:\API_AUTH_KEYS -ErrorAction SilentlyContinue
        Clear-TestServerEnv
    }

    It 'rejects a capability request with no X-Api-Key header' {
        try {
            Invoke-WebRequest -Uri "$($script:Server.BaseUrl)/api/v1/windows/processes" -UseBasicParsing
            throw 'Expected the request to fail with 401'
        }
        catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $resp = $_.Exception.Response
            $resp.StatusCode.value__ | Should -Be 401
            (Get-ErrorHeaderValue $resp 'WWW-Authenticate') | Should -Match 'ApiKey'

            $body = $_.ErrorDetails.Message | ConvertFrom-Json
            $body.error.code | Should -Be 'UNAUTHORIZED'
            $body.error.category | Should -Be 'auth'
            $body.error.retryable | Should -BeFalse
            $body.error.correlationId | Should -Not -BeNullOrEmpty
        }
    }

    It 'rejects a capability request with a wrong X-Api-Key' {
        try {
            Invoke-WebRequest -Uri "$($script:Server.BaseUrl)/api/v1/windows/processes" -Headers @{ 'X-Api-Key' = 'not-a-real-key' } -UseBasicParsing
            throw 'Expected the request to fail with 401'
        }
        catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $_.Exception.Response.StatusCode.value__ | Should -Be 401
        }
    }

    It 'accepts a capability request with the configured key' {
        $r = Invoke-WebRequest -Uri "$($script:Server.BaseUrl)/api/v1/windows/processes" -Headers @{ 'X-Api-Key' = 'key-one' } -UseBasicParsing
        $r.StatusCode | Should -Be 200
    }

    It 'accepts any one of several configured keys (rotation: old and new both work)' {
        $r = Invoke-WebRequest -Uri "$($script:Server.BaseUrl)/api/v1/windows/processes" -Headers @{ 'X-Api-Key' = 'key-two' } -UseBasicParsing
        $r.StatusCode | Should -Be 200
    }

    It 'still serves /health/live with no key - probes are exempt' {
        $r = Invoke-WebRequest -Uri "$($script:Server.BaseUrl)/health/live" -UseBasicParsing
        $r.StatusCode | Should -Be 200
    }

    It 'still serves /health/ready with no key - probes are exempt' {
        $r = Invoke-WebRequest -Uri "$($script:Server.BaseUrl)/health/ready" -UseBasicParsing
        $r.StatusCode | Should -Be 200
    }

    It 'rejects an unmatched path with 401, not 404 - auth runs before any route, including the catch-all' {
        try {
            Invoke-WebRequest -Uri "$($script:Server.BaseUrl)/does-not-exist" -UseBasicParsing
            throw 'Expected the request to fail with 401'
        }
        catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $_.Exception.Response.StatusCode.value__ | Should -Be 401
        }
    }
}

Describe 'Authentication - invalid configuration' {
    It 'fails startup (fail-fast) when enabled with no keys configured' {
        $env:API_AUTH_ENABLED = 'true'
        try {
            { Start-TestServer -RepoRoot $script:RepoRoot } | Should -Throw
        }
        finally {
            Remove-Item Env:\API_AUTH_ENABLED -ErrorAction SilentlyContinue
            Clear-TestServerEnv
        }
    }
}
