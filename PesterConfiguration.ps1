<#
.SYNOPSIS
    Shared Pester 6 configuration for OpsBridge.
.DESCRIPTION
    Used by both local development and CI: `Invoke-Pester -Configuration (./PesterConfiguration.ps1)`.
    Runs unit and integration tests together by default; pass -Path to Invoke-Pester's
    caller (or filter with -TagFilter) to run only one of the two.
#>
[CmdletBinding()]
param()

$config = New-PesterConfiguration
$config.Run.Path = @('tests/unit', 'tests/integration')
$config.Run.Exit = $true
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = 'testResults.xml'
$config.TestResult.OutputFormat = 'NUnitXml'

return $config
