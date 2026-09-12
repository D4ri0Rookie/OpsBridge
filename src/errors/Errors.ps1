<#
.SYNOPSIS
    Standardized JSON error response for every route handler.
.DESCRIPTION
    Every error OpsBridge returns - validation, not-found, unexpected failure -
    shares one body shape:

        { "error": { "code", "message", "correlationId", "details"?, "category"?, "retryable"? } }

    "category" and "retryable" are optional fields (docs/api.md), included only
    when supplied - same pattern as "correlationId"/"details". They're set on
    the newer runtime-protection errors (validation, rate_limit, overload,
    timeout, internal); older sources (404, the Windows service-manager 503)
    are left alone rather than forced into a category that doesn't fit. This
    is additive, not a breaking change to the envelope.

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
        $Details,

        # One of: validation, rate_limit, overload, timeout, internal (docs/api.md).
        # Omitted entirely when not supplied - see the file synopsis.
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]
        $Category,

        # Whether retrying the same request later could succeed. Must be an
        # actual boolean when supplied, never a string - omitted when $null.
        [Parameter()]
        [AllowNull()]
        [Nullable[bool]]
        $Retryable
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

    if (-not [string]::IsNullOrEmpty($Category)) {
        $errorBody.category = $Category
    }

    if ($null -ne $Retryable) {
        $errorBody.retryable = [bool]$Retryable
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
        $Details,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]
        $Category,

        [Parameter()]
        [AllowNull()]
        [Nullable[bool]]
        $Retryable
    )

    $correlationId = $null
    if (Get-Command -Name 'Get-CorrelationId' -ErrorAction SilentlyContinue) {
        $correlationId = Get-CorrelationId
    }

    $body = New-ApiErrorBody -Code $Code -Message $Message -CorrelationId $correlationId -Details $Details -Category $Category -Retryable $Retryable

    Set-PodeResponseStatus -Code $StatusCode -Description $Message -NoErrorPage
    Write-PodeJsonResponse -StatusCode $StatusCode -Value $body
}
