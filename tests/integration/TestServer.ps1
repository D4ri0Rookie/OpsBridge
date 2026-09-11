<#
.SYNOPSIS
    Shared helpers for the integration tests: start / stop a real OpsBridge
    server process on a free port. Dot-sourced from each integration test
    file's BeforeAll - these tests exercise the real HTTP contract, not an
    in-process function call.
#>

function Get-FreeTcpPort {
    # A random high port is picked per run (instead of a fixed one) so a stale
    # listener from a previous, forcibly-killed run can never collide with it.
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    return $port
}

function Start-TestServer {
    param(
        [string]$RepoRoot,

        # 'Https' starts the server with API_CERT_SELF_SIGNED=true - a
        # Pode-generated self-signed certificate, good enough to exercise the
        # TLS code path without a real certificate file in the repo.
        [ValidateSet('Http', 'Https')]
        [string]$Protocol = 'Http'
    )

    $port = Get-FreeTcpPort
    $env:API_PORT = $port
    $env:API_HOST = 'localhost'
    $env:API_LOG_DESTINATION = 'file'
    $env:API_ENVIRONMENT = 'Test'
    $env:API_PROTOCOL = $Protocol
    if ($Protocol -eq 'Https') {
        $env:API_CERT_SELF_SIGNED = 'true'
    }

    $serverScript = Join-Path $RepoRoot 'server.ps1'
    $stdErrLog = Join-Path ([System.IO.Path]::GetTempPath()) "opsbridge-it-$port.err.log"

    # $PSHOME/pwsh rather than the bare 'pwsh' name: on Windows the latter can
    # resolve to the App Execution Alias stub, which intermittently fails to
    # spawn (EPERM) when launched from an automated/non-interactive parent.
    $pwshName = if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }

    # -WindowStyle is Windows-only; Start-Process on Linux/macOS throws
    # NotSupportedException if it's passed at all, even as a no-op.
    $startProcessParams = @{
        FilePath               = (Join-Path $PSHOME $pwshName)
        ArgumentList            = @('-NoProfile', '-File', $serverScript)
        WorkingDirectory        = $RepoRoot
        PassThru                = $true
        RedirectStandardOutput  = (Join-Path ([System.IO.Path]::GetTempPath()) "opsbridge-it-$port.out.log")
        RedirectStandardError   = $stdErrLog
    }
    if ($IsWindows) {
        $startProcessParams.WindowStyle = 'Hidden'
    }

    $process = Start-Process @startProcessParams

    # 127.0.0.1 rather than 'localhost': on some hosts an unready/closed port on
    # the IPv6 loopback (::1) doesn't refuse the connection, it just hangs.
    $scheme = $Protocol.ToLowerInvariant()
    $baseUrl = "$($scheme)://127.0.0.1:$port"
    $readyCheckParams = @{ Uri = "$baseUrl/health/live"; TimeoutSec = 2 }
    if ($Protocol -eq 'Https') {
        # Self-signed - there is no CA chain to validate against.
        $readyCheckParams.SkipCertificateCheck = $true
    }
    $ready = $false
    $attempts = 0
    while (-not $ready -and $attempts -lt 40) {
        $attempts++
        Start-Sleep -Milliseconds 500
        try {
            Invoke-RestMethod @readyCheckParams | Out-Null
            $ready = $true
        }
        catch { $null = $_ }
    }

    if (-not $ready) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "Server on port $port did not become ready in time. Check $stdErrLog"
    }

    return [pscustomobject]@{ Process = $process; BaseUrl = $baseUrl; Port = $port }
}

function Stop-TestServer {
    param($Server)
    if ($Server -and $Server.Process) {
        Stop-Process -Id $Server.Process.Id -Force -ErrorAction SilentlyContinue
    }
}

function Clear-TestServerEnv {
    Remove-Item Env:\API_PORT, Env:\API_HOST, Env:\API_LOG_DESTINATION, Env:\API_ENVIRONMENT,
        Env:\API_PROTOCOL, Env:\API_CERT_SELF_SIGNED, Env:\API_CERT_PATH, Env:\API_CERT_PASSWORD `
        -ErrorAction SilentlyContinue
}

function Get-HeaderValue {
    param($Response, [string]$Name)
    ($Response.Headers[$Name] -join '')
}

# Reads a header off the HttpResponseMessage carried by an
# HttpResponseException (error responses), tolerating a missing header.
function Get-ErrorHeaderValue {
    param($Response, [string]$Name)
    $values = $null
    if ($Response.Headers.TryGetValues($Name, [ref]$values)) {
        return ($values -join '')
    }
    if ($Response.Content -and $Response.Content.Headers.TryGetValues($Name, [ref]$values)) {
        return ($values -join '')
    }
    return $null
}

# Polls the given log file(s) (glob under $LogsPath) for a line containing
# $Contains (a plain substring, not a regex - callers match on a JSON
# fragment like '"correlationId":"abc"'), and returns it parsed as an object,
# with the original raw line attached as a RawLine note property.
# Pode's file log method writes asynchronously, so a line written by a
# request made a moment ago may not be on disk yet - poll instead of a single
# fixed sleep, which is either too slow (always) or flaky (too short).
#
# RawLine matters because PowerShell's ConvertFrom-Json auto-detects
# ISO-8601-shaped string values and silently converts them to [datetime]
# objects, which then stringify with the current culture's default format
# (e.g. "09/11/2026 16:40:24", no milliseconds, no 'Z') - losing the exact
# wire format a test needs to verify. Use Get-RawJsonStringField against
# RawLine, not the parsed property, whenever the assertion is about the
# string's exact shape rather than its value.
function Wait-ForLogEntry {
    param(
        [string]$LogsPath,
        [string]$FileFilter,
        [string]$Contains,
        [int]$TimeoutSeconds = 10
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $files = Get-ChildItem -Path $LogsPath -Filter $FileFilter -File -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            $line = Get-Content -Path $file.FullName -ErrorAction SilentlyContinue |
                Where-Object { $_ -like "*$Contains*" } |
                Select-Object -Last 1
            if ($line) {
                return ($line | ConvertFrom-Json) | Add-Member -NotePropertyName 'RawLine' -NotePropertyValue $line -PassThru
            }
        }
        Start-Sleep -Milliseconds 200
    }

    return $null
}

# Extracts a top-level string field's literal value straight from a raw JSON
# log line via regex, bypassing ConvertFrom-Json entirely - see the note on
# Wait-ForLogEntry above for why that matters for date-shaped strings.
# Only reliable for fields whose value cannot itself contain a double quote
# (true for every field OpsBridge logs today: timestamps, ids, enum-like
# strings).
function Get-RawJsonStringField {
    param(
        [string]$Line,
        [string]$Field
    )

    $pattern = '"' + $Field + '":"([^"]*)"'
    if ($Line -match $pattern) {
        return $Matches[1]
    }
    return $null
}
