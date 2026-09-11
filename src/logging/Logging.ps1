<#
.SYNOPSIS
    Structured JSON logging on top of Pode 2.14.1's native logging framework
    (Log Types + Log Methods).
.DESCRIPTION
    Three separate log streams, each a Pode Custom Log Type so every entry can
    carry the request's correlation id and OpsBridge's own field names:
      - Application : lifecycle / service / external-dependency events
                       (application.started, service.operation.failed, ...)
      - RequestLog   : one entry per HTTP request (written by the endware in
                       src/middleware/RequestLogging.ps1)
      - Error        : unhandled exceptions, via Pode's native automatic capture
                       (Enable-PodeErrorLogging), extended with Metadata so
                       correlation id / route context can be attached.

    Every stream writes structured JSON. Destination (stdout / file / both) is
    controlled by API_LOG_DESTINATION (see src/config/Config.ps1) - stdout is preferred
    for containers (docs/logging.md); file logging is optional and never a
    startup dependency.

    Field names in every emitted log line are lowerCamelCase, matching
    docs/logging.md exactly: timestamp, level, event, application, environment,
    correlationId, plus event-specific fields. Never log secrets, tokens,
    Authorization headers, or raw exception/query-string content that might
    carry them - see docs/logging.md "Sensitive data policy".
#>

function Get-AppLogLevelOrder {
    # A function, not a $script: variable: Pode's Use-PodeScript propagates
    # function definitions into every runspace (web/route, middleware, main),
    # but a bare top-level assignment like `$script:x = ...` only takes effect
    # in the runspace that happened to dot-source this file first - other
    # runspaces see the variable as $null. Write-AppLog is called from route
    # handlers, which run in a different runspace than Initialize-AppLogging,
    # so this state must be a function call, not a shared variable.
    [OutputType([string[]])]
    param()
    return @('Emergency', 'Alert', 'Critical', 'Error', 'Warning', 'Notice', 'Informational', 'Verbose', 'Debug')
}

function Get-AppLogLevelMap {
    # Same reasoning as Get-AppLogLevelOrder above.
    [OutputType([hashtable])]
    param()
    return @{ Debug = 'Debug'; Info = 'Informational'; Warning = 'Warning'; Error = 'Error' }
}

function Get-AppTimestamp {
    <#
        One timestamp format across every log line: UTC, ISO-8601, millisecond
        precision. The Application, Request and Error logs are correlated by
        correlationId and, failing that, by time - so their timestamps must be in
        the same zone regardless of where the host is or how it is configured.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [datetime]
        $Instant = [datetime]::UtcNow
    )

    return $Instant.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
}

function Get-PodeLevelsAtOrAbove {
    param([Parameter(Mandatory = $true)][string]$MinLevel)

    $order = Get-AppLogLevelOrder
    $index = [array]::IndexOf($order, $MinLevel)
    if ($index -lt 0) {
        # Guard the PowerShell range footgun: $order[0..-1] is NOT empty, it is
        # @($order[0], $order[-1]) - which would silently enable only Emergency +
        # Debug. Fail loudly instead so a level/map drift is caught at startup.
        throw "Get-PodeLevelsAtOrAbove: unknown level '$MinLevel'. Expected one of: $($order -join ', ')."
    }
    return $order[0..$index]
}

function Initialize-AppLogging {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Config)

    $minLevel = (Get-AppLogLevelMap)[$Config.LogLevel]
    $appLevels = Get-PodeLevelsAtOrAbove -MinLevel $minLevel

    $appMethods = @()
    $requestMethods = @()
    $errorMethods = @()

    if ($Config.LogDestination -in @('stdout', 'both')) {
        $terminalId = New-PodeLogTerminalMethod
        $appMethods += $terminalId
        $requestMethods += $terminalId
        $errorMethods += $terminalId
    }

    if ($Config.LogDestination -in @('file', 'both')) {
        $appMethods += (New-PodeLogFileMethod -Name 'application' -Path $Config.LogPath -MaxDays $Config.LogRetentionDays)
        $requestMethods += (New-PodeLogFileMethod -Name 'requests' -Path $Config.LogPath -MaxDays $Config.LogRetentionDays)
        $errorMethods += (New-PodeLogFileMethod -Name 'errors' -Path $Config.LogPath -MaxDays $Config.LogRetentionDays)
    }

    Add-PodeLogType -Name 'Application' -Method $appMethods -Levels $appLevels -SerialiseFormat Json -Version 2 -ScriptBlock {
        param($logEvent)
        $cfg = Get-PodeState -Name 'AppConfig'
        $item = [ordered]@{
            timestamp     = $logEvent.Data.Timestamp
            level         = "$($logEvent.Level)"
            event         = $logEvent.Data.Event
            application   = 'OpsBridge'
            environment   = $cfg.Environment
            correlationId = $logEvent.Data.CorrelationId
        }
        if ($logEvent.Data.Extra) {
            foreach ($key in $logEvent.Data.Extra.Keys) {
                $item[$key] = $logEvent.Data.Extra[$key]
            }
        }
        return $item
    }

    Add-PodeLogType -Name 'RequestLog' -Method $requestMethods -Levels @('Informational', 'Error') -SerialiseFormat Json -Version 2 -ScriptBlock {
        param($logEvent)
        $cfg = Get-PodeState -Name 'AppConfig'
        $item = [ordered]@{
            timestamp     = $logEvent.Data.Timestamp
            level         = "$($logEvent.Level)"
            event         = $logEvent.Data.Event
            application   = 'OpsBridge'
            environment   = $cfg.Environment
            correlationId = $logEvent.Data.CorrelationId
            method        = $logEvent.Data.Method
            path          = $logEvent.Data.Path
            statusCode    = $logEvent.Data.StatusCode
            durationMs    = $logEvent.Data.DurationMs
        }
        if ($logEvent.Data.ErrorType) {
            $item.errorType = $logEvent.Data.ErrorType
        }
        return $item
    }

    Enable-PodeErrorLogging -Method $errorMethods -Levels @('Emergency', 'Alert', 'Critical', 'Error', 'Warning') -SerialiseFormat Json -ScriptBlock {
        param($logEvent)
        $cfg = Get-PodeState -Name 'AppConfig'
        [ordered]@{
            # Inline (not Get-AppTimestamp) - this scriptblock runs in Pode's
            # logging engine, where the src/ helper functions are not loaded.
            timestamp   = $logEvent.Data.Date.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            level       = "$($logEvent.Data.Level)"
            application = 'OpsBridge'
            environment = $cfg.Environment
            category    = $logEvent.Data.Category
            message     = $logEvent.Data.Message
            stackTrace  = $logEvent.Data.StackTrace
            metadata    = $logEvent.Metadata
        }
    }
}

function Write-AppLog {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]
        $Level = 'Info',

        # Event category, e.g. 'application.started', 'service.operation.failed'.
        # See docs/logging.md for the full taxonomy.
        [Parameter(Mandatory = $true)]
        [string]
        $Event,

        # Extra fields merged verbatim (flat, top-level) into the JSON line - use
        # lowerCamelCase keys to match the rest of the schema.
        [Parameter()]
        [hashtable]
        $Data
    )

    $item = @{
        Timestamp     = (Get-AppTimestamp)
        Event         = $Event
        CorrelationId = (Get-CorrelationId)
        Extra         = $Data
    }

    Write-PodeLog -Name 'Application' -Level (Get-AppLogLevelMap)[$Level] -InputObject $item
}

function Write-AppErrorLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Exception')]
        [System.Exception]
        $Exception,

        [Parameter(Mandatory = $true, ParameterSetName = 'Message')]
        [string]
        $Message
    )

    $metadata = @{
        correlationId = (Get-CorrelationId)
    }
    if ($null -ne $WebEvent) {
        $metadata.route = $WebEvent.Path
    }

    if ($PSCmdlet.ParameterSetName -eq 'Exception') {
        Write-PodeErrorLog -Exception $Exception -Metadata $metadata
    }
    else {
        Write-PodeErrorLog -Message $Message -Metadata $metadata
    }
}
