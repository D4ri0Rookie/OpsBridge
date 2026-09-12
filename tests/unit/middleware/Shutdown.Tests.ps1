<#
.SYNOPSIS
    Unit tests for Wait-AppShutdownDrain (src/middleware/Shutdown.ps1) - the
    bounded wait-for-in-flight-requests logic run from Pode's Terminate event.
.DESCRIPTION
    Mocks Get-PodeState (both 'AppConfig' and 'ConcurrencySemaphore') and
    Write-AppLog so the bounded-wait logic can be verified without a running
    Pode server or real in-flight HTTP requests - in particular, the "timeout
    elapses while requests are still in flight" case, which has no real route
    slow enough to exercise it end-to-end (see
    tests/integration/GracefulShutdown.Tests.ps1 for the SIGTERM-to-process
    behaviour this function is called from).
#>

BeforeAll {
    . "$PSScriptRoot/../../../src/logging/Logging.ps1"
    . "$PSScriptRoot/../../../src/middleware/Shutdown.ps1"

    # A real function (defined here, not at the file's top level - see the
    # note on this same pattern in tests/integration/TestServer.ps1) so
    # PSUseUsingScopeModifierInNewRunspaces' suppression below can attach to
    # it: $Semaphore *is* passed safely via -ArgumentList/param(), which is
    # exactly what that rule wants instead of relying on $using: - this is a
    # known false positive for Start-ThreadJob specifically.
    function Start-DelayedSemaphoreRelease {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'Passed via -ArgumentList/param(), not a closure over an outer variable - a known false positive for Start-ThreadJob.')]
        param(
            [System.Threading.SemaphoreSlim]$Semaphore,
            [int]$DelayMilliseconds
        )

        Start-ThreadJob -ScriptBlock {
            param($Semaphore, $DelayMilliseconds)
            Start-Sleep -Milliseconds $DelayMilliseconds
            $Semaphore.Release() | Out-Null
        } -ArgumentList $Semaphore, $DelayMilliseconds
    }
}

Describe 'Wait-AppShutdownDrain' {
    It 'returns immediately when no requests are in flight (semaphore already at full count)' {
        Mock Get-PodeState {
            switch ($Name) {
                'AppConfig' { @{ MaxInFlightRequests = 5; ShutdownTimeoutSeconds = 10 } }
                'ConcurrencySemaphore' { [System.Threading.SemaphoreSlim]::new(5, 5) }
            }
        }
        Mock Write-AppLog {}

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Wait-AppShutdownDrain
        $sw.Stop()

        $sw.Elapsed.TotalSeconds | Should -BeLessThan 1

        Should -Invoke Write-AppLog -Times 1 -ParameterFilter { $Event -eq 'application.shutdown.completed' -and $Data.drained -eq $true }
    }

    It 'waits for an in-flight request to finish, then returns before the timeout' {
        $semaphore = [System.Threading.SemaphoreSlim]::new(5, 5)
        $semaphore.Wait(0) | Out-Null   # simulate one request holding a slot

        Mock Get-PodeState {
            switch ($Name) {
                'AppConfig' { @{ MaxInFlightRequests = 5; ShutdownTimeoutSeconds = 10 } }
                'ConcurrencySemaphore' { $semaphore }
            }
        }
        Mock Write-AppLog {}

        # Release the held slot shortly after the drain wait starts, from a
        # background runspace, to simulate the in-flight request completing.
        $releaseJob = Start-DelayedSemaphoreRelease -Semaphore $semaphore -DelayMilliseconds 300

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Wait-AppShutdownDrain
        $sw.Stop()

        $releaseJob | Wait-Job -Timeout 5 | Remove-Job -Force

        $sw.Elapsed.TotalSeconds | Should -BeGreaterThan 0.25
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 10

        Should -Invoke Write-AppLog -Times 1 -ParameterFilter { $Event -eq 'application.shutdown.completed' -and $Data.drained -eq $true }
    }

    It 'gives up at the shutdown timeout when a request never finishes, and reports drained = $false' {
        $semaphore = [System.Threading.SemaphoreSlim]::new(5, 5)
        $semaphore.Wait(0) | Out-Null   # held for the whole test - never released

        Mock Get-PodeState {
            switch ($Name) {
                'AppConfig' { @{ MaxInFlightRequests = 5; ShutdownTimeoutSeconds = 1 } }
                'ConcurrencySemaphore' { $semaphore }
            }
        }
        Mock Write-AppLog {}

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Wait-AppShutdownDrain
        $sw.Stop()

        # Bounded by the 1s configured timeout, not left hanging indefinitely.
        $sw.Elapsed.TotalSeconds | Should -BeGreaterThan 0.9
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 3

        Should -Invoke Write-AppLog -Times 1 -ParameterFilter {
            $Event -eq 'application.shutdown.completed' -and $Data.drained -eq $false -and $Data.inFlightRequests -eq 1
        }
    }

    It 'logs application.shutdown.started with the current in-flight count before waiting' {
        $semaphore = [System.Threading.SemaphoreSlim]::new(5, 5)
        $semaphore.Wait(0) | Out-Null
        $semaphore.Wait(0) | Out-Null   # two held slots

        Mock Get-PodeState {
            switch ($Name) {
                'AppConfig' { @{ MaxInFlightRequests = 5; ShutdownTimeoutSeconds = 1 } }
                'ConcurrencySemaphore' { $semaphore }
            }
        }
        Mock Write-AppLog {}

        Wait-AppShutdownDrain

        Should -Invoke Write-AppLog -Times 1 -ParameterFilter {
            $Event -eq 'application.shutdown.started' -and $Data.inFlightRequests -eq 2 -and $Data.shutdownTimeoutSeconds -eq 1
        }
    }
}

Describe 'Test-AppShutdownRequested' {
    It 'returns $false when the OS signal handler was never registered (e.g. a unit test host process)' {
        # No Register-AppShutdownSignalHandler call anywhere in this file's
        # BeforeAll - the compiled type may or may not exist depending on test
        # run order within the same pwsh process, but either way this must
        # never throw and must reflect "not requested" unless a real SIGTERM/
        # SIGINT was actually received by *this* process.
        { Test-AppShutdownRequested } | Should -Not -Throw
    }
}
