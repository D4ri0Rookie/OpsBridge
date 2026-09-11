<#
.SYNOPSIS
    Runs PSScriptAnalyzer with the project's rule set plus InjectionHunter's
    injection-focused rules.
.DESCRIPTION
    A thin wrapper, not a replacement for PSScriptAnalyzerSettings.psd1 - that
    file still owns severity and exclusions. This script only resolves
    InjectionHunter's install location, which cannot be hardcoded into that
    static .psd1 (it differs per machine/OS), and adds it via -CustomRulePath.

    InjectionHunter (Microsoft) adds rules default PSScriptAnalyzer does not
    have - e.g. flagging [scriptblock]::Create / Add-Type / ForEach-Object
    -Parallel $using: patterns that can turn untrusted input into arbitrary
    code execution. Relevant for a REST API where request data eventually
    reaches PowerShell code paths.
.EXAMPLE
    .\scripts\analyze.ps1
#>

$injectionHunter = Get-Module -ListAvailable -Name InjectionHunter |
    Sort-Object Version -Descending | Select-Object -First 1

if (-not $injectionHunter) {
    Write-Host 'ERROR: InjectionHunter module not found. Install it with:'
    Write-Host '  Install-Module -Name InjectionHunter -Scope CurrentUser'
    exit 1
}

$rootPath = Split-Path $PSScriptRoot -Parent
$rulePath = Join-Path $injectionHunter.ModuleBase 'InjectionHunter.psm1'

Invoke-ScriptAnalyzer -Path $rootPath -Recurse `
    -Settings (Join-Path $rootPath 'PSScriptAnalyzerSettings.psd1') `
    -CustomRulePath $rulePath
