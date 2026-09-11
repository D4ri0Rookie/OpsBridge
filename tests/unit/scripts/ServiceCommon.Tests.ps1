<#
.SYNOPSIS
    Unit tests for Get-PodeServiceDefinition (scripts/ServiceCommon.ps1) - pure
    given a -PwshPath, so it never depends on the actual service control
    manager or an installed pwsh. This script targets Windows services (NSSM)
    in production, but the function itself is just string-building and is
    tested here regardless of the OS running the suite - $script:RepoRoot is
    picked per-OS only because Join-Path rejects a 'C:\...' literal on
    non-Windows (no such PSDrive), not because the logic itself is
    platform-specific.
#>

BeforeAll {
    . "$PSScriptRoot/../../../scripts/ServiceCommon.ps1"
    $script:RepoRoot = if ($IsWindows) { 'C:\OpsBridge' } else { '/opt/opsbridge' }
    $script:PwshPath = if ($IsWindows) { 'C:\pwsh\pwsh.exe' } else { '/usr/bin/pwsh' }
}

Describe 'Get-PodeServiceDefinition' {
    It 'builds the expected NSSM parameter set' {
        $def = Get-PodeServiceDefinition -ServiceName 'OpsBridge' -RepoRoot $script:RepoRoot -PwshPath $script:PwshPath

        $def.ServiceName | Should -Be 'OpsBridge'
        $def.Application | Should -Be $script:PwshPath
        $def.AppParameters | Should -Match 'server\.ps1'
        $def.AppDirectory | Should -Be $script:RepoRoot
    }

    It 'always sets API_DAEMON=true by default' {
        $def = Get-PodeServiceDefinition -ServiceName 'OpsBridge' -RepoRoot $script:RepoRoot -PwshPath $script:PwshPath
        $def.AppEnvironmentExtra | Should -Contain 'API_DAEMON=true'
    }

    It 'lets an explicit API_DAEMON override win' {
        $def = Get-PodeServiceDefinition -ServiceName 'OpsBridge' -RepoRoot $script:RepoRoot -PwshPath $script:PwshPath -Environment @{ API_DAEMON = 'false' }
        $def.AppEnvironmentExtra | Should -Contain 'API_DAEMON=false'
        $def.AppEnvironmentExtra | Should -Not -Contain 'API_DAEMON=true'
    }

    It 'includes extra environment variables' {
        $def = Get-PodeServiceDefinition -ServiceName 'OpsBridge' -RepoRoot $script:RepoRoot -PwshPath $script:PwshPath -Environment @{ API_PORT = '9000' }
        $def.AppEnvironmentExtra | Should -Contain 'API_PORT=9000'
    }

    It 'throws when pwsh cannot be located and no -PwshPath is given' {
        Mock Get-Command { $null }
        { Get-PodeServiceDefinition -ServiceName 'OpsBridge' -RepoRoot $script:RepoRoot } | Should -Throw
    }
}
