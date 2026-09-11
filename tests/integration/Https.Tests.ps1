<#
.SYNOPSIS
    Integration tests for the HTTPS endpoint (API_PROTOCOL=Https).
.DESCRIPTION
    Starts a real server process with a Pode-generated self-signed
    certificate (API_CERT_SELF_SIGNED=true) - good enough to prove the TLS
    code path in src/App.ps1 actually works end-to-end, without needing a real
    certificate file in the repo. Certificate-file loading
    (API_CERT_PATH/API_CERT_PASSWORD) and the pre-flight failure when it is
    missing are covered by unit tests (tests/unit/HttpsCertificate.Tests.ps1)
    against Test-HttpsCertificateReady directly - no need to start a server
    just to prove a file-not-found check works.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $PSScriptRoot 'TestServer.ps1')
    $script:Server = Start-TestServer -RepoRoot $script:RepoRoot -Protocol Https
    $script:BaseUrl = $script:Server.BaseUrl
}

AfterAll {
    Stop-TestServer -Server $script:Server
    Clear-TestServerEnv
}

Describe 'HTTPS endpoint' {
    BeforeAll {
        $script:Resp = Invoke-WebRequest -Uri "$script:BaseUrl/health/live" -SkipCertificateCheck -UseBasicParsing
    }

    It 'serves the API over TLS with a self-signed certificate' {
        $script:BaseUrl | Should -Match '^https://'
        $script:Resp.StatusCode | Should -Be 200
    }

    It 'sets Strict-Transport-Security on an HTTPS response' {
        (Get-HeaderValue $script:Resp 'Strict-Transport-Security') | Should -Match 'max-age='
    }
}
