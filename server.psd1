@{
    # Pode-native server settings that are not part of OpsBridge's own API_*
    # configuration surface (see src/config/Config.ps1).
    Server = @{
        Request = @{
            # Basic request hardening, tightened from Pode's defaults (30s / 100MB)
            # for a small internal automation API. A slow client that exceeds the
            # timeout gets 408; a body over the limit gets 413 - both before the
            # request reaches a route. Raise BodySize if a future endpoint needs to
            # accept a larger payload (e.g. a bulk operation).
            Timeout  = 30      # seconds
            BodySize = 1MB     # bytes (PowerShell notation)
        }
    }

    Web = @{
        ErrorPages = @{
            # Makes automatic error pages (404, 500, and anything Pode rejects
            # before a route - 408, 413, ...) default to JSON so the static files
            # under /errors are picked up without per-route wiring.
            Default        = 'application/json'
            ShowExceptions = $false
        }
    }
}
