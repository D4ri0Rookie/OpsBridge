<#
.SYNOPSIS
    Graceful shutdown (API_SHUTDOWN_TIMEOUT_SECONDS, docs/configuration.md).
.DESCRIPTION
    Turns SIGTERM/SIGINT (docker stop, Ctrl+C) into a clean shutdown instead
    of an instant kill. Verified before this file existed: SIGTERM killed the
    process in under a second, with nothing flushed to the logs.

    Flow: signal received -> new requests get 503 immediately -> a timer
    notices within ~1s and calls Close-PodeServer -> Pode's Terminate event
    waits for in-flight requests to drain (up to API_SHUTDOWN_TIMEOUT_SECONDS)
    -> Pode closes its listeners and the process exits.

    The signal callback only sets a compiled static field - it never runs
    PowerShell script code. .NET calls it on a thread with no Runspace
    attached, and any script code there throws "no Runspace available to run
    scripts in this thread". The Pode timer below (which does run inside a
    Runspace) is what actually calls Close-PodeServer.
#>

function Register-AppShutdownSignalHandler {
    <#
        Called once, from Start-ApplicationServer, before Start-PodeServer.
        Unit tests only dot-source this file - they never call
        Start-ApplicationServer, so no test process registers a real signal
        handler. The type check below also guards against double
        registration.
    #>
    [CmdletBinding()]
    # Add-Type can run arbitrary code if its source is untrusted input - here
    # the source is a fixed string literal in this file, never built from a
    # request. Same reasoning as [scriptblock]::Create in src/App.ps1.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('InjectionRisk.AddType', '', Justification = 'Fixed string literal in this file, never built from request/network data.')]
    param()

    if (-not ('OpsBridge.ShutdownSignal' -as [type])) {
        Add-Type -Namespace OpsBridge -Name ShutdownSignal -MemberDefinition @'
public static volatile bool Requested = false;
// Keeps the two signal registrations alive for the process lifetime.
// PosixSignalRegistration is IDisposable; with nothing referencing it, the
// GC can collect it, which silently un-registers the handler.
public static object[] Registrations;
public static void Handle(System.Runtime.InteropServices.PosixSignalContext ctx) {
    // Prevent the runtime's default action (immediate termination) so the
    // Pode-side watcher (Add-ShutdownWatcherTimer) gets a chance to drain.
    ctx.Cancel = true;
    Requested = true;
}
'@
    }

    $callback = [Action[System.Runtime.InteropServices.PosixSignalContext]][OpsBridge.ShutdownSignal]::Handle
    [OpsBridge.ShutdownSignal]::Registrations = @(
        [System.Runtime.InteropServices.PosixSignalRegistration]::Create([System.Runtime.InteropServices.PosixSignal]::SIGTERM, $callback)
        [System.Runtime.InteropServices.PosixSignalRegistration]::Create([System.Runtime.InteropServices.PosixSignal]::SIGINT, $callback)
    )
}

function Test-AppShutdownRequested {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not ('OpsBridge.ShutdownSignal' -as [type])) {
        return $false
    }
    return [OpsBridge.ShutdownSignal]::Requested
}

function Add-ShutdownGateMiddleware {
    <#
        Registered right after security headers (src/App.ps1) - rejects a
        request the instant shutdown is signalled, without waiting for
        Pode's own ~1s Terminate poll.
    #>
    Add-PodeMiddleware -Name 'ShutdownGate' -ScriptBlock {
        try {
            if (Test-AppShutdownRequested) {
                Send-ApiError -StatusCode 503 -Code 'SHUTTING_DOWN' -Message 'The server is shutting down and is not accepting new requests.' -Category 'overload' -Retryable $true
                return $false
            }
            return $true
        }
        catch {
            Write-AppErrorLog -Exception $_.Exception
            return $true
        }
    }
}

function Add-ShutdownWatcherTimer {
    <#
        Checks the signal flag once a second, from inside a real Pode
        runspace where calling Close-PodeServer is safe. Safe to call more
        than once, so no extra guard is needed here.
    #>
    Add-PodeTimer -Name 'ShutdownSignalWatcher' -Interval 1 -ScriptBlock {
        if (Test-AppShutdownRequested) {
            Close-PodeServer
        }
    }
}

function Wait-AppShutdownDrain {
    <#
        Called from Pode's Terminate event (src/App.ps1). Blocks until every
        in-flight request finishes or API_SHUTDOWN_TIMEOUT_SECONDS elapses,
        whichever is first - Pode does not close its listeners until this
        returns.
    #>
    [CmdletBinding()]
    param()

    $config = Get-PodeState -Name 'AppConfig'
    $semaphore = Get-PodeState -Name 'ConcurrencySemaphore'
    $deadline = [datetime]::UtcNow.AddSeconds($config.ShutdownTimeoutSeconds)

    Write-AppLog -Level Info -Event 'application.shutdown.started' -Data @{
        inFlightRequests       = $config.MaxInFlightRequests - $semaphore.CurrentCount
        shutdownTimeoutSeconds = $config.ShutdownTimeoutSeconds
    }

    while ($semaphore.CurrentCount -lt $config.MaxInFlightRequests -and [datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }

    $drained = $semaphore.CurrentCount -eq $config.MaxInFlightRequests
    Write-AppLog -Level Info -Event 'application.shutdown.completed' -Data @{
        drained          = $drained
        inFlightRequests = $config.MaxInFlightRequests - $semaphore.CurrentCount
    }
}

function Invoke-AppShutdownTerminateHandler {
    <#
        The body of the Register-PodeEvent -Type Terminate registration in
        src/App.ps1 - pulled out into its own function, not left as an
        inline scriptblock, for two reasons: it is unit-testable this way
        (same reasoning as New-WrappedRouteScriptBlock in src/App.ps1), and
        it can re-source what it calls itself rather than trusting ambient
        availability.

        That trust turned out to be misplaced: Pode invokes a registered
        event's scriptblock via its own GetNewClosure() at *fire* time, not
        at Register-PodeEvent time - so a variable like $root, valid when
        this was originally written inline, is already out of scope by the
        time Terminate actually fires. Verified directly: this intermittently
        made Wait-AppShutdownDrain "not recognized" in that context, which
        silently skipped the drain wait entirely - the exact ungraceful-
        shutdown failure mode this mechanism exists to prevent. A fresh
        Get-PodeServerPath call has no such problem (Pode resolves it from
        its own server context, not a closure), so every dependency this
        function needs is re-sourced from that, every time, regardless of
        which runspace ends up running it.
    #>
    [CmdletBinding()]
    param()

    $terminateRoot = Get-PodeServerPath
    . (Join-Path $terminateRoot 'src/logging/Logging.ps1')
    . (Join-Path $terminateRoot 'src/middleware/CorrelationId.ps1')

    Wait-AppShutdownDrain
    Write-AppLog -Level Info -Event 'application.stopped'
}
