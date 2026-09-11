<#
.SYNOPSIS
    OpsBridge - lightweight internal REST API runtime for SysOps/DevOps automation, built on Pode.
.DESCRIPTION
    Entry point only. All startup logic lives in src/App.ps1; configuration in
    src/config/Config.ps1 (with API_* environment overrides); routes in
    src/routes/ and src/routes/v1/. Adding an endpoint means adding a file
    under src/routes/ or src/routes/v1/ plus a service under src/services/ -
    this file does not change.
.NOTES
    Version:      see src/config/Config.ps1 (AppVersion)
    Requirements: PowerShell 7.6+, Pode 2.14.1+
#>

#Requires -Version 7.6
#Requires -Modules @{ ModuleName = 'Pode'; ModuleVersion = '2.14.1' }

. "$PSScriptRoot/src/App.ps1"

Start-ApplicationServer -RootPath $PSScriptRoot
