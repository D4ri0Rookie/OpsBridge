<#
.SYNOPSIS
    Unit tests for Test-HttpsCertificateReady (src/App.ps1) - the pre-flight
    check that fails startup fast when API_PROTOCOL=Https points at a
    certificate file that does not exist, instead of letting Pode raise an
    opaque error deep inside Start-PodeServer.
#>

BeforeAll {
    . "$PSScriptRoot/../../src/App.ps1"
}

Describe 'Test-HttpsCertificateReady' {
    It 'passes for Http regardless of CertPath' {
        Test-HttpsCertificateReady -Protocol 'Http' -SelfSigned $false -CertPath '' | Should -BeTrue
    }

    It 'passes for Https with SelfSigned, even with no CertPath' {
        Test-HttpsCertificateReady -Protocol 'Https' -SelfSigned $true -CertPath '' | Should -BeTrue
    }

    It 'fails for Https without SelfSigned and an empty CertPath' {
        Test-HttpsCertificateReady -Protocol 'Https' -SelfSigned $false -CertPath '' | Should -BeFalse
    }

    It 'fails for Https without SelfSigned and a CertPath that does not exist' {
        Test-HttpsCertificateReady -Protocol 'Https' -SelfSigned $false -CertPath 'TestDrive:/does-not-exist.pfx' | Should -BeFalse
    }

    It 'passes for Https without SelfSigned and a CertPath that exists' {
        $certPath = Join-Path 'TestDrive:' 'cert.pfx'
        Set-Content -Path $certPath -Value 'not a real certificate, existence is all this check verifies'

        Test-HttpsCertificateReady -Protocol 'Https' -SelfSigned $false -CertPath $certPath | Should -BeTrue
    }
}
