<#
.SYNOPSIS
    Unit tests for the pure helpers in src/logging/Logging.ps1.
    Initialize-AppLogging / Write-AppLog need a running Pode server
    (Add-PodeLogType, Write-PodeLog) and are only exercised indirectly, by
    every test under tests/integration/ hitting a real running server (which
    logs through this module on every request).
#>

BeforeAll {
    . "$PSScriptRoot/../../../src/logging/Logging.ps1"
}

Describe 'Get-AppTimestamp' {
    It 'formats a known instant as UTC ISO-8601 with millisecond precision' {
        $instant = [datetime]::new(2026, 1, 2, 3, 4, 5, 678, [System.DateTimeKind]::Utc)
        Get-AppTimestamp -Instant $instant | Should -Be '2026-01-02T03:04:05.678Z'
    }

    It 'converts a local/offset instant to UTC before formatting' {
        $instant = [datetimeoffset]::new(2026, 6, 1, 12, 0, 0, [timespan]::FromHours(2)).UtcDateTime
        Get-AppTimestamp -Instant $instant | Should -Be '2026-06-01T10:00:00.000Z'
    }

    It 'defaults to the current UTC instant when none is supplied' {
        $before = [datetime]::UtcNow
        $result = [datetime]::Parse((Get-AppTimestamp), $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $after = [datetime]::UtcNow
        $result | Should -BeGreaterOrEqual $before.AddSeconds(-1)
        $result | Should -BeLessOrEqual $after.AddSeconds(1)
    }
}

Describe 'Get-PodeLevelsAtOrAbove' {
    It 'includes every level from Emergency down to the requested one' {
        Get-PodeLevelsAtOrAbove -MinLevel 'Warning' | Should -Be @('Emergency', 'Alert', 'Critical', 'Error', 'Warning')
    }

    It 'returns just Emergency for the narrowest level' {
        Get-PodeLevelsAtOrAbove -MinLevel 'Emergency' | Should -Be @('Emergency')
    }

    It 'returns every level for the widest (Debug)' {
        (Get-PodeLevelsAtOrAbove -MinLevel 'Debug').Count | Should -Be 9
    }

    It 'throws on an unknown level instead of silently returning a wrong range' {
        { Get-PodeLevelsAtOrAbove -MinLevel 'Trace' } | Should -Throw
    }
}

Describe 'Protect-AppLogData' {
    It 'passes through a hashtable with no sensitive-looking keys unchanged' {
        $data = @{ service = 'Windows'; operation = 'GetServices'; durationMs = 12 }
        $result = Protect-AppLogData -Data $data
        $result.service | Should -Be 'Windows'
        $result.operation | Should -Be 'GetServices'
        $result.durationMs | Should -Be 12
    }

    It 'returns $null unchanged (Write-AppLog is called with no -Data on many events)' {
        Protect-AppLogData -Data $null | Should -BeNullOrEmpty
    }

    It 'redacts each of the documented sensitive key names (docs/logging.md)' -TestCases @(
        @{ Key = 'Authorization' }
        @{ Key = 'Password' }
        @{ Key = 'Token' }
        @{ Key = 'ApiKey' }
        @{ Key = 'Secret' }
        @{ Key = 'Credential' }
        @{ Key = 'Cookie' }
    ) {
        param($Key)
        $result = Protect-AppLogData -Data @{ $Key = 'super-secret-value' }
        $result[$Key] | Should -Be '***REDACTED***'
        $result[$Key] | Should -Not -Match 'super-secret-value'
    }

    It 'matches case-insensitively and as a substring (real header/field names)' -TestCases @(
        @{ Key = 'authorization' }
        @{ Key = 'AUTHORIZATION' }
        @{ Key = 'X-Api-Key' }
        @{ Key = 'apiKey' }
        @{ Key = 'authToken' }
        @{ Key = 'sessionCookie' }
        @{ Key = 'dbPassword' }
        @{ Key = 'clientSecret' }
    ) {
        param($Key)
        (Protect-AppLogData -Data @{ $Key = 'super-secret-value' })[$Key] | Should -Be '***REDACTED***'
    }

    It 'redacts recursively inside a nested hashtable' {
        $data = @{
            request = @{
                headers = @{ Authorization = 'Bearer abc123'; Accept = 'application/json' }
            }
        }
        $result = Protect-AppLogData -Data $data
        $result.request.headers.Authorization | Should -Be '***REDACTED***'
        $result.request.headers.Accept | Should -Be 'application/json'
    }

    It 'never mutates the caller''s original hashtable' {
        $data = @{ Password = 'hunter2' }
        Protect-AppLogData -Data $data | Out-Null
        $data.Password | Should -Be 'hunter2'
    }

    It 'does not redact a key that merely contains an unrelated substring' {
        # Guards against an overly broad pattern - "count" should never match
        # "credential"-adjacent redaction just because both contain "c".
        $result = Protect-AppLogData -Data @{ count = 5; statusCode = 200 }
        $result.count | Should -Be 5
        $result.statusCode | Should -Be 200
    }
}
