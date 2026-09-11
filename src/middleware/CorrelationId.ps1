<#
.SYNOPSIS
    Correlation ID middleware.
.DESCRIPTION
    Reuses a client-supplied X-Correlation-ID when it is well-formed, otherwise
    generates one from Pode's own per-request ContextId. The resolved id is:
      - stored on $WebEvent.Data.CorrelationId for the lifetime of the request
      - echoed to the client via the X-Correlation-ID response header
      - available to logging / error responses through Get-CorrelationId

    A client value is only accepted if it matches Test-CorrelationIdFormat - this
    closes off header/log-injection and reflected-XSS via an echoed header, and
    caps the length so a client cannot push arbitrarily large values into logs.

    This must be the first middleware registered (src/App.ps1) so every other
    middleware, route and log entry has a correlation id available.
#>

# Accepted shape for a client-supplied correlation id: url-safe characters only,
# 1-128 chars. Anything else is discarded and a fresh id is generated instead.
#
# The pattern ends with \z, not $: in .NET regex $ also matches just before a
# trailing newline, so '^[A-Za-z0-9_-]{1,128}$' would accept "abc`n" - letting a
# newline through into the echoed X-Correlation-ID header. \z anchors to the very
# end of the string with no exception.
function Test-CorrelationIdFormat {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]
        $Value
    )

    return [bool]($Value -match '^[A-Za-z0-9_-]{1,128}\z')
}

function Add-CorrelationIdMiddleware {
    Add-PodeMiddleware -Name 'CorrelationId' -ScriptBlock {
        try {
            $correlationId = $null

            if (Test-PodeHeader -Name 'X-Correlation-ID') {
                $value = Get-PodeHeader -Name 'X-Correlation-ID'
                if (Test-CorrelationIdFormat -Value $value) {
                    $correlationId = $value
                }
            }

            if (-not $correlationId) {
                $correlationId = "$($WebEvent.ContextId)"
            }

            $WebEvent.Data.CorrelationId = $correlationId
            Set-PodeHeader -Name 'X-Correlation-ID' -Value $correlationId
        }
        catch {
            # Never let correlation-id handling fail a request; fall back to the
            # Pode context id so downstream logging still has something.
            try { Write-AppErrorLog -Exception $_.Exception } catch { $null = $_ }
            if ($null -ne $WebEvent -and $null -ne $WebEvent.Data) {
                $WebEvent.Data.CorrelationId = "$($WebEvent.ContextId)"
            }
        }

        return $true
    }
}

function Get-CorrelationId {
    # $WebEvent.Data is null for requests Pode short-circuits before this
    # middleware runs. Guarded here because Write-AppLog calls this even outside
    # a request (e.g. at startup, where $WebEvent is $null entirely).
    if ($null -ne $WebEvent -and $null -ne $WebEvent.Data -and $WebEvent.Data.ContainsKey('CorrelationId')) {
        return $WebEvent.Data.CorrelationId
    }

    return $null
}
