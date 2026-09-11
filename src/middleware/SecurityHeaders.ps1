<#
.SYNOPSIS
    HTTP security response headers.
.DESCRIPTION
    Registers a Pode middleware that sets a fixed set of OWASP-aligned response
    headers on every response, and normalises the Server header so the underlying
    stack (Pode / PowerShell version) is never advertised.

    OpsBridge serves JSON only - no HTML, no inline scripts or styles - so the
    Content-Security-Policy can be the strictest useful value (default-src
    'none') rather than the more permissive policy an HTML-serving app would
    need. If a future route ever serves rendered content (e.g. an optional '/'
    status page, see docs/architecture.md), revisit this policy deliberately.

    Adjust deliberately, with the security-related integration tests updated to
    match.
#>

function Add-SecurityHeadersMiddleware {
    Add-PodeMiddleware -Name 'SecurityHeaders' -ScriptBlock {
        try {
            # Get-PodeState, not a closure over $config: this scriptblock runs
            # in a route/middleware runspace, not the one that set it up (the
            # same "$script: doesn't cross runspaces" gotcha as Logging.ps1 -
            # see docs/architecture.md). Advertising HSTS over a plain HTTP
            # endpoint would be actively wrong (it tells the browser to assume
            # HTTPS on a host that isn't serving it), so this must reflect the
            # actual running protocol, not just "did someone remember to add
            # the header".
            if ((Get-PodeState -Name 'AppConfig').Protocol -eq 'Https') {
                Set-PodeHeader -Name 'Strict-Transport-Security' -Value 'max-age=31536000; includeSubDomains'
            }
            Set-PodeHeader -Name 'Content-Security-Policy' -Value "default-src 'none'; frame-ancestors 'none'"
            Set-PodeHeader -Name 'X-Content-Type-Options' -Value 'nosniff'
            # X-XSS-Protection is deprecated; current OWASP guidance is to
            # explicitly disable it (its legacy filter has caused real XSS
            # vulnerabilities in older browsers) and rely on CSP instead.
            Set-PodeHeader -Name 'X-XSS-Protection' -Value '0'
            Set-PodeHeader -Name 'X-Frame-Options' -Value 'DENY'
            Set-PodeHeader -Name 'Referrer-Policy' -Value 'strict-origin-when-cross-origin'
            Set-PodeHeader -Name 'Permissions-Policy' -Value 'camera=(), microphone=(), geolocation=()'
            Set-PodeHeader -Name 'Cross-Origin-Opener-Policy' -Value 'same-origin'
            Set-PodeHeader -Name 'Cross-Origin-Resource-Policy' -Value 'same-origin'
            # API responses should never be cached by intermediaries/browsers.
            Set-PodeHeader -Name 'Cache-Control' -Value 'no-store'
            Set-PodeHeader -Name 'Server' -Value 'OpsBridge'
        }
        catch {
            Write-AppErrorLog -Exception $_.Exception
        }
        return $true
    }
}
