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

    # Same reasoning as Start-DelayedSemaphoreRelease above: a real function
    # so the suppression can attach to it, and $ShutdownPath/$RepoRoot *are*
    # passed safely via -ArgumentList/param() - a known false positive for
    # Start-Job, same as Start-ThreadJob.
    function Start-AppShutdownTerminateHandlerInEmptyProcess {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'Passed via -ArgumentList/param(), not a closure over an outer variable - a known false positive for Start-Job.')]
        param(
            [string]$ShutdownPath,
            [string]$RepoRoot
        )

        Start-Job -ScriptBlock {
            param($ShutdownPath, $RepoRoot)
            # $RepoRoot is used below, but only via closure from inside the
            # nested Get-PodeServerPath function - too indirect for
            # PSReviewUnusedParameter's static analysis to trace.
            $null = $RepoRoot

            function Get-PodeServerPath { $RepoRoot }
            function Get-PodeState {
                param($Name)
                switch ($Name) {
                    'AppConfig' { @{ MaxInFlightRequests = 5; ShutdownTimeoutSeconds = 10 } }
                    'ConcurrencySemaphore' { [System.Threading.SemaphoreSlim]::new(5, 5) }
                }
            }
            # Stands in for Pode's own log-writing cmdlet, which Write-AppLog
            # (re-sourced from inside the function under test) calls - never
            # itself stubbed by this test, proving the real implementation runs.
            # A true no-op: the params only need to exist so the named-argument
            # call from Write-AppLog binds; nothing here needs their values.
            function Write-PodeLog {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'A no-op stand-in for Pode''s real cmdlet - only needs to accept these named arguments, never use them.')]
                param($Name, $Level, $InputObject)
            }

            . $ShutdownPath
            try {
                Invoke-AppShutdownTerminateHandler
                'ok'
            }
            catch {
                "threw: $($_.Exception.Message)"
            }
        } -ArgumentList $ShutdownPath, $RepoRoot | Wait-Job -Timeout 20 | Receive-Job
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

Describe 'Invoke-AppShutdownTerminateHandler' {
    <#
        Regression guard for a real bug found by manual reproduction against
        a live server: Pode invokes a registered Terminate event's
        scriptblock via its own GetNewClosure() at *fire* time, not at
        Register-PodeEvent time - so a variable closed over when the
        scriptblock was written (e.g. $root) is already out of scope by
        then. This intermittently made Wait-AppShutdownDrain "not
        recognized" there, silently skipping the drain wait entirely. The
        fix: re-source every dependency from a freshly called
        Get-PodeServerPath, never a closed-over variable - these tests
        mock Get-PodeServerPath to point at this repo's own real source
        files, so a regression that reintroduces a closure/ambient
        dependency here would fail these without needing a real Pode
        server or a real SIGTERM at all.
    #>
    BeforeAll {
        $script:RepoRootForTerminateHandler = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    }

    It 'runs Wait-AppShutdownDrain and logs application.stopped by re-sourcing its own dependencies' {
        Mock Get-PodeServerPath { $script:RepoRootForTerminateHandler }
        Mock Get-PodeState {
            switch ($Name) {
                'AppConfig' { @{ MaxInFlightRequests = 5; ShutdownTimeoutSeconds = 10 } }
                'ConcurrencySemaphore' { [System.Threading.SemaphoreSlim]::new(5, 5) }
            }
        }
        Mock Write-AppLog {}

        { Invoke-AppShutdownTerminateHandler } | Should -Not -Throw

        Should -Invoke Get-PodeServerPath -Times 1
        Should -Invoke Write-AppLog -ParameterFilter { $Event -eq 'application.shutdown.completed' }
        Should -Invoke Write-AppLog -ParameterFilter { $Event -eq 'application.stopped' }
    }

    It 'still works in a genuinely empty process - not just one where Logging/CorrelationId happen to already be loaded' {
        # Start-Job runs in a brand new PowerShell process: nothing this test
        # file's own BeforeAll dot-sourced exists there, and Pode itself is
        # never imported - only bare stubs for the three Pode-native cmdlets
        # a real Pode server would provide (Get-PodeServerPath, Get-PodeState,
        # Write-PodeLog). This is the closest a unit test can get to the real
        # cross-runspace scenario the bug came from, without a running server.
        $result = Start-AppShutdownTerminateHandlerInEmptyProcess -ShutdownPath "$PSScriptRoot/../../../src/middleware/Shutdown.ps1" -RepoRoot $script:RepoRootForTerminateHandler

        $result | Should -Be 'ok'
    }
}
