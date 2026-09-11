<#
.SYNOPSIS
    Centralized application configuration with environment variable overrides.
.DESCRIPTION
    Single source of truth for runtime configuration. Every value has a sensible
    default and can be overridden via an API_* environment variable. No secrets
    are stored here - this is what lets the same artifact be promoted unchanged
    from Development to Test to Production (see docs/configuration.md).

    'AppVersion' is the single source of truth for the application version - it is
    reported by /health/ready and logged at startup. Update it here only.

    An override that fails validation is discarded (the default is kept) and a
    warning is emitted via Write-Warning. The bootstrap (src/App.ps1) captures
    those warnings with -WarningVariable and re-logs them through the structured
    Application log once logging is up, so a bad API_* value is diagnosable from
    the logs without attaching to the process.
#>

function Get-AppConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $RootPath
    )

    $config = [ordered]@{
        AppVersion       = '0.1.0'
        Environment      = 'Development'   # Development, Test, Production
        ListenAddress    = '0.0.0.0'       # container-friendly default
        Port             = 8080
        Protocol         = 'Http'          # Http, Https
        CertPath         = ''              # path to a .pfx, only used when Protocol=Https and not self-signed
        CertSelfSigned   = $false          # Https with a Pode-generated self-signed cert (dev/test only)
        Threads          = 3               # Pode worker runspaces
        Daemon           = $false          # Start-PodeServer -Daemon (service/background mode)
        LogLevel         = 'Info'          # Debug, Info, Warning, Error
        LogFormat        = 'json'          # only 'json' is supported today
        LogDestination   = 'stdout'        # stdout, file, both
        LogPath          = (Join-Path $RootPath 'logs')
        LogRetentionDays = 7
    }

    if ($env:API_ENVIRONMENT) {
        if ($env:API_ENVIRONMENT -in @('Development', 'Test', 'Production')) {
            $config.Environment = $env:API_ENVIRONMENT
        }
        else {
            Write-Warning "API_ENVIRONMENT '$($env:API_ENVIRONMENT)' is not one of Development/Test/Production; keeping default $($config.Environment)."
        }
    }

    if ($env:API_HOST) { $config.ListenAddress = $env:API_HOST }

    if ($env:API_PORT) {
        $parsedPort = 0
        if ([int]::TryParse($env:API_PORT, [ref]$parsedPort) -and $parsedPort -ge 1 -and $parsedPort -le 65535) {
            $config.Port = $parsedPort
        }
        else {
            Write-Warning "API_PORT '$($env:API_PORT)' is not an integer in 1-65535; keeping default $($config.Port)."
        }
    }

    if ($env:API_PROTOCOL) {
        if ($env:API_PROTOCOL -in @('Http', 'Https')) {
            $config.Protocol = $env:API_PROTOCOL
        }
        else {
            Write-Warning "API_PROTOCOL '$($env:API_PROTOCOL)' is not one of Http/Https; keeping default $($config.Protocol)."
        }
    }

    if ($env:API_CERT_PATH) { $config.CertPath = $env:API_CERT_PATH }

    if ($env:API_CERT_SELF_SIGNED) {
        $truthy = @('1', 'true', 'yes', 'on')
        $falsy = @('0', 'false', 'no', 'off')
        if ($env:API_CERT_SELF_SIGNED.ToLowerInvariant() -in $truthy) {
            $config.CertSelfSigned = $true
        }
        elseif ($env:API_CERT_SELF_SIGNED.ToLowerInvariant() -notin $falsy) {
            Write-Warning "API_CERT_SELF_SIGNED '$($env:API_CERT_SELF_SIGNED)' is not a boolean (true/false); keeping default $($config.CertSelfSigned)."
        }
    }

    # API_CERT_PASSWORD is deliberately NOT read here. It is a secret, and this
    # function's output is stored as shared Pode state (Set-PodeState 'AppConfig',
    # readable from any runspace) and partly written into the Application log -
    # this is where the "no secrets are stored here" guarantee in the file
    # header comes from. src/App.ps1 reads $env:API_CERT_PASSWORD directly, only
    # at the single point it hands it to Add-PodeEndpoint.

    if ($env:API_THREADS) {
        $parsedThreads = 0
        if ([int]::TryParse($env:API_THREADS, [ref]$parsedThreads) -and $parsedThreads -ge 1) {
            $config.Threads = $parsedThreads
        }
        else {
            Write-Warning "API_THREADS '$($env:API_THREADS)' is not an integer >= 1; keeping default $($config.Threads)."
        }
    }

    if ($env:API_DAEMON) {
        $truthy = @('1', 'true', 'yes', 'on')
        $falsy = @('0', 'false', 'no', 'off')
        if ($env:API_DAEMON.ToLowerInvariant() -in $truthy) {
            $config.Daemon = $true
        }
        elseif ($env:API_DAEMON.ToLowerInvariant() -notin $falsy) {
            Write-Warning "API_DAEMON '$($env:API_DAEMON)' is not a boolean (true/false); keeping default $($config.Daemon)."
        }
    }

    if ($env:API_LOG_LEVEL) {
        if ($env:API_LOG_LEVEL -in @('Debug', 'Info', 'Warning', 'Error')) {
            $config.LogLevel = $env:API_LOG_LEVEL
        }
        else {
            Write-Warning "API_LOG_LEVEL '$($env:API_LOG_LEVEL)' is not one of Debug/Info/Warning/Error; keeping default $($config.LogLevel)."
        }
    }

    if ($env:API_LOG_FORMAT) {
        if ($env:API_LOG_FORMAT -eq 'json') {
            $config.LogFormat = $env:API_LOG_FORMAT
        }
        else {
            Write-Warning "API_LOG_FORMAT '$($env:API_LOG_FORMAT)' is not supported (only 'json' is); keeping default $($config.LogFormat)."
        }
    }

    if ($env:API_LOG_DESTINATION) {
        if ($env:API_LOG_DESTINATION -in @('stdout', 'file', 'both')) {
            $config.LogDestination = $env:API_LOG_DESTINATION
        }
        else {
            Write-Warning "API_LOG_DESTINATION '$($env:API_LOG_DESTINATION)' is not one of stdout/file/both; keeping default $($config.LogDestination)."
        }
    }

    if ($env:API_LOG_PATH) { $config.LogPath = $env:API_LOG_PATH }

    if ($env:API_LOG_RETENTION_DAYS) {
        $parsedRetention = 0
        if ([int]::TryParse($env:API_LOG_RETENTION_DAYS, [ref]$parsedRetention) -and $parsedRetention -ge 1) {
            $config.LogRetentionDays = $parsedRetention
        }
        else {
            Write-Warning "API_LOG_RETENTION_DAYS '$($env:API_LOG_RETENTION_DAYS)' is not an integer >= 1; keeping default $($config.LogRetentionDays)."
        }
    }

    return $config
}
