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
