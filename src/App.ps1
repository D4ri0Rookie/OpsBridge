<#
.SYNOPSIS
    Application bootstrap and route wiring - the single coordination point for
    OpsBridge.
.DESCRIPTION
    Start-ApplicationServer:
      1. reads configuration (src/config/Config.ps1)
      2. runs a pre-flight port-availability check
      3. starts the Pode server with the configured worker thread count
      4. inside the server: loads the src/ components, initialises logging,
         replays any configuration warnings, registers the endpoint, middleware
         and routes, registers the shutdown event, then marks the application
         ready.

    This file coordinates; it does not contain the detailed logic of any
    individual component (that lives in src/config/Config.ps1,
    src/logging/Logging.ps1, src/errors/Errors.ps1, src/middleware/*).
    server.ps1 only calls this function - adding an endpoint never requires
    touching this file.

    Add-AppRoute / Register-ApplicationRoutes also live here rather than in a
    separate "routing" layer: OpsBridge deliberately keeps the framework surface
    a new route/service author has to understand to a minimum (docs/api.md).
#>

function Write-BootstrapLog {
    <#
        Covers the handful of events that happen outside Pode's own lifecycle -
        a fatal pre-flight failure, or the final "server stopped" line. Console
        only: this runs before logging (and possibly before Pode) is up, and
        must not depend on the filesystem being writable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $Message,

        [Parameter()]
        [string]
        $Level = 'Info'
    )

    $timestamp = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    Write-Host "[$timestamp] [$Level] $Message"
}

function Resolve-ListenIPAddress {
    [CmdletBinding()]
    [OutputType([System.Net.IPAddress])]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $Address
    )

    switch -Regex ($Address) {
        '^localhost$' { return [System.Net.IPAddress]::Loopback }
        '^(\*|all|0\.0\.0\.0)$' { return [System.Net.IPAddress]::Any }
        default {
            [System.Net.IPAddress]$parsed = $null
            if ([System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) {
                return $parsed
            }
            return $null
        }
    }
}

function Test-ListenPortAvailable {
    <#
        Tries to bind the configured address/port before Pode does, so a busy
        port produces a clear "port in use" startup failure instead of a raw
        socket exception. For a bind address that cannot be resolved locally (a
        hostname) this returns $true and lets Pode be the authority.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $Address,

        [Parameter(Mandatory = $true)]
        [int]
        $Port
    )

    $ip = Resolve-ListenIPAddress -Address $Address
    if ($null -eq $ip) {
        return $true   # unresolvable bind address - let Pode try
    }

    $listener = [System.Net.Sockets.TcpListener]::new($ip, $Port)
    try {
        $listener.Start()
        return $true
    }
    catch [System.Net.Sockets.SocketException] {
        # Only a genuine "address already in use" is a port conflict. Any other
        # socket failure (permission, address not available) is left for Pode to
        # report with its own error rather than mislabelled as "port in use".
        if ($_.Exception.SocketErrorCode -eq [System.Net.Sockets.SocketError]::AddressAlreadyInUse) {
            return $false
        }
        return $true
    }
    catch {
        return $true
    }
    finally {
        try { $listener.Stop() } catch { $null = $_ }
    }
}

function Test-HttpsCertificateReady {
    <#
        Pre-flight check for a Https + non-self-signed configuration: fails
        fast with a clear reason (Test-ListenPortAvailable's counterpart for
        TLS) instead of letting Pode raise an opaque certificate-loading
        exception deep inside Start-PodeServer. A Http or self-signed
        configuration has nothing to check here and always passes.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $Protocol,

        [Parameter(Mandatory = $true)]
        [bool]
        $SelfSigned,

        [Parameter()]
        [AllowEmptyString()]
        [string]
        $CertPath
    )

    if ($Protocol -ne 'Https' -or $SelfSigned) {
        return $true
    }

    return (-not [string]::IsNullOrWhiteSpace($CertPath)) -and (Test-Path -Path $CertPath -PathType Leaf)
}

function New-RuntimeServerConfigFile {
    <#
        Only called when API_MAX_BODY_BYTES overrides the default. Pode reads
        Server.Request.BodySize once from its config file, before this
        script's own -ScriptBlock runs, and there is no cmdlet to change it
        afterwards - so this writes a copy of server.psd1 with just BodySize
        swapped, and starts Pode with -ConfigFile pointing at it. Reuses
        Pode's own size check (correct for chunked requests, which have no
        Content-Length to pre-check) instead of reimplementing it ourselves.

        -ConfigFile replaces the default server.psd1 lookup, it doesn't merge
        with it (docs/configuration.md), so this copies the whole file, not
        just the Request block. Written to a process-unique temp path so
        several test servers running at once never collide, and deleted once
        the server stops (Start-ApplicationServer's finally block).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $RootPath,

        [Parameter(Mandatory = $true)]
        [int]
        $MaxBodyBytes
    )

    $baseConfig = Import-PowerShellDataFile -Path (Join-Path $RootPath 'server.psd1')
    $timeout = [int]$baseConfig.Server.Request.Timeout
    $errorPagesDefault = $baseConfig.Web.ErrorPages.Default
    $showExceptions = if ([bool]$baseConfig.Web.ErrorPages.ShowExceptions) { '$true' } else { '$false' }

    $content = @"
@{
    Server = @{
        Request = @{
            Timeout  = $timeout
            BodySize = $MaxBodyBytes
        }
    }
    Web = @{
        ErrorPages = @{
            Default        = '$errorPagesDefault'
            ShowExceptions = $showExceptions
        }
    }
}
"@

    $path = Join-Path ([System.IO.Path]::GetTempPath()) "opsbridge-server-$PID.psd1"
    Set-Content -Path $path -Value $content -Encoding utf8 -NoNewline
    return $path
}

function New-WrappedRouteScriptBlock {
    <#
        Builds the actual scriptblock Add-AppRoute registers with Pode: the
        handler body spliced verbatim into a try/catch and recompiled with
        [scriptblock]::Create, so the result is exactly what Pode would run if
        the try/catch had been written inline in the route file - no
        runspace/closure or $using: concerns. Route handlers use $WebEvent /
        Get-PodeState, not $using:.

        Pode 2.14.1 does not pass the web event as a positional argument - it
        only sets $WebEvent in scope - so a handler that opens with a param()
        block would get $null for it and fail at runtime. Rejected here with a
        clear message instead of failing obscurely per-request.

        Pulled out of Add-AppRoute as its own function - with no Add-PodeRoute
        call in it - specifically so the unhandled-exception behaviour (catch,
        log, generic 500) can be unit-tested by building and invoking the
        wrapped scriptblock directly, without a running Pode server. See
        tests/unit/AppRoute.Tests.ps1.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    # InjectionHunter flags [scriptblock]::Create as a generic injection risk -
    # correct when building a command from untrusted request/network data, but
    # $handlerText below is a route file's own developer-authored source (read
    # from disk under src/routes/ at startup), never anything from an HTTP
    # request. This *is* the mechanism, not a shortcut around one - see the
    # synopsis above and tests/unit/AppRoute.Tests.ps1.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('InjectionRisk.Create', '', Justification = 'Recompiles a route file''s own source (disk, startup-time), never request/network data.')]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]
        $Method,

        [Parameter(Mandatory = $true)]
        [string]
        $Path,

        [Parameter(Mandatory = $true)]
        [scriptblock]
        $ScriptBlock
    )

    if ($ScriptBlock.Ast.ParamBlock) {
        throw "Add-AppRoute ($($Method -join ',') $Path): a route handler cannot declare a param() block. Read the request via `$WebEvent and shared state via Get-PodeState."
    }

    $handlerText = $ScriptBlock.ToString()

    return [scriptblock]::Create(@"
`$__handlerStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
try {
$handlerText
}
catch {
    `$__handlerError = `$_
    try { Write-AppErrorLog -Exception `$__handlerError.Exception } catch { `$null = `$_ }
    Send-ApiError -StatusCode 500 -Code 'INTERNAL_ERROR' -Message 'An unexpected error occurred.' -Category 'internal' -Retryable `$false
}
finally {
    # API_REQUEST_TIMEOUT_SECONDS (docs/configuration.md) is a *soft* budget:
    # logged when exceeded, not enforced. Aborting a running handler would
    # need a runspace per request - real overhead for a hang scenario no
    # current route can hit. This still logs a handler that is slow but does
    # return.
    `$__handlerStopwatch.Stop()
    try {
        `$__timeoutSeconds = (Get-PodeState -Name 'AppConfig').RequestTimeoutSeconds
        if (`$__handlerStopwatch.Elapsed.TotalSeconds -gt `$__timeoutSeconds) {
            Write-AppLog -Level Warning -Event 'application.timeout' -Data @{ path = "`$(`$WebEvent.Path)"; durationMs = [math]::Round(`$__handlerStopwatch.Elapsed.TotalMilliseconds, 2); timeoutSeconds = `$__timeoutSeconds }
            if (`$null -ne `$WebEvent -and `$null -ne `$WebEvent.Data) {
                `$WebEvent.Data.TimedOut = `$true
            }
        }
    }
    catch { `$null = `$_ }
}
"@)
}

function Add-AppRoute {
    <#
        Thin wrapper over Add-PodeRoute that gives every handler the same
        unhandled-exception behaviour: a handler that throws is logged to the
        Error log with the request's correlation id, and the client gets the
        standard coherent 500 body (INTERNAL_ERROR + correlationId) instead of
        a raw exception. The wrapping itself is built by
        New-WrappedRouteScriptBlock; this function only registers the result
        with Pode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]
        $Method,

        [Parameter(Mandatory = $true)]
        [string]
        $Path,

        [Parameter(Mandatory = $true)]
        [scriptblock]
        $ScriptBlock
    )

    $wrapped = New-WrappedRouteScriptBlock -Method $Method -Path $Path -ScriptBlock $ScriptBlock

    Add-PodeRoute -Method $Method -Path $Path -ScriptBlock $wrapped
}

function Register-ApplicationServices {
    <#
        Dot-sources every *.ps1 under src/services (recursively) into every Pode
        runspace via Use-PodeScript, so a route handler can call any service
        function regardless of which runspace serves the request. This is what
        makes "drop a file under services/<Area>/" sufficient to add a new
        capability (docs/architecture.md) - nothing here needs to change when a
        new services/VCenter/ or services/Azure/ folder is added.

        Runs before Register-ApplicationRoutes so route files can rely on their
        service functions already being defined.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $Path,

        [Parameter(Mandatory = $true)]
        [string]
        $RootPath
    )

    if (-not (Test-Path -Path $Path)) {
        return
    }

    $serviceFiles = @(Get-ChildItem -Path $Path -Filter '*.ps1' -File -Recurse | Sort-Object -Property FullName)

    foreach ($file in $serviceFiles) {
        $relativePath = [System.IO.Path]::GetRelativePath($RootPath, $file.FullName)
        Use-PodeScript -Path $relativePath
        . $file.FullName
        Write-AppLog -Level Info -Event 'application.service.loaded' -Data @{ file = $relativePath }
    }
}

function Register-ApplicationRoutes {
    <#
        Loads route files from $Path (unversioned - health, catch-all) and from
        $Path/v1 (versioned API resources). Each file is a self-contained unit
        that calls Add-AppRoute for one or more endpoints - adding an endpoint
        means adding a file, not changing this loader. A future v2 surface is
        added the same way, as $Path/v2.

        A missing routes directory or a file that fails to load is fatal: logged
        and re-thrown so startup fails loudly rather than serving a
        half-registered API.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $Path
    )

    if (-not (Test-Path -Path $Path)) {
        throw "Routes directory not found: $Path"
    }

    $groups = @($Path, (Join-Path $Path 'v1'))

    foreach ($group in $groups) {
        if (-not (Test-Path -Path $group)) {
            continue
        }

        $routeFiles = @(Get-ChildItem -Path $group -Filter '*.ps1' -File | Sort-Object -Property Name)

        foreach ($routeFile in $routeFiles) {
            try {
                . $routeFile.FullName
                Write-AppLog -Level Info -Event 'application.route.loaded' -Data @{ file = $routeFile.Name }
            }
            catch {
                Write-AppErrorLog -Exception $_.Exception
                throw "Failed to load route file '$($routeFile.Name)': $($_.Exception.Message)"
            }
        }
    }
}

function Start-ApplicationServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $RootPath
    )

    # Configuration is needed here (outside Pode) only for the worker thread
    # count and the pre-flight port check, both Start-PodeServer inputs. It is
    # re-read inside the server for everything else - Get-AppConfig is
    # deterministic for a given environment. Warnings are suppressed here and
    # re-logged, once, through the structured log inside the server.
    . (Join-Path $RootPath 'src/config/Config.ps1')
    try {
        $bootConfig = Get-AppConfig -RootPath $RootPath -WarningAction SilentlyContinue
    }
    catch {
        # Get-AppConfig throws for the hardening settings (docs/configuration.md)
        # instead of discarding-with-warning, so a bad value must abort
        # startup here, not surface as a raw exception.
        Write-BootstrapLog -Level Error -Message "Cannot start: invalid configuration - $($_.Exception.Message)"
        try { $Host.SetShouldExit(1) } catch { $null = $_ }
        exit 1
    }

    if (-not (Test-ListenPortAvailable -Address $bootConfig.ListenAddress -Port $bootConfig.Port)) {
        Write-BootstrapLog -Level Error -Message "Cannot start: $($bootConfig.ListenAddress):$($bootConfig.Port) is already in use. Set API_PORT to a free port or stop the process holding it."
        # server.ps1 carries a '#Requires -Modules' line, which makes a plain
        # `exit 1` surface as exit code 0. SetShouldExit forces the real code.
        try { $Host.SetShouldExit(1) } catch { $null = $_ }
        exit 1
    }

    if (-not (Test-HttpsCertificateReady -Protocol $bootConfig.Protocol -SelfSigned $bootConfig.CertSelfSigned -CertPath $bootConfig.CertPath)) {
        Write-BootstrapLog -Level Error -Message "Cannot start: API_PROTOCOL is Https but API_CERT_PATH ('$($bootConfig.CertPath)') does not point to an existing certificate file. Set API_CERT_PATH to a valid .pfx (and API_CERT_PASSWORD if it is password-protected), or set API_CERT_SELF_SIGNED=true for a development-only self-signed certificate."
        try { $Host.SetShouldExit(1) } catch { $null = $_ }
        exit 1
    }

    # Only generated when API_MAX_BODY_BYTES overrides the default - the common
    # case (no override) loads server.psd1 exactly as before, unchanged.
    # See New-RuntimeServerConfigFile for why this needs a real config file
    # rather than a runtime setter.
    $runtimeConfigPath = $null
    if ($env:API_MAX_BODY_BYTES) {
        $runtimeConfigPath = New-RuntimeServerConfigFile -RootPath $RootPath -MaxBodyBytes $bootConfig.MaxBodyBytes
    }

    # Must be registered before Start-PodeServer (which blocks until
    # shutdown) - see src/middleware/Shutdown.ps1 for why a real server
    # process, not a unit test dot-sourcing this file, is the only caller.
    . (Join-Path $RootPath 'src/middleware/Shutdown.ps1')
    Register-AppShutdownSignalHandler

    try {
        # -Daemon:$false is a no-op; -Daemon:$true runs Pode in background/service
        # mode (minimal console interaction), driven by API_DAEMON (set by
        # scripts/install-service.ps1 for the Windows service).
        $startServerParams = @{
            RootPath = $RootPath
            Threads  = $bootConfig.Threads
            Daemon   = $bootConfig.Daemon
        }
        if ($runtimeConfigPath) {
            $startServerParams.ConfigFile = $runtimeConfigPath
        }
        $startServerParams.ScriptBlock = {

            $root = Get-PodeServerPath

            # Use-PodeScript registers each file's functions into every Pode
            # runspace pool (so they are callable from deferred, per-request
            # scriptblocks - routes, middleware, endware). Its own dot-sourcing
            # runs inside Use-PodeScript's function scope, so a plain dot-source
            # is also needed to make the functions callable here, during setup.
            $components = @(
                'src/config/Config.ps1'
                'src/errors/Errors.ps1'
                'src/middleware/CorrelationId.ps1'
                'src/logging/Logging.ps1'
                'src/middleware/RequestLogging.ps1'
                'src/middleware/SecurityHeaders.ps1'
                'src/middleware/Shutdown.ps1'
                'src/middleware/RateLimit.ps1'
                'src/middleware/Authentication.ps1'
                'src/middleware/Concurrency.ps1'
                # App.ps1 itself: Start-PodeServer's -ScriptBlock runs inside
                # Pode's own session state, not the caller's, so Add-AppRoute /
                # Register-ApplicationRoutes / Register-ApplicationServices
                # (defined further up in this same file) must be re-registered
                # here too, exactly like every other component.
                'src/App.ps1'
            )
            foreach ($component in $components) {
                Use-PodeScript -Path $component
                . (Join-Path $root $component)
            }

            # --- configuration -------------------------------------------------
            $config = Get-AppConfig -RootPath $root -WarningVariable configWarnings -WarningAction SilentlyContinue
            Set-PodeState -Name 'AppConfig' -Value $config -NoPassThru

            # A SemaphoreSlim, not a plain counter: Get-PodeState returns this
            # exact object in every runspace, and only its own Wait()/Release()
            # are safe to call concurrently from multiple threads (see
            # src/middleware/Concurrency.ps1).
            Set-PodeState -Name 'ConcurrencySemaphore' -Value ([System.Threading.SemaphoreSlim]::new($config.MaxInFlightRequests, $config.MaxInFlightRequests)) -NoPassThru

            # A synchronized hashtable, not a plain one: src/middleware/RateLimit.ps1
            # locks its own SyncRoot around the check-reset-increment sequence.
            Set-PodeState -Name 'RateLimitState' -Value ([hashtable]::Synchronized(@{ Count = 0; WindowStart = [datetime]::UtcNow })) -NoPassThru

            # --- logging -----------------------------------------------------
            Initialize-AppLogging -Config $config

            # A rejected API_* override is now visible in the Application log,
            # not just on the console at startup.
            foreach ($warning in $configWarnings) {
                Write-AppLog -Level Warning -Event 'application.startup.warning' -Data @{ message = "Configuration: $warning" }
            }

            # --- endpoint ------------------------------------------------------
            if ($config.Protocol -eq 'Https') {
                if ($config.CertSelfSigned) {
                    Add-PodeEndpoint -Address $config.ListenAddress -Port $config.Port -Protocol Https -SelfSigned
                }
                else {
                    # $env:API_CERT_PASSWORD, not $config.CertPassword: the
                    # certificate password is a secret and deliberately never
                    # enters Get-AppConfig's output (see src/config/Config.ps1)
                    # since that hashtable is shared Pode state and partly
                    # logged. Read directly here, at the single point it is
                    # needed, and go no further with it.
                    $certEndpointParams = @{
                        Address     = $config.ListenAddress
                        Port        = $config.Port
                        Protocol    = 'Https'
                        Certificate = $config.CertPath
                    }
                    if ($env:API_CERT_PASSWORD) {
                        $certEndpointParams.CertificatePassword = $env:API_CERT_PASSWORD
                    }
                    Add-PodeEndpoint @certEndpointParams
                }
            }
            else {
                Add-PodeEndpoint -Address $config.ListenAddress -Port $config.Port -Protocol Http
            }

            Write-AppLog -Level Info -Event 'application.started' -Data @{
                appVersion    = $config.AppVersion
                podeVersion   = "$((Get-Module -Name Pode).Version)"
                psVersion     = "$($PSVersionTable.PSVersion)"
                listenAddress = $config.ListenAddress
                port          = $config.Port
                protocol      = $config.Protocol
                threads       = $config.Threads
                daemon        = $config.Daemon
                logLevel      = $config.LogLevel
                logDestination = $config.LogDestination
            }

            # --- middleware -------------------------------------------------
            # Order matters (docs/architecture.md): correlation id and security
            # headers first, so even a rejection below still carries them.
            # Then the shutdown gate, then rate limiting - a volumetric,
            # identity-blind defense that must apply to a request before its
            # credentials are even checked, otherwise a flood of unauthenticated
            # traffic would bypass it entirely. Authentication runs next, before
            # concurrency: an unauthenticated request is rejected doing no real
            # work, so it must never occupy a concurrency slot a legitimate
            # request might need. Route is last. The endware pair runs at the
            # end, regardless of outcome.
            Add-CorrelationIdMiddleware
            Add-SecurityHeadersMiddleware
            Add-ShutdownGateMiddleware
            Add-RateLimitMiddleware
            Add-AuthenticationMiddleware
            Add-ConcurrencyLimitMiddleware
            Add-ShutdownWatcherTimer
            Add-RequestLoggingEndware
            Add-ConcurrencyReleaseEndware

            # --- services ----------------------------------------------------
            Register-ApplicationServices -Path (Join-Path $root 'src/services') -RootPath $root

            # --- routes ----------------------------------------------------
            # src/routes/NotFound.ps1 is a catch-all: unmatched requests still run
            # the middleware above and get a coherent 404.
            Register-ApplicationRoutes -Path (Join-Path $root 'src/routes')

            # --- shutdown --------------------------------------------------
            # Pode fires Terminate just before it stops serving, listeners
            # still up. Invoke-AppShutdownTerminateHandler
            # (src/middleware/Shutdown.ps1) waits for in-flight requests and
            # logs the outcome (Write-BootstrapLog only logs the later
            # "Server stopped" line, after Pode has torn down) - pulled out
            # into its own function, not left as an inline scriptblock here,
            # specifically so it is unit-testable without a running Pode
            # server (same reasoning as New-WrappedRouteScriptBlock above)
            # and so it can re-source its own dependencies via a freshly
            # called Get-PodeServerPath rather than a closed-over $root: a
            # Terminate event's scriptblock is invoked by Pode via its own
            # GetNewClosure() at fire time, not at Register-PodeEvent time,
            # so $root here would already be out of scope by then - verified
            # directly, this intermittently made Wait-AppShutdownDrain "not
            # recognized", silently skipping the drain wait entirely.
            Register-PodeEvent -Type Terminate -Name 'AppShutdownLog' -ScriptBlock {
                # Guarantees Invoke-AppShutdownTerminateHandler itself is
                # defined here, for the same reason it re-sources its own
                # dependencies internally - see its own doc comment
                # (src/middleware/Shutdown.ps1).
                . (Join-Path (Get-PodeServerPath) 'src/middleware/Shutdown.ps1')
                Invoke-AppShutdownTerminateHandler
            }

            # --- ready ---------------------------------------------------
            Set-PodeState -Name 'AppReady' -Value $true -NoPassThru
            $scheme = $config.Protocol.ToLowerInvariant()
            Write-AppLog -Level Info -Event 'application.ready' -Data @{ url = "$($scheme)://$($config.ListenAddress):$($config.Port)" }
        }

        Start-PodeServer @startServerParams
    }
    catch {
        Write-BootstrapLog -Level Error -Message "Server error: $($_.Exception.Message)"
        try { $Host.SetShouldExit(1) } catch { $null = $_ }
        exit 1
    }
    finally {
        if ($runtimeConfigPath) {
            Remove-Item -Path $runtimeConfigPath -ErrorAction SilentlyContinue
        }
        Write-BootstrapLog -Level Info -Message 'Server stopped'
    }
}
