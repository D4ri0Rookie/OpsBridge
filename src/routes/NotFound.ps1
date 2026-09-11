<#
.SYNOPSIS
    Catch-all route: coherent JSON 404 for any unmatched path.
.DESCRIPTION
    Registered as a real wildcard route so an unknown request still runs the
    correlation and security middleware and the request-log endware, and gets a
    body with `error.correlationId` - unlike Pode's built-in not-found handling,
    which answers before the application middleware.

    Registered per-method (not `-Method *`, which Pode checks *before* the
    method-specific routes and would shadow every real route). Within a method,
    Pode matches exact/parameterized paths first and only falls back to this
    wildcard, so registration order relative to other route files does not
    matter.
#>

Add-AppRoute -Method Get, Post, Put, Delete, Patch, Options, Head -Path '*' -ScriptBlock {
    Send-ApiError -StatusCode 404 -Code 'NOT_FOUND' -Message 'Resource not found.'
}
