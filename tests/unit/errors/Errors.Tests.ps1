<#
.SYNOPSIS
    Unit tests for New-ApiErrorBody (src/errors/Errors.ps1) - the pure
    error-shaping function behind Send-ApiError. Send-ApiError itself calls
    Pode response cmdlets and is exercised end-to-end by
    tests/integration/Api.Tests.ps1 (404) and tests/integration/v1/Windows.Tests.ps1
    (422/503).
#>

BeforeAll {
    . "$PSScriptRoot/../../../src/errors/Errors.ps1"
}

Describe 'New-ApiErrorBody' {
    It 'produces the minimal { error: { code, message } } shape with no correlation id or details' {
        $body = New-ApiErrorBody -Code 'NOT_FOUND' -Message 'Resource not found.'
        $body.error.code | Should -Be 'NOT_FOUND'
        $body.error.message | Should -Be 'Resource not found.'
        $body.error.Contains('correlationId') | Should -BeFalse
        $body.error.Contains('details') | Should -BeFalse
    }

    It 'includes correlationId when one is supplied' {
        $body = New-ApiErrorBody -Code 'NOT_FOUND' -Message 'Resource not found.' -CorrelationId 'abc-123'
        $body.error.correlationId | Should -Be 'abc-123'
    }

    It 'omits correlationId when it is null or empty, rather than emitting a blank field' {
        $body = New-ApiErrorBody -Code 'NOT_FOUND' -Message 'Resource not found.' -CorrelationId $null
        $body.error.Contains('correlationId') | Should -BeFalse
    }

    It 'includes details for a validation error' {
        $details = @(@{ field = 'name'; code = 'REQUIRED' })
        $body = New-ApiErrorBody -Code 'VALIDATION_ERROR' -Message 'The request contains invalid parameters.' -Details $details
        $body.error.details.Count | Should -Be 1
        $body.error.details[0].field | Should -Be 'name'
        $body.error.details[0].code | Should -Be 'REQUIRED'
    }

    It 'omits details when an empty array is supplied' {
        $body = New-ApiErrorBody -Code 'NOT_FOUND' -Message 'Resource not found.' -Details @()
        $body.error.Contains('details') | Should -BeFalse
    }

    It 'never includes exception-shaped internal fields (stack trace, file path)' {
        $body = New-ApiErrorBody -Code 'INTERNAL_ERROR' -Message 'An unexpected error occurred.'
        ($body.error.Keys) | Should -Not -Contain 'stackTrace'
        ($body.error.Keys) | Should -Not -Contain 'exception'
        $body.error.message | Should -Not -Match '\.ps1'
    }
}
