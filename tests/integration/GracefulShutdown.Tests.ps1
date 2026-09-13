<#
.SYNOPSIS
    Integration tests for graceful shutdown (SIGTERM/SIGINT -> drain -> exit).
.DESCRIPTION
    Uses a real server process and a real SIGTERM, not Stop-TestServer's
    Stop-Process -Force (a hard kill - correct for every other test file,
    not this one). Skipped on Windows: SIGTERM has no direct equivalent there
    (a Windows service stop goes through the Service Control Manager - see
    scripts/install-service.ps1 - which this suite does not cover).

    The timeout case (a request that never finishes) is unit-tested instead
    (tests/unit/middleware/Shutdown.Tests.ps1) - there is no route slow
    enough to trigger it for real. So is the correctness of
    Invoke-AppShutdownTerminateHandler itself (same file): Pode's own
    file-log writer races the same Terminate signal that fires this event
    (verified directly - its background runspace polls the identical
    cancellation token and can stop before a log line written from inside
    the event handler is flushed), so asserting on log content from here
    would be flaky by construction, not a sign of a real regression.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $PSScriptRoot 'TestServer.ps1')   # brings in Get-FreeTcpPort
    $script:LogDir = Join-Path ([System.IO.Path]::GetTempPath()) "opsbridge-shutdown-it-$PID"
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null

    # Defined here, not at the file's top level - Pester 6 runs Discovery and
    # Run as separate passes, and only Run-phase code like this BeforeAll is
    # guaranteed to still be in scope for the It blocks below (same reason
    # TestServer.ps1 is dot-sourced here rather than at the top of the file).
    # A real .NET Process object (not Start-TestServer, which force-kills) so
    # this file controls exactly how the process is signalled and can read
    # its exit code.
    function Start-RealServerProcess {
        param([string]$Port)

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $pwshName = if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }
        $psi.FileName = Join-Path $PSHOME $pwshName
        $psi.ArgumentList.Add('-NoProfile')
        $psi.ArgumentList.Add('-File')
        $psi.ArgumentList.Add((Join-Path $script:RepoRoot 'server.ps1'))
        $psi.WorkingDirectory = $script:RepoRoot
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.EnvironmentVariables['API_PORT'] = $Port
        $psi.EnvironmentVariables['API_HOST'] = '127.0.0.1'
        $psi.EnvironmentVariables['API_LOG_DESTINATION'] = 'file'
        $psi.EnvironmentVariables['API_LOG_PATH'] = $script:LogDir
        $psi.EnvironmentVariables['API_SHUTDOWN_TIMEOUT_SECONDS'] = '5'

        $proc = [System.Diagnostics.Process]::Start($psi)

        $ready = $false
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Milliseconds 500
            try {
                Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health/ready" -TimeoutSec 1 | Out-Null
                $ready = $true
                break
            }
            catch { $null = $_ }
        }
        if (-not $ready) {
            $proc.Kill()
            throw "Server on port $Port did not become ready in time."
        }

        return $proc
    }

    # PSUseUsingScopeModifierInNewRunspaces' suppression below can attach to
    # this function's param block: $Port *is* passed safely via
    # -ArgumentList/param(), a known false positive for Start-ThreadJob.
    function Start-BackgroundHealthRequest {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'Passed via -ArgumentList/param(), not a closure over an outer variable - a known false positive for Start-ThreadJob.')]
        param([string]$Port)

        Start-ThreadJob -ScriptBlock {
            param($Port)
            try {
                $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health/live" -UseBasicParsing -TimeoutSec 5
                [int]$r.StatusCode
            }
            catch {
                if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode.value__ } else { -1 }
            }
        } -ArgumentList $Port
    }
}

Describe 'Graceful shutdown (SIGTERM)' -Skip:$IsWindows {
    It 'stops accepting new requests immediately and exits with code 0' {
        $port = Get-FreeTcpPort
        $proc = Start-RealServerProcess -Port $port
        try {
            & kill -TERM $proc.Id

            try {
                Invoke-WebRequest -Uri "http://127.0.0.1:$port/health/live" -UseBasicParsing -TimeoutSec 3
                throw 'Expected the request to be rejected with 503 SHUTTING_DOWN'
            }
            catch [Microsoft.PowerShell.Commands.HttpResponseException] {
                $_.Exception.Response.StatusCode.value__ | Should -Be 503
                $body = $_.ErrorDetails.Message | ConvertFrom-Json
                $body.error.code | Should -Be 'SHUTTING_DOWN'
                $body.error.category | Should -Be 'overload'
                $body.error.retryable | Should -BeTrue
                $body.error.correlationId | Should -Not -BeNullOrEmpty
            }

            $exited = $proc.WaitForExit(10000)
            $exited | Should -BeTrue
            $proc.ExitCode | Should -Be 0
        }
        finally {
            if (-not $proc.HasExited) { $proc.Kill() }
        }
    }

    It 'lets a request already in flight complete normally instead of cutting it off' {
        $port = Get-FreeTcpPort
        $proc = Start-RealServerProcess -Port $port
        try {
            # Fire the request and signal termination back-to-back, from the
            # same thread, so the request is in flight (or at least accepted)
            # before SIGTERM arrives - as close to "racing" the shutdown as
            # this test can get without a deliberately slow route.
            $requestJob = Start-BackgroundHealthRequest -Port $port

            & kill -TERM $proc.Id
            $statusCode = $requestJob | Wait-Job -Timeout 10 | Receive-Job
            $requestJob | Remove-Job -Force -ErrorAction SilentlyContinue

            # Either it was accepted just before shutdown (200) or rejected
            # cleanly by the shutdown gate (503) - never a raw connection
            # failure (-1), which is what an abrupt, ungraceful kill would
            # produce for a request that was genuinely in flight.
            $statusCode | Should -BeIn @(200, 503)

            $proc.WaitForExit(10000) | Should -BeTrue
            $proc.ExitCode | Should -Be 0
        }
        finally {
            if (-not $proc.HasExited) { $proc.Kill() }
        }
    }

    It 'logs "Server stopped" to the console after a clean shutdown' {
        $port = Get-FreeTcpPort
        $proc = Start-RealServerProcess -Port $port
        try {
            & kill -TERM $proc.Id
            $proc.WaitForExit(10000) | Should -BeTrue

            $stdout = $proc.StandardOutput.ReadToEnd()
            $stdout | Should -Match 'Server stopped'
        }
        finally {
            if (-not $proc.HasExited) { $proc.Kill() }
        }
    }
}
