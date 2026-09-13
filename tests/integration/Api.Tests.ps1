<#
.SYNOPSIS
    Integration tests for health endpoints, correlation id and the JSON error
    contract. Starts a real OpsBridge server process on a free port and talks
    to it over HTTP - this verifies the actual contract, not an isolated
    function call.
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

Describe 'GET /health/live' {
    It 'returns 200 JSON { status: healthy, checks.application: healthy }' {
        $r = Invoke-WebRequest -Uri "$script:BaseUrl/health/live" -UseBasicParsing
        $r.StatusCode | Should -Be 200
        (Get-HeaderValue $r 'Content-Type') | Should -Match 'application/json'
        $body = $r.Content | ConvertFrom-Json
        $body.status | Should -Be 'healthy'
        $body.checks.application | Should -Be 'healthy'
    }

    It 'answers a HEAD probe with 200 (not the catch-all 404)' {
        $r = Invoke-WebRequest -Uri "$script:BaseUrl/health/live" -Method Head -UseBasicParsing
        $r.StatusCode | Should -Be 200
    }
}

Describe 'GET /health/ready' {
    It 'returns 200 JSON { status: healthy, checks.application: healthy } once the app is up' {
        $r = Invoke-WebRequest -Uri "$script:BaseUrl/health/ready" -UseBasicParsing
        $r.StatusCode | Should -Be 200
        $body = $r.Content | ConvertFrom-Json
        $body.status | Should -Be 'healthy'
        $body.checks.application | Should -Be 'healthy'
    }

    It 'answers HEAD /health/ready with 200' {
        (Invoke-WebRequest -Uri "$script:BaseUrl/health/ready" -Method Head -UseBasicParsing).StatusCode | Should -Be 200
    }
}

Describe 'Unknown routes' {
    It 'returns a coherent JSON 404 with code + correlationId' {
        try {
            Invoke-WebRequest -Uri "$script:BaseUrl/does-not-exist" -UseBasicParsing
            throw 'Expected the request to fail with 404'
        }
        catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $_.Exception.Response.StatusCode.value__ | Should -Be 404
            $body = $_.ErrorDetails.Message | ConvertFrom-Json
            $body.error.code | Should -Be 'NOT_FOUND'
            $body.error.correlationId | Should -Not -BeNullOrEmpty
        }
    }

    It 'runs the full pipeline for a 404 (correlation id header, Server value)' {
        try {
            Invoke-WebRequest -Uri "$script:BaseUrl/does-not-exist" -UseBasicParsing
            throw 'Expected the request to fail with 404'
        }
        catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $resp = $_.Exception.Response
            (Get-ErrorHeaderValue $resp 'X-Correlation-ID') | Should -Not -BeNullOrEmpty
            (Get-ErrorHeaderValue $resp 'Server') | Should -Be 'OpsBridge'
        }
    }

    It 'returns a coherent 404 for a non-GET method too' {
        try {
            Invoke-WebRequest -Uri "$script:BaseUrl/does-not-exist" -Method Post -UseBasicParsing
            throw 'Expected the request to fail with 404'
        }
        catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $_.Exception.Response.StatusCode.value__ | Should -Be 404
            ($_.ErrorDetails.Message | ConvertFrom-Json).error.code | Should -Be 'NOT_FOUND'
        }
    }

    It 'never leaks internal details (paths, stack traces, framework name) in the body' {
        try {
            Invoke-WebRequest -Uri "$script:BaseUrl/does-not-exist" -UseBasicParsing
            throw 'Expected the request to fail with 404'
        }
        catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $raw = $_.ErrorDetails.Message
            $raw | Should -Not -Match '[A-Za-z]:\\'
            $raw | Should -Not -Match 'Exception'
            $raw | Should -Not -Match 'at\s+\S+\.ps1'
            $raw | Should -Not -Match 'Pode|PowerShell 7'
        }
    }

    It 'serves the error body as application/json' {
        try {
            Invoke-WebRequest -Uri "$script:BaseUrl/does-not-exist" -UseBasicParsing
            throw 'Expected the request to fail with 404'
        }
        catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            (Get-ErrorHeaderValue $_.Exception.Response 'Content-Type') | Should -Match 'application/json'
        }
    }
}

Describe 'Wrong HTTP method on an existing route' {
    It 'falls through to the coherent 404 catch-all instead of a raw 405 (docs/architecture.md: routes are registered per-method, not with -Method *)' {
        # api/v1/windows/services is GET-only. Pode's own "Method Not Allowed"
        # behaviour (if it ever kicked in here instead of the catch-all) would
        # skip the correlation id / security header / JSON error middleware
        # this whole suite otherwise guarantees on every response - a route
        # registration regression this subtle would otherwise go unnoticed.
        try {
            Invoke-WebRequest -Uri "$script:BaseUrl/api/v1/windows/services" -Method Post -UseBasicParsing
            throw 'Expected the request to fail with 404'
        }
        catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $resp = $_.Exception.Response
            $resp.StatusCode.value__ | Should -Be 404
            $body = $_.ErrorDetails.Message | ConvertFrom-Json
            $body.error.code | Should -Be 'NOT_FOUND'
            $body.error.correlationId | Should -Not -BeNullOrEmpty
            (Get-ErrorHeaderValue $resp 'X-Correlation-ID') | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Correlation ID' {
    It 'echoes a valid client-supplied id' {
        $id = 'test-correlation-12345'
        $r = Invoke-WebRequest -Uri "$script:BaseUrl/health/live" -Headers @{ 'X-Correlation-ID' = $id } -UseBasicParsing
        (Get-HeaderValue $r 'X-Correlation-ID') | Should -Be $id
    }

    It 'generates an id when none is supplied' {
        $r = Invoke-WebRequest -Uri "$script:BaseUrl/health/live" -UseBasicParsing
        (Get-HeaderValue $r 'X-Correlation-ID') | Should -Not -BeNullOrEmpty
    }

    It 'generates a well-formed id that round-trips through the validator' {
        # The generated id must satisfy the same rule a client id must, otherwise
        # a caller that reads X-Correlation-ID and passes it back on the next
        # request would have it rejected and the chain would break.
        $generated = Get-HeaderValue (Invoke-WebRequest -Uri "$script:BaseUrl/health/live" -UseBasicParsing) 'X-Correlation-ID'
        $generated | Should -Match '^[A-Za-z0-9_-]{1,128}$'

        $echoed = Get-HeaderValue (Invoke-WebRequest -Uri "$script:BaseUrl/health/live" -Headers @{ 'X-Correlation-ID' = $generated } -UseBasicParsing) 'X-Correlation-ID'
        $echoed | Should -Be $generated
    }

    It 'ignores a malicious/malformed id instead of reflecting it' {
        $r = Invoke-WebRequest -Uri "$script:BaseUrl/health/live" -Headers @{ 'X-Correlation-ID' = '<script>alert(1)</script>' } -UseBasicParsing
        $returned = Get-HeaderValue $r 'X-Correlation-ID'
        $returned | Should -Not -Be '<script>alert(1)</script>'
        $returned | Should -Not -Match '[<>]'
    }

    It 'rejects an id longer than 128 characters' {
        $r = Invoke-WebRequest -Uri "$script:BaseUrl/health/live" -Headers @{ 'X-Correlation-ID' = ('a' * 200) } -UseBasicParsing
        (Get-HeaderValue $r 'X-Correlation-ID') | Should -Not -Be ('a' * 200)
    }

    It 'generates a different id for each of two separate requests (no accidental reuse across requests)' {
        # Guards the exact class of bug docs/architecture.md's "Gotcha" note
        # describes: state that looks per-request but is actually shared
        # across runspaces/requests. Get-CorrelationId is read from
        # $WebEvent.Data, which is request-scoped, but nothing before this
        # proved two consecutive requests actually get independent values.
        $first = Get-HeaderValue (Invoke-WebRequest -Uri "$script:BaseUrl/health/live" -UseBasicParsing) 'X-Correlation-ID'
        $second = Get-HeaderValue (Invoke-WebRequest -Uri "$script:BaseUrl/health/live" -UseBasicParsing) 'X-Correlation-ID'
        $first | Should -Not -Be $second
    }
}
