<#
.SYNOPSIS
    Integration tests for the request body size limit (API_MAX_BODY_BYTES).
.DESCRIPTION
    OpsBridge has no route that accepts a body today, so these tests send a
    POST to /health/live: the body-size check runs before routing, so the
    response is either the catch-all 404 (body accepted, request just didn't
    match a POST route) or 413 (body rejected) - either way proves whether the
    limit was enforced, without needing a body-accepting endpoint.

    Each test starts its own server since the limit is only overridable at
    startup (see New-RuntimeServerConfigFile in src/App.ps1).
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $PSScriptRoot 'TestServer.ps1')
}

Describe 'Request body size limit - default (no override)' {
    BeforeAll {
        $script:Server = Start-TestServer -RepoRoot $script:RepoRoot
    }

    AfterAll {
        Stop-TestServer -Server $script:Server
        Clear-TestServerEnv
    }

    It 'accepts a small body unaffected by the limit (current behaviour preserved)' {
        $r = Invoke-WebRequest -Uri "$($script:Server.BaseUrl)/health/live" -Method Post -Body 'small-body' -UseBasicParsing -SkipHttpErrorCheck
        $r.StatusCode | Should -Be 404   # catch-all: no POST route registered, not a body-size rejection
    }
}

Describe 'Request body size limit - API_MAX_BODY_BYTES override' {
    BeforeAll {
        $env:API_MAX_BODY_BYTES = '1000'
        $script:Server = Start-TestServer -RepoRoot $script:RepoRoot
    }

    AfterAll {
        Stop-TestServer -Server $script:Server
        Remove-Item Env:\API_MAX_BODY_BYTES -ErrorAction SilentlyContinue
        Clear-TestServerEnv
    }

    It 'accepts a body under the limit' {
        $r = Invoke-WebRequest -Uri "$($script:Server.BaseUrl)/health/live" -Method Post -Body ('a' * 500) -UseBasicParsing -SkipHttpErrorCheck
        $r.StatusCode | Should -Be 404
    }

    It 'accepts a body exactly at the limit' {
        $r = Invoke-WebRequest -Uri "$($script:Server.BaseUrl)/health/live" -Method Post -Body ('a' * 1000) -UseBasicParsing -SkipHttpErrorCheck
        $r.StatusCode | Should -Be 404
    }

    It 'rejects a body over the limit with 413 and the standard error contract' {
        try {
            Invoke-WebRequest -Uri "$($script:Server.BaseUrl)/health/live" -Method Post -Body ('a' * 2000) -UseBasicParsing
            throw 'Expected the request to fail with 413'
        }
        catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $_.Exception.Response.StatusCode.value__ | Should -Be 413
            $body = $_.ErrorDetails.Message | ConvertFrom-Json
            $body.error.code | Should -Be 'PAYLOAD_TOO_LARGE'
            $body.error.category | Should -Be 'validation'
            $body.error.retryable | Should -BeFalse
        }
    }
}

Describe 'Request body size limit - invalid configuration' {
    It 'fails startup (fail-fast) instead of serving with a broken limit' {
        $env:API_MAX_BODY_BYTES = '0'
        try {
            { Start-TestServer -RepoRoot $script:RepoRoot } | Should -Throw
        }
        finally {
            Remove-Item Env:\API_MAX_BODY_BYTES -ErrorAction SilentlyContinue
            Clear-TestServerEnv
        }
    }
}
