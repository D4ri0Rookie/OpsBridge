<#
.SYNOPSIS
    Integration tests for the actual JSON content of the structured logs
    (docs/logging.md), not just the HTTP-visible side effects (headers,
    error bodies) other integration tests already cover.
.DESCRIPTION
    Every other test that touches correlation id / logging asserts through
    the HTTP response only - nothing reads the log files back and checks they
    match the schema docs/logging.md promises. That schema (field names,
    ISO-8601 UTC timestamp format) is a real contract: a future change to
    src/logging/Logging.ps1 could silently break it without any test
    noticing, the same way the Pode-runspace bug in that file once broke
    Write-AppLog from inside a route handler with no unit test able to catch
    it (see docs/architecture.md's "Gotcha" note).
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $PSScriptRoot 'TestServer.ps1')
    $script:Server = Start-TestServer -RepoRoot $script:RepoRoot
    $script:BaseUrl = $script:Server.BaseUrl
    $script:LogsPath = Join-Path $script:RepoRoot 'logs'

    # The exact ISO-8601 shape docs/logging.md documents: UTC, millisecond
    # precision, literal 'Z' offset - e.g. 2026-09-11T15:42:12.123Z.
    $script:IsoTimestampPattern = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$'

    # Defined here, not at file scope: Pester 6 does not guarantee a plain
    # top-level function is resolvable from inside an It block during the run
    # phase - only what BeforeAll establishes reliably is.
    function Assert-IsoUtcTimestamp {
        param([string]$Timestamp)

        $Timestamp | Should -Match $script:IsoTimestampPattern

        $parsed = [datetime]::ParseExact(
            $Timestamp,
            'yyyy-MM-ddTHH:mm:ss.fffZ',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        )

        $parsed.Kind | Should -Be ([System.DateTimeKind]::Utc)
        # Sanity bound, not just format-valid: catches a timestamp built from
        # the wrong clock/base (e.g. local time mislabelled as UTC, or Unix
        # epoch).
        ([datetime]::UtcNow - $parsed).TotalMinutes | Should -BeLessThan 5
    }

    # Wait-ForLogEntry (TestServer.ps1) matches by substring, which is right
    # for a correlation id (effectively unique text) but wrong for a numeric
    # field like port: JSON key order from an unordered hashtable is not
    # guaranteed, so "port" can land anywhere in the line, and a substring
    # match on "port":8080 would also hit a differently-ordered "port":80801.
    # Parse every candidate line and compare the field numerically instead.
    function Wait-ForApplicationLogEntryByPort {
        param(
            [int]$Port,
            [int]$TimeoutSeconds = 10
        )

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            $files = Get-ChildItem -Path $script:LogsPath -Filter 'application_*.log' -File -ErrorAction SilentlyContinue
            foreach ($file in $files) {
                $candidates = Get-Content -Path $file.FullName -ErrorAction SilentlyContinue |
                    Where-Object { $_ -like '*"event":"application.started"*' } |
                    ForEach-Object { ($_ | ConvertFrom-Json) | Add-Member -NotePropertyName 'RawLine' -NotePropertyValue $_ -PassThru } |
                    Where-Object { $_.port -eq $Port }
                if ($candidates) {
                    return $candidates | Select-Object -Last 1
                }
            }
            Start-Sleep -Milliseconds 200
        }

        return $null
    }
}

AfterAll {
    Stop-TestServer -Server $script:Server
    Clear-TestServerEnv
}

Describe 'Application log content' {
    It 'writes an application.started entry with the documented schema and a valid ISO-8601 UTC timestamp' {
        # Other integration test files' server instances also write to
        # logs/application_*.log, from separate OS processes with no
        # ordering guarantee between them - matching on this instance's own
        # (randomly chosen, effectively unique) port is what makes this
        # reliable, not "the last line".
        $entry = Wait-ForApplicationLogEntryByPort -Port $script:Server.Port

        $entry | Should -Not -BeNullOrEmpty
        $entry.event | Should -Be 'application.started'
        $entry.application | Should -Be 'OpsBridge'
        $entry.environment | Should -Be 'Test'
        $entry.level | Should -Be 'Informational'
        $entry.correlationId | Should -BeNullOrEmpty

        Assert-IsoUtcTimestamp -Timestamp (Get-RawJsonStringField -Line $entry.RawLine -Field 'timestamp')
    }
}

Describe 'Request log content' {
    It 'writes an http.request.completed entry with the documented schema, correlated by id' {
        $id = "logging-test-$([guid]::NewGuid().ToString('N'))"
        Invoke-WebRequest -Uri "$script:BaseUrl/health/live" -Headers @{ 'X-Correlation-ID' = $id } -UseBasicParsing | Out-Null

        $entry = Wait-ForLogEntry -LogsPath $script:LogsPath -FileFilter 'requests_*.log' -Contains "`"correlationId`":`"$id`""

        $entry | Should -Not -BeNullOrEmpty
        $entry.event | Should -Be 'http.request.completed'
        $entry.application | Should -Be 'OpsBridge'
        $entry.environment | Should -Be 'Test'
        $entry.level | Should -Be 'Informational'
        $entry.method | Should -Be 'GET'
        $entry.path | Should -Be '/health/live'
        $entry.statusCode | Should -Be 200
        $entry.durationMs | Should -BeGreaterOrEqual 0
        $entry.correlationId | Should -Be $id

        Assert-IsoUtcTimestamp -Timestamp (Get-RawJsonStringField -Line $entry.RawLine -Field 'timestamp')
    }

    It 'marks a client error (4xx) as http.request.completed, not http.request.failed' {
        # http.request.failed is reserved for 5xx (docs/logging.md) - a 404 is
        # an ordinary, correctly-handled response, not a server failure.
        $id = "logging-test-404-$([guid]::NewGuid().ToString('N'))"
        try {
            Invoke-WebRequest -Uri "$script:BaseUrl/does-not-exist" -Headers @{ 'X-Correlation-ID' = $id } -UseBasicParsing
        }
        catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $null = $_
        }

        $entry = Wait-ForLogEntry -LogsPath $script:LogsPath -FileFilter 'requests_*.log' -Contains "`"correlationId`":`"$id`""

        $entry | Should -Not -BeNullOrEmpty
        $entry.event | Should -Be 'http.request.completed'
        $entry.statusCode | Should -Be 404
    }
}
