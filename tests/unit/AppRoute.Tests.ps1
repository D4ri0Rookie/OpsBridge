<#
.SYNOPSIS
    Unit tests for New-WrappedRouteScriptBlock (src/App.ps1) - the
    unhandled-exception wrapping every route handler gets via Add-AppRoute.
.DESCRIPTION
    Builds the wrapped scriptblock directly and invokes it, with
    Write-AppErrorLog / Send-ApiError mocked, so the "handler throws -> log it
    -> generic 500, no leak" contract is verified without a running Pode
    server. The full HTTP-level behaviour (500 body shape, headers,
    correlation id) is out of scope here by design - see
    tests/integration/Api.Tests.ps1 for the 404 case, which exercises the same
    Send-ApiError path end-to-end.
#>

BeforeAll {
    . "$PSScriptRoot/../../src/errors/Errors.ps1"
    . "$PSScriptRoot/../../src/logging/Logging.ps1"
    . "$PSScriptRoot/../../src/App.ps1"
}

Describe 'New-WrappedRouteScriptBlock' {
    It 'runs the handler normally and returns its output when it does not throw' {
        $sb = { Write-Output 'ok' }
        $wrapped = New-WrappedRouteScriptBlock -Method @('Get') -Path '/test' -ScriptBlock $sb

        & $wrapped | Should -Be 'ok'
    }

    It 'rejects a handler that declares a param() block' {
        $sb = { param($x) $x }

        { New-WrappedRouteScriptBlock -Method @('Get') -Path '/test' -ScriptBlock $sb } | Should -Throw '*param()*'
    }

    It 'catches an unhandled exception instead of letting it propagate' {
        Mock Write-AppErrorLog {}
        Mock Send-ApiError {}

        $sb = { throw [System.InvalidOperationException]::new('boom') }
        $wrapped = New-WrappedRouteScriptBlock -Method @('Get') -Path '/test' -ScriptBlock $sb

        { & $wrapped } | Should -Not -Throw
    }

    It 'logs the real exception with its original message' {
        Mock Write-AppErrorLog {}
        Mock Send-ApiError {}

        $sb = { throw [System.InvalidOperationException]::new('boom') }
        $wrapped = New-WrappedRouteScriptBlock -Method @('Get') -Path '/test' -ScriptBlock $sb
        & $wrapped

        Should -Invoke Write-AppErrorLog -Times 1 -ParameterFilter {
            $Exception.Message -eq 'boom'
        }
    }

    It 'sends a generic 500 INTERNAL_ERROR - never the real exception message - to the client' {
        Mock Write-AppErrorLog {}
        Mock Send-ApiError {}

        $sb = { throw [System.InvalidOperationException]::new('boom') }
        $wrapped = New-WrappedRouteScriptBlock -Method @('Get') -Path '/test' -ScriptBlock $sb
        & $wrapped

        Should -Invoke Send-ApiError -Times 1 -ParameterFilter {
            $StatusCode -eq 500 -and $Code -eq 'INTERNAL_ERROR' -and $Message -notmatch 'boom'
        }
    }

    It 'still sends the generic 500 even if logging the error itself throws' {
        Mock Write-AppErrorLog { throw 'logging backend unavailable' }
        Mock Send-ApiError {}

        $sb = { throw 'boom' }
        $wrapped = New-WrappedRouteScriptBlock -Method @('Get') -Path '/test' -ScriptBlock $sb

        { & $wrapped } | Should -Not -Throw
        Should -Invoke Send-ApiError -Times 1 -ParameterFilter { $StatusCode -eq 500 }
    }
}

Describe 'New-WrappedRouteScriptBlock - soft request timeout (API_REQUEST_TIMEOUT_SECONDS)' {
    It 'logs application.timeout when the handler runs past the configured budget' {
        # RequestTimeoutSeconds = 0 rather than a real Start-Sleep past a
        # realistic (>=1s) budget - any nonzero elapsed time already exceeds
        # it, so this stays a fast unit test.
        Mock Get-PodeState { @{ RequestTimeoutSeconds = 0 } } -ParameterFilter { $Name -eq 'AppConfig' }
        Mock Write-AppLog {}

        $sb = { Start-Sleep -Milliseconds 5 }
        $wrapped = New-WrappedRouteScriptBlock -Method @('Get') -Path '/test' -ScriptBlock $sb
        & $wrapped

        Should -Invoke Write-AppLog -Times 1 -ParameterFilter {
            $Event -eq 'application.timeout'
        }
    }

    It 'does not log application.timeout when the handler finishes within budget' {
        Mock Get-PodeState { @{ RequestTimeoutSeconds = 30 } } -ParameterFilter { $Name -eq 'AppConfig' }
        Mock Write-AppLog {}

        $sb = { Write-Output 'ok' }
        $wrapped = New-WrappedRouteScriptBlock -Method @('Get') -Path '/test' -ScriptBlock $sb
        & $wrapped | Out-Null

        Should -Invoke Write-AppLog -Times 0 -ParameterFilter {
            $Event -eq 'application.timeout'
        }
    }

    It 'still returns the handler''s own output - a soft timeout never blocks or alters the response' {
        Mock Get-PodeState { @{ RequestTimeoutSeconds = 0 } } -ParameterFilter { $Name -eq 'AppConfig' }
        Mock Write-AppLog {}

        $sb = { Start-Sleep -Milliseconds 5; Write-Output 'still ok' }
        $wrapped = New-WrappedRouteScriptBlock -Method @('Get') -Path '/test' -ScriptBlock $sb

        & $wrapped | Should -Be 'still ok'
    }

    It 'still sends the generic 500 for a handler that both throws and exceeds its timeout budget' {
        Mock Get-PodeState { @{ RequestTimeoutSeconds = 0 } } -ParameterFilter { $Name -eq 'AppConfig' }
        Mock Write-AppLog {}
        Mock Write-AppErrorLog {}
        Mock Send-ApiError {}

        $sb = { Start-Sleep -Milliseconds 5; throw 'boom' }
        $wrapped = New-WrappedRouteScriptBlock -Method @('Get') -Path '/test' -ScriptBlock $sb

        { & $wrapped } | Should -Not -Throw
        Should -Invoke Send-ApiError -Times 1 -ParameterFilter { $StatusCode -eq 500 }
        Should -Invoke Write-AppLog -Times 1 -ParameterFilter { $Event -eq 'application.timeout' }
    }

    It 'never breaks the response even if reading the timeout budget itself fails' {
        Mock Get-PodeState { throw 'state backend unavailable' } -ParameterFilter { $Name -eq 'AppConfig' }
        Mock Write-AppLog {}

        $sb = { Write-Output 'ok' }
        $wrapped = New-WrappedRouteScriptBlock -Method @('Get') -Path '/test' -ScriptBlock $sb

        & $wrapped | Should -Be 'ok'
    }
}
