<#
.SYNOPSIS
    Integration tests for GET /api/v1/windows/processes.
.DESCRIPTION
    Unlike windows/services, Get-Process is cross-platform - the success
    (200) path is asserted for real on every host running this suite, not
    skipped outside Windows.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'TestServer.ps1')
    $script:Server = Start-TestServer -RepoRoot $script:RepoRoot
    $script:BaseUrl = $script:Server.BaseUrl
}

AfterAll {
    Stop-TestServer -Server $script:Server
    Clear-TestServerEnv
}

Describe 'GET /api/v1/windows/processes - validation' {
    It 'returns 422 VALIDATION_ERROR with details when name is blank' {
        try {
            Invoke-WebRequest -Uri "$script:BaseUrl/api/v1/windows/processes?name=" -UseBasicParsing
            throw 'Expected the request to fail with 422'
        }
        catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $_.Exception.Response.StatusCode.value__ | Should -Be 422
            $body = $_.ErrorDetails.Message | ConvertFrom-Json
            $body.error.code | Should -Be 'VALIDATION_ERROR'
            $body.error.details[0].field | Should -Be 'name'
            $body.error.details[0].code | Should -Be 'EMPTY'
            $body.error.category | Should -Be 'validation'
            $body.error.retryable | Should -BeFalse
            $body.error.correlationId | Should -Not -BeNullOrEmpty
        }
    }

    It 'returns 422 VALIDATION_ERROR with details when name is longer than 256 characters' {
        $longName = 'a' * 257
        try {
            Invoke-WebRequest -Uri "$script:BaseUrl/api/v1/windows/processes?name=$longName" -UseBasicParsing
            throw 'Expected the request to fail with 422'
        }
        catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $_.Exception.Response.StatusCode.value__ | Should -Be 422
            $body = $_.ErrorDetails.Message | ConvertFrom-Json
            $body.error.code | Should -Be 'VALIDATION_ERROR'
            $body.error.details[0].field | Should -Be 'name'
            $body.error.details[0].code | Should -Be 'TOO_LONG'
        }
    }

    It 'returns 404 PROCESS_NOT_FOUND for a specific name that matches nothing' {
        try {
            Invoke-WebRequest -Uri "$script:BaseUrl/api/v1/windows/processes?name=definitely-not-a-real-process-xyz" -UseBasicParsing
            throw 'Expected the request to fail with 404'
        }
        catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $_.Exception.Response.StatusCode.value__ | Should -Be 404
            $body = $_.ErrorDetails.Message | ConvertFrom-Json
            $body.error.code | Should -Be 'PROCESS_NOT_FOUND'
            $body.error.correlationId | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'GET /api/v1/windows/processes - success' {
    It 'lists processes with the documented shape' {
        $r = Invoke-WebRequest -Uri "$script:BaseUrl/api/v1/windows/processes" -UseBasicParsing
        $r.StatusCode | Should -Be 200
        (Get-HeaderValue $r 'Content-Type') | Should -Match 'application/json'

        $body = $r.Content | ConvertFrom-Json
        $body.data | Should -Not -BeNullOrEmpty
        $body.data[0].id | Should -BeGreaterThan 0
        $body.data[0].name | Should -Not -BeNullOrEmpty
        # workingSetBytes is a number for every process on every platform
        # this suite runs on - not asserting an exact value, just presence
        # and type, since actual memory use is inherently non-deterministic.
        $body.data[0].workingSetBytes | Should -Not -BeNullOrEmpty
    }

    It 'echoes the client-supplied correlation id' {
        $id = 'processes-contract-test-id'
        $r = Invoke-WebRequest -Uri "$script:BaseUrl/api/v1/windows/processes" -Headers @{ 'X-Correlation-ID' = $id } -UseBasicParsing
        (Get-HeaderValue $r 'X-Correlation-ID') | Should -Be $id
    }
}
