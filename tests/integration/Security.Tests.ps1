<#
.SYNOPSIS
    Integration tests for the security response headers (src/middleware/SecurityHeaders.ps1).
    Asserted on both a normal 200 and a 404, since the middleware must run for
    every response regardless of outcome.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $PSScriptRoot 'TestServer.ps1')
    $script:Server = Start-TestServer -RepoRoot $script:RepoRoot
    $script:BaseUrl = $script:Server.BaseUrl
}

AfterAll {
    Stop-TestServer -Server $script:Server
    Clear-TestServerEnv
}

Describe 'Security headers on a normal response' {
    BeforeAll { $script:Resp = Invoke-WebRequest -Uri "$script:BaseUrl/health/live" -UseBasicParsing }

    It 'sets a restrictive Content-Security-Policy' {
        (Get-HeaderValue $script:Resp 'Content-Security-Policy') | Should -Match "default-src 'none'"
    }

    It 'sets X-Content-Type-Options: nosniff' {
        (Get-HeaderValue $script:Resp 'X-Content-Type-Options') | Should -Be 'nosniff'
    }

    It 'sets X-Frame-Options: DENY' {
        (Get-HeaderValue $script:Resp 'X-Frame-Options') | Should -Be 'DENY'
    }

    It 'sets a strict Referrer-Policy' {
        (Get-HeaderValue $script:Resp 'Referrer-Policy') | Should -Be 'strict-origin-when-cross-origin'
    }

    It 'sets Cache-Control: no-store' {
        (Get-HeaderValue $script:Resp 'Cache-Control') | Should -Be 'no-store'
    }

    It 'normalises the Server header (no framework/version fingerprint)' {
        (Get-HeaderValue $script:Resp 'Server') | Should -Be 'OpsBridge'
    }

    It 'does not set Strict-Transport-Security over plain HTTP' {
        # Advertising HSTS on a host that isn't actually serving HTTPS would
        # be actively wrong, not just unnecessary - see tests/integration/Https.Tests.ps1
        # for the positive case.
        (Get-HeaderValue $script:Resp 'Strict-Transport-Security') | Should -BeNullOrEmpty
    }
}

Describe 'Security headers on an error response' {
    It 'are present on a 404 too' {
        try {
            Invoke-WebRequest -Uri "$script:BaseUrl/does-not-exist" -UseBasicParsing
            throw 'Expected the request to fail with 404'
        }
        catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $resp = $_.Exception.Response
            (Get-ErrorHeaderValue $resp 'X-Frame-Options') | Should -Be 'DENY'
            (Get-ErrorHeaderValue $resp 'X-Content-Type-Options') | Should -Be 'nosniff'
        }
    }
}
