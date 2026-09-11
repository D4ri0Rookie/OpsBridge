<#
.SYNOPSIS
    Unit tests for Get-AppConfig (src/config/Config.ps1). Pure function - no
    Pode, no running server.
#>

BeforeAll {
    . "$PSScriptRoot/../../../src/config/Config.ps1"
    $script:RootPath = 'TestDrive:/opsbridge'
}

Describe 'Get-AppConfig' {
    BeforeEach {
        # Config reads directly from $env:*, so every test starts from a clean
        # slate regardless of what the previous test (or the host shell) set.
        foreach ($name in @(
                'API_ENVIRONMENT', 'API_HOST', 'API_PORT', 'API_PROTOCOL', 'API_CERT_PATH',
                'API_CERT_SELF_SIGNED', 'API_THREADS', 'API_DAEMON',
                'API_LOG_LEVEL', 'API_LOG_FORMAT', 'API_LOG_DESTINATION', 'API_LOG_PATH',
                'API_LOG_RETENTION_DAYS'
            )) {
            Remove-Item "Env:\$name" -ErrorAction SilentlyContinue
        }
    }

    It 'returns sensible defaults with no environment overrides' {
        $config = Get-AppConfig -RootPath $script:RootPath
        $config.Environment | Should -Be 'Development'
        $config.ListenAddress | Should -Be '0.0.0.0'
        $config.Port | Should -Be 8080
        $config.LogLevel | Should -Be 'Info'
        $config.LogFormat | Should -Be 'json'
        $config.LogDestination | Should -Be 'stdout'
    }

    It 'applies a valid API_ENVIRONMENT override' {
        $env:API_ENVIRONMENT = 'Production'
        (Get-AppConfig -RootPath $script:RootPath).Environment | Should -Be 'Production'
    }

    It 'discards an invalid API_ENVIRONMENT and warns' {
        $env:API_ENVIRONMENT = 'Staging'
        $config = Get-AppConfig -RootPath $script:RootPath -WarningVariable warnings -WarningAction SilentlyContinue
        $config.Environment | Should -Be 'Development'
        $warnings.Count | Should -BeGreaterThan 0
    }

    It 'applies a valid API_PORT override' {
        $env:API_PORT = '9000'
        (Get-AppConfig -RootPath $script:RootPath).Port | Should -Be 9000
    }

    It 'discards an out-of-range API_PORT and keeps the default' {
        $env:API_PORT = '70000'
        $config = Get-AppConfig -RootPath $script:RootPath -WarningAction SilentlyContinue
        $config.Port | Should -Be 8080
    }

    It 'discards a non-numeric API_PORT and keeps the default' {
        $env:API_PORT = 'not-a-number'
        $config = Get-AppConfig -RootPath $script:RootPath -WarningAction SilentlyContinue
        $config.Port | Should -Be 8080
    }

    It 'defaults to plain Http with no certificate configured' {
        $config = Get-AppConfig -RootPath $script:RootPath
        $config.Protocol | Should -Be 'Http'
        $config.CertPath | Should -BeNullOrEmpty
        $config.CertSelfSigned | Should -BeFalse
    }

    It 'applies a valid API_PROTOCOL override' {
        $env:API_PROTOCOL = 'Https'
        (Get-AppConfig -RootPath $script:RootPath).Protocol | Should -Be 'Https'
    }

    It 'discards an invalid API_PROTOCOL and warns' {
        $env:API_PROTOCOL = 'Ftp'
        $config = Get-AppConfig -RootPath $script:RootPath -WarningVariable warnings -WarningAction SilentlyContinue
        $config.Protocol | Should -Be 'Http'
        $warnings.Count | Should -BeGreaterThan 0
    }

    It 'applies API_CERT_PATH verbatim' {
        $env:API_CERT_PATH = '/etc/opsbridge/cert.pfx'
        (Get-AppConfig -RootPath $script:RootPath).CertPath | Should -Be '/etc/opsbridge/cert.pfx'
    }

    It 'accepts API_CERT_SELF_SIGNED truthy/falsy spellings' {
        $env:API_CERT_SELF_SIGNED = 'yes'
        (Get-AppConfig -RootPath $script:RootPath).CertSelfSigned | Should -BeTrue

        $env:API_CERT_SELF_SIGNED = 'off'
        (Get-AppConfig -RootPath $script:RootPath).CertSelfSigned | Should -BeFalse
    }

    It 'accepts API_DAEMON truthy/falsy spellings' {
        $env:API_DAEMON = 'yes'
        (Get-AppConfig -RootPath $script:RootPath).Daemon | Should -BeTrue

        $env:API_DAEMON = 'off'
        (Get-AppConfig -RootPath $script:RootPath).Daemon | Should -BeFalse
    }

    It 'rejects an unsupported API_LOG_FORMAT and keeps the default' {
        $env:API_LOG_FORMAT = 'text'
        $config = Get-AppConfig -RootPath $script:RootPath -WarningAction SilentlyContinue
        $config.LogFormat | Should -Be 'json'
    }

    It 'rejects an unsupported API_LOG_DESTINATION and keeps the default' {
        $env:API_LOG_DESTINATION = 'syslog'
        $config = Get-AppConfig -RootPath $script:RootPath -WarningAction SilentlyContinue
        $config.LogDestination | Should -Be 'stdout'
    }

    It 'never stores a secret-shaped key in the returned config' {
        $config = Get-AppConfig -RootPath $script:RootPath
        $config.Keys | Where-Object { $_ -match 'password|secret|token|key$' } | Should -BeNullOrEmpty
    }
}
