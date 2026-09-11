# Pode's own published image already ships PowerShell + the exact Pode
# version pinned by server.ps1's #Requires line - keep these two in sync, and
# prefer this over a generic PowerShell base image plus `Install-Module Pode`
# at build time (slower builds, a PSGallery dependency at build time, no
# version pin backed by an image digest).
FROM badgerati/pode:2.14.1-alpine

# /usr/src/app is Pode's own documented convention for where a hosted script
# lives inside their image (see hub.docker.com/r/badgerati/pode).
WORKDIR /usr/src/app
COPY . .

# The base image predefines a non-root user via APP_UID (the standard .NET
# container images convention) - reuse it instead of creating a new one.
# Nothing OpsBridge does requires writing outside /usr/src/app (and only then
# if API_LOG_DESTINATION includes file), so no persistent volume is required.
RUN chown -R "$APP_UID:$APP_UID" /usr/src/app
USER $APP_UID

ENV API_HOST=0.0.0.0
ENV API_PORT=8080
ENV API_LOG_DESTINATION=stdout

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["pwsh", "-NoProfile", "-Command", "try { $r = Invoke-WebRequest -Uri http://localhost:8080/health/ready -UseBasicParsing -TimeoutSec 2; if ($r.StatusCode -eq 200) { exit 0 } else { exit 1 } } catch { exit 1 }"]

CMD ["pwsh", "-NoProfile", "-File", "server.ps1"]
