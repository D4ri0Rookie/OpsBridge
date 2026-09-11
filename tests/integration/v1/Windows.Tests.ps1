<#
.SYNOPSIS
    Integration tests for GET /api/v1/windows/services - the reference
    Pode -> middleware -> route -> service implementation.
.DESCRIPTION
    The 200/service-listing behaviour only applies on a real Windows host (it
    calls the actual Service Control Manager); everywhere else the endpoint is
    expected to answer 503, and that is asserted instead. Validation (422) is
    platform-independent and always asserted.
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

Describe 'GET /api/v1/windows/services - validation' {
    It 'returns 422 VALIDATION_ERROR with details when name is blank' {
        try {
            Invoke-WebRequest -Uri "$script:BaseUrl/api/v1/windows/services?name=" -UseBasicParsing
            throw 'Expected the request to fail with 422'
        }
        catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $_.Exception.Response.StatusCode.value__ | Should -Be 422
            $body = $_.ErrorDetails.Message | ConvertFrom-Json
            $body.error.code | Should -Be 'VALIDATION_ERROR'
            $body.error.details[0].field | Should -Be 'name'
            $body.error.details[0].code | Should -Be 'EMPTY'
            $body.error.correlationId | Should -Not -BeNullOrEmpty
        }
    }

    It 'returns 422 VALIDATION_ERROR with details when name is longer than 256 characters' {
        $longName = 'a' * 257
        try {
            Invoke-WebRequest -Uri "$script:BaseUrl/api/v1/windows/services?name=$longName" -UseBasicParsing
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

    It 'accepts a name at exactly the 256-character limit (rejects 257, not 256)' -Skip:(-not $IsWindows) {
        # Off-by-one guard: on a non-Windows host this would 503 before the
        # length check even matters for the *outcome*, but the check itself
        # (Length -gt 256) must not reject the boundary value. Only
        # meaningful to assert end-to-end on Windows, where it reaches
        # Get-Service and gets a normal 200/404 instead of a 422.
        $boundaryName = 'a' * 256
        $r = $null
        try {
            $r = Invoke-WebRequest -Uri "$script:BaseUrl/api/v1/windows/services?name=$boundaryName" -UseBasicParsing
        }
        catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $_.Exception.Response.StatusCode.value__ | Should -Be 404
        }
        if ($r) { $r.StatusCode | Should -Be 200 }
    }
}

Describe 'GET /api/v1/windows/services - platform behaviour' {
    It 'lists services with the documented shape on Windows' -Skip:(-not $IsWindows) {
        $r = Invoke-WebRequest -Uri "$script:BaseUrl/api/v1/windows/services" -UseBasicParsing
        $r.StatusCode | Should -Be 200
        $body = $r.Content | ConvertFrom-Json
        $body.data | Should -Not -BeNullOrEmpty
        $body.data[0].name | Should -Not -BeNullOrEmpty
        $body.data[0].status | Should -Not -BeNullOrEmpty
    }

    It 'returns 503 WINDOWS_SERVICE_MANAGER_UNAVAILABLE on a non-Windows host' -Skip:($IsWindows) {
        try {
            Invoke-WebRequest -Uri "$script:BaseUrl/api/v1/windows/services" -UseBasicParsing
            throw 'Expected the request to fail with 503'
        }
        catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $_.Exception.Response.StatusCode.value__ | Should -Be 503
            $body = $_.ErrorDetails.Message | ConvertFrom-Json
            $body.error.code | Should -Be 'WINDOWS_SERVICE_MANAGER_UNAVAILABLE'
            $body.error.correlationId | Should -Not -BeNullOrEmpty
        }
    }
}
