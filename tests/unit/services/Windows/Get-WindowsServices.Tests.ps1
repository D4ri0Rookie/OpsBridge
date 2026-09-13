<#
.SYNOPSIS
    Unit tests for Get-OpsBridgeWindowsServices (src/services/Windows/Get-WindowsServices.ps1).
    Invoke-OpsBridgeGetService (the internal Get-Service wrapper) is mocked -
    these tests never touch a real Service Control Manager and are
    deterministic on any OS running the test suite, including one where
    Get-Service does not exist at all (e.g. Linux/macOS).
#>

BeforeAll {
    . "$PSScriptRoot/../../../../src/services/Windows/Get-WindowsServices.ps1"
}

Describe 'Get-OpsBridgeWindowsServices' {
    Context 'unsupported platform' {
        It 'returns Supported = $false and an empty list, without calling the service wrapper' {
            Mock Invoke-OpsBridgeGetService { throw 'Invoke-OpsBridgeGetService should not be called on an unsupported platform' }

            $result = Get-OpsBridgeWindowsServices -IsSupportedPlatform $false

            $result.Supported | Should -BeFalse
            $result.Services | Should -BeNullOrEmpty
            Should -Invoke Invoke-OpsBridgeGetService -Times 0
        }
    }

    Context 'supported platform, no name filter' {
        It 'shapes every service into name/displayName/status/startType' {
            Mock Invoke-OpsBridgeGetService {
                @(
                    [pscustomobject]@{ Name = 'wuauserv'; DisplayName = 'Windows Update'; Status = 'Running'; StartType = 'Automatic' }
                    [pscustomobject]@{ Name = 'spooler'; DisplayName = 'Print Spooler'; Status = 'Stopped'; StartType = 'Manual' }
                )
            }

            $result = Get-OpsBridgeWindowsServices -IsSupportedPlatform $true

            $result.Supported | Should -BeTrue
            $result.Services.Count | Should -Be 2
            $result.Services[0].name | Should -Be 'wuauserv'
            $result.Services[0].displayName | Should -Be 'Windows Update'
            $result.Services[0].status | Should -Be 'Running'
            $result.Services[0].startType | Should -Be 'Automatic'
        }

        It 'shapes a single service without unwrapping the Services array to a scalar' {
            # PowerShell's pipeline silently unwraps a one-element array in some
            # contexts - shapeing must go through @() explicitly so .Services
            # stays indexable/Count-able even with exactly one result.
            Mock Invoke-OpsBridgeGetService {
                @([pscustomobject]@{ Name = 'spooler'; DisplayName = 'Print Spooler'; Status = 'Running'; StartType = 'Automatic' })
            }

            $result = Get-OpsBridgeWindowsServices -IsSupportedPlatform $true

            $result.Services.Count | Should -Be 1
            $result.Services[0].name | Should -Be 'spooler'
        }

        It 'calls the service wrapper with no -Name' {
            Mock Invoke-OpsBridgeGetService { @() }

            Get-OpsBridgeWindowsServices -IsSupportedPlatform $true | Out-Null

            Should -Invoke Invoke-OpsBridgeGetService -Times 1 -ParameterFilter {
                -not $PSBoundParameters.ContainsKey('Name') -or [string]::IsNullOrEmpty($Name)
            }
        }
    }

    Context 'supported platform, with a name filter' {
        It 'forwards the name filter to the service wrapper' {
            Mock Invoke-OpsBridgeGetService { @() }

            Get-OpsBridgeWindowsServices -Name 'wuau*' -IsSupportedPlatform $true | Out-Null

            Should -Invoke Invoke-OpsBridgeGetService -Times 1 -ParameterFilter { $Name -eq 'wuau*' }
        }

        It 'returns an empty (not null) Services array when nothing matches, so the route can tell "no match" from "call failed"' {
            Mock Invoke-OpsBridgeGetService { @() }

            $result = Get-OpsBridgeWindowsServices -Name 'does-not-exist' -IsSupportedPlatform $true

            $result.Supported | Should -BeTrue
            # Piping an empty array into Should would invoke it zero times
            # (nothing to unwrap), which looks like $null - assert directly
            # instead of through the pipeline.
            ($null -ne $result.Services) | Should -BeTrue
            $result.Services.Count | Should -Be 0
        }
    }

    Context 'dependency failure' {
        It 'lets an exception from the service wrapper propagate uncaught' {
            # Get-OpsBridgeWindowsServices has no try/catch of its own - a
            # dependency failure (e.g. Get-Service denied) is meant to reach
            # the route unhandled, where Add-AppRoute's wrapper
            # (src/App.ps1, tests/unit/AppRoute.Tests.ps1) turns it into the
            # standard 500 INTERNAL_ERROR. This locks in that division of
            # responsibility: the service does not swallow or reshape it.
            Mock Invoke-OpsBridgeGetService { throw [System.InvalidOperationException]::new('Access is denied') }

            { Get-OpsBridgeWindowsServices -IsSupportedPlatform $true } | Should -Throw '*Access is denied*'
        }
    }
}

Describe 'Invoke-OpsBridgeGetService' {
    It 'lists at least one real service on Windows' -Skip:(-not $IsWindows) {
        $result = Invoke-OpsBridgeGetService
        $result.Count | Should -BeGreaterThan 0
    }
}
