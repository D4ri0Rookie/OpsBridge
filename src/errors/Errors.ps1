<#
.SYNOPSIS
    Standardized JSON error response for every route handler.
.DESCRIPTION
    Every error OpsBridge returns - validation, not-found, unexpected failure -
    shares one body shape:

        { "error": { "code", "message", "correlationId", "details"? } }

    New-ApiErrorBody builds that hashtable and is pure (no Pode calls), so it is
    unit-testable without a running server. Send-ApiError is the thin route-facing
    wrapper that also sets the HTTP status and writes the response.

    Never pass exception messages, stack traces, file paths or other internal
    detail into $Message - those belong in the structured Error log only (see
    src/logging/Logging.ps1 / Write-AppErrorLog), tagged with the same
    correlation id.
#>

function New-ApiErrorBody {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $Code,

        [Parameter(Mandatory = $true)]
        [string]
        $Message,

        [Parameter()]
        [AllowNull()]
        [string]
        $CorrelationId,

        [Parameter()]
        [AllowNull()]
        [array]
        $Details
    )

    $errorBody = [ordered]@{
        code    = $Code
        message = $Message
    }

    if ($CorrelationId) {
        $errorBody.correlationId = $CorrelationId
    }

    if ($Details -and $Details.Count -gt 0) {
        $errorBody.details = $Details
    }

    return @{ error = $errorBody }
}

function Send-ApiError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]
        $StatusCode,

        [Parameter(Mandatory = $true)]
        [string]
        $Code,

        [Parameter(Mandatory = $true)]
        [string]
        $Message,

        [Parameter()]
        [array]
        $Details
    )

    $correlationId = $null
    if (Get-Command -Name 'Get-CorrelationId' -ErrorAction SilentlyContinue) {
        $correlationId = Get-CorrelationId
    }

    $body = New-ApiErrorBody -Code $Code -Message $Message -CorrelationId $correlationId -Details $Details

    Set-PodeResponseStatus -Code $StatusCode -Description $Message -NoErrorPage
    Write-PodeJsonResponse -StatusCode $StatusCode -Value $body
}
