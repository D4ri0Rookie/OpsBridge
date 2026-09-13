<#
.SYNOPSIS
    Unit tests for Test-ApiKeyValid (src/middleware/Authentication.ps1).
    Add-AuthenticationMiddleware needs a live $WebEvent/Pode server and is
    exercised by tests/integration/Authentication.Tests.ps1 instead.
#>

BeforeAll {
    . "$PSScriptRoot/../../../src/middleware/Authentication.ps1"
}

Describe 'Test-ApiKeyValid' {
    It 'accepts a key that matches the only configured key' {
        Test-ApiKeyValid -PresentedKey 'secret-123' -ValidKeys @('secret-123') | Should -BeTrue
    }

    It 'accepts a key that matches one of several configured keys' {
        Test-ApiKeyValid -PresentedKey 'key-b' -ValidKeys @('key-a', 'key-b', 'key-c') | Should -BeTrue
    }

    It 'rejects a key that matches none of the configured keys' {
        Test-ApiKeyValid -PresentedKey 'wrong-key' -ValidKeys @('key-a', 'key-b') | Should -BeFalse
    }

    It 'rejects a $null presented key' {
        Test-ApiKeyValid -PresentedKey $null -ValidKeys @('key-a') | Should -BeFalse
    }

    It 'rejects an empty presented key, even if an empty string were somehow a configured key' {
        Test-ApiKeyValid -PresentedKey '' -ValidKeys @('key-a') | Should -BeFalse
    }

    It 'rejects any key when no valid keys are configured' {
        Test-ApiKeyValid -PresentedKey 'anything' -ValidKeys @() | Should -BeFalse
    }

    It 'rejects any key when the valid keys list is $null' {
        Test-ApiKeyValid -PresentedKey 'anything' -ValidKeys $null | Should -BeFalse
    }

    It 'is case-sensitive (a secret token, not a human-facing identifier)' {
        Test-ApiKeyValid -PresentedKey 'Secret-123' -ValidKeys @('secret-123') | Should -BeFalse
    }

    It 'rejects a key that is a prefix or superstring of a valid key (no partial match)' {
        Test-ApiKeyValid -PresentedKey 'secret-12' -ValidKeys @('secret-123') | Should -BeFalse
        Test-ApiKeyValid -PresentedKey 'secret-1234' -ValidKeys @('secret-123') | Should -BeFalse
    }
}

Describe 'Get-ApiAuthKeys' {
    AfterEach {
        Remove-Item Env:\API_AUTH_KEYS -ErrorAction SilentlyContinue
    }

    It 'returns an empty array when API_AUTH_KEYS is not set' {
        Remove-Item Env:\API_AUTH_KEYS -ErrorAction SilentlyContinue
        ,(Get-ApiAuthKeys) | Should -BeNullOrEmpty
    }

    It 'splits a comma-separated list and trims whitespace' {
        $env:API_AUTH_KEYS = ' key-a ,key-b, key-c'
        Get-ApiAuthKeys | Should -Be @('key-a', 'key-b', 'key-c')
    }

    It 'ignores empty entries from a trailing/leading/double comma' {
        $env:API_AUTH_KEYS = 'key-a,,key-b,'
        Get-ApiAuthKeys | Should -Be @('key-a', 'key-b')
    }

    It 'returns a single-element array for one key with no comma' {
        $env:API_AUTH_KEYS = 'only-key'
        Get-ApiAuthKeys | Should -Be @('only-key')
    }
}
