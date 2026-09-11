<#
.SYNOPSIS
    Unit tests for Test-CorrelationIdFormat (src/middleware/CorrelationId.ps1).
    Get-CorrelationId / Add-CorrelationIdMiddleware need a live $WebEvent and are
    exercised by tests/integration/Api.Tests.ps1 instead.
#>

BeforeAll {
    . "$PSScriptRoot/../../../src/middleware/CorrelationId.ps1"
}

Describe 'Test-CorrelationIdFormat' {
    It 'accepts a well-formed alphanumeric id' {
        Test-CorrelationIdFormat -Value 'abc123-XYZ_789' | Should -BeTrue
    }

    It 'accepts a single character' {
        Test-CorrelationIdFormat -Value 'a' | Should -BeTrue
    }

    It 'accepts exactly 128 characters' {
        Test-CorrelationIdFormat -Value ('a' * 128) | Should -BeTrue
    }

    It 'rejects more than 128 characters' {
        Test-CorrelationIdFormat -Value ('a' * 129) | Should -BeFalse
    }

    It 'rejects an empty string' {
        Test-CorrelationIdFormat -Value '' | Should -BeFalse
    }

    It 'rejects $null' {
        Test-CorrelationIdFormat -Value $null | Should -BeFalse
    }

    It 'rejects markup (closes off reflected-XSS via the echoed header)' {
        Test-CorrelationIdFormat -Value '<script>alert(1)</script>' | Should -BeFalse
    }

    It 'rejects a value with an embedded space' {
        Test-CorrelationIdFormat -Value 'has space' | Should -BeFalse
    }

    It 'rejects a value with a trailing newline (closes off header/log injection)' {
        Test-CorrelationIdFormat -Value "abc`n" | Should -BeFalse
    }

    It 'rejects a value with an embedded CR/LF' {
        Test-CorrelationIdFormat -Value "abc`r`ndef" | Should -BeFalse
    }
}
