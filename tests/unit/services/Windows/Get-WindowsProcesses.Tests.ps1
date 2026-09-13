<#
.SYNOPSIS
    Unit tests for Get-OpsBridgeWindowsProcesses (src/services/Windows/Get-WindowsProcesses.ps1).
    Invoke-OpsBridgeGetProcess is mocked - these tests never touch a real
    process list and are deterministic regardless of what is actually
    running on the host executing the suite.
#>

BeforeAll {
    . "$PSScriptRoot/../../../../src/services/Windows/Get-WindowsProcesses.ps1"
}

Describe 'Get-OpsBridgeWindowsProcesses' {
    Context 'no name filter' {
        It 'shapes every process into id/name/workingSetBytes' {
            Mock Invoke-OpsBridgeGetProcess {
                @(
                    [pscustomobject]@{ Id = 1; ProcessName = 'init'; WorkingSet64 = 1024 }
                    [pscustomobject]@{ Id = 2; ProcessName = 'sshd'; WorkingSet64 = 2048 }
                )
            }

            $result = Get-OpsBridgeWindowsProcesses

            $result.Processes.Count | Should -Be 2
            $result.Processes[0].id | Should -Be 1
            $result.Processes[0].name | Should -Be 'init'
            $result.Processes[0].workingSetBytes | Should -Be 1024
        }

        It 'shapes a single process without unwrapping the array to a scalar' {
            Mock Invoke-OpsBridgeGetProcess {
                @([pscustomobject]@{ Id = 42; ProcessName = 'pwsh'; WorkingSet64 = 4096 })
            }

            $result = Get-OpsBridgeWindowsProcesses

            $result.Processes.Count | Should -Be 1
            $result.Processes[0].id | Should -Be 42
        }

        It 'calls the process wrapper with no -Name' {
            Mock Invoke-OpsBridgeGetProcess { @() }

            Get-OpsBridgeWindowsProcesses | Out-Null

            Should -Invoke Invoke-OpsBridgeGetProcess -Times 1 -ParameterFilter {
                -not $PSBoundParameters.ContainsKey('Name') -or [string]::IsNullOrEmpty($Name)
            }
        }
    }

    Context 'with a name filter' {
        It 'forwards the name filter to the process wrapper' {
            Mock Invoke-OpsBridgeGetProcess { @() }

            Get-OpsBridgeWindowsProcesses -Name 'pwsh*' | Out-Null

            Should -Invoke Invoke-OpsBridgeGetProcess -Times 1 -ParameterFilter { $Name -eq 'pwsh*' }
        }

        It 'returns an empty (not null) Processes array when nothing matches' {
            Mock Invoke-OpsBridgeGetProcess { @() }

            $result = Get-OpsBridgeWindowsProcesses -Name 'does-not-exist'

            ($null -ne $result.Processes) | Should -BeTrue
            $result.Processes.Count | Should -Be 0
        }
    }

    Context 'dependency failure' {
        It 'lets an exception from the process wrapper propagate uncaught' {
            # Same division of responsibility as Get-OpsBridgeWindowsServices:
            # no try/catch here, a dependency failure is meant to reach the
            # route unhandled, where Add-AppRoute's wrapper turns it into the
            # standard 500 INTERNAL_ERROR.
            Mock Invoke-OpsBridgeGetProcess { throw [System.InvalidOperationException]::new('Access is denied') }

            { Get-OpsBridgeWindowsProcesses } | Should -Throw '*Access is denied*'
        }
    }
}

Describe 'Invoke-OpsBridgeGetProcess' {
    It 'lists at least one real process on the current host' {
        # Unlike Get-Service, Get-Process is cross-platform - this runs (and
        # must pass) on every OS the suite runs on, not just Windows.
        $result = Invoke-OpsBridgeGetProcess
        $result.Count | Should -BeGreaterThan 0
    }
}
