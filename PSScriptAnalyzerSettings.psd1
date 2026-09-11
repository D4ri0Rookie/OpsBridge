@{
    # Run the full default rule set. Only rules that genuinely do not apply to
    # this project are excluded, each with a stated reason - there is no blanket
    # suppression. The project keeps this clean: treat any Error or Warning as a
    # failure.
    IncludeDefaultRules = $true

    Severity            = @('Error', 'Warning')

    ExcludeRules        = @(
        # Start-ApplicationServer / Start-TestServer / Stop-TestServer are
        # process-lifecycle entry points, not cmdlets that mutate external state;
        # -WhatIf/-Confirm semantics do not apply. (install-service.ps1 /
        # uninstall-service.ps1 *do* change state and *do* declare
        # SupportsShouldProcess.)
        'PSUseShouldProcessForStateChangingFunctions'

        # Register-ApplicationRoutes / Register-ApplicationServices register
        # *all* application routes/services; the plural noun is intentional and
        # reads correctly.
        'PSUseSingularNouns'

        # server.ps1 and the helper scripts are invoked by path, not imported as
        # a module, so there is no manifest to export fields from.
        'PSUseToExportFieldsInManifest'

        # Write-Host is used only in the operator-facing console scripts
        # (scripts/*.ps1) and the bootstrap startup/shutdown lines. That output
        # is interactive console UX, not pipeline data - Write-Output/
        # Write-Information would be wrong here. The application's structured
        # logging (src/logging/Logging.ps1) never uses Write-Host.
        'PSAvoidUsingWriteHost'
    )
}
