<#
.SYNOPSIS
    Unit tests for Get-AppConfig (src/config/Config.ps1). Pure function - no
    Pode, no running server.
#>

BeforeAll {
    . "$PSScriptRoot/../../../src/config/Config.ps1"
    $script:RootPath = 'TestDrive:/opsbridge'
    $script:AllConfigEnvVars = @(
        'API_ENVIRONMENT', 'API_HOST', 'API_PORT', 'API_PROTOCOL', 'API_CERT_PATH',
        'API_CERT_SELF_SIGNED', 'API_THREADS', 'API_DAEMON',
        'API_LOG_LEVEL', 'API_LOG_FORMAT', 'API_LOG_DESTINATION', 'API_LOG_PATH',
        'API_LOG_RETENTION_DAYS',
        'API_MAX_BODY_BYTES', 'API_MAX_IN_FLIGHT_REQUESTS', 'API_REQUEST_TIMEOUT_SECONDS',
        'API_SHUTDOWN_TIMEOUT_SECONDS', 'API_RATE_LIMIT_ENABLED', 'API_RATE_LIMIT_REQUESTS',
        'API_RATE_LIMIT_WINDOW_SECONDS', 'API_AUTH_ENABLED', 'API_AUTH_KEYS'
    )
}

AfterAll {
    # Without this, whichever invalid override the last test in this file set
    # (e.g. a fail-fast test's deliberately-bad value) stays in *this* process's
    # environment after the file finishes. tests/integration spawns real server
    # processes with Start-Process, which inherits the parent environment by
    # default - a leaked invalid setting would then make every subsequent
    # integration test server fail to start (fail-fast), not just this file's
    # own tests. BeforeEach alone only protects the *next test in this file*.
    foreach ($name in $script:AllConfigEnvVars) {
        Remove-Item "Env:\$name" -ErrorAction SilentlyContinue
    }
}

Describe 'Get-AppConfig' {
    BeforeEach {
        # Config reads directly from $env:*, so every test starts from a clean
        # slate regardless of what the previous test (or the host shell) set.
        foreach ($name in $script:AllConfigEnvVars) {
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

    It 'applies a valid API_LOG_LEVEL override' {
        $env:API_LOG_LEVEL = 'Debug'
        (Get-AppConfig -RootPath $script:RootPath).LogLevel | Should -Be 'Debug'
    }

    It 'rejects an unsupported API_LOG_LEVEL and keeps the default' {
        $env:API_LOG_LEVEL = 'Trace'
        $config = Get-AppConfig -RootPath $script:RootPath -WarningVariable warnings -WarningAction SilentlyContinue
        $config.LogLevel | Should -Be 'Info'
        $warnings.Count | Should -BeGreaterThan 0
    }

    It 'applies a valid API_THREADS override' {
        $env:API_THREADS = '8'
        (Get-AppConfig -RootPath $script:RootPath).Threads | Should -Be 8
    }

    It 'rejects a non-numeric API_THREADS and keeps the default' {
        $env:API_THREADS = 'many'
        $config = Get-AppConfig -RootPath $script:RootPath -WarningAction SilentlyContinue
        $config.Threads | Should -Be 3
    }

    It 'rejects a zero/negative API_THREADS and keeps the default' {
        $env:API_THREADS = '0'
        $config = Get-AppConfig -RootPath $script:RootPath -WarningAction SilentlyContinue
        $config.Threads | Should -Be 3
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

Describe 'Get-AppConfig - hardening settings (fail-fast validation)' {
    BeforeEach {
        foreach ($name in @(
                'API_ENVIRONMENT', 'API_HOST', 'API_PORT', 'API_PROTOCOL', 'API_CERT_PATH',
                'API_CERT_SELF_SIGNED', 'API_THREADS', 'API_DAEMON',
                'API_LOG_LEVEL', 'API_LOG_FORMAT', 'API_LOG_DESTINATION', 'API_LOG_PATH',
                'API_LOG_RETENTION_DAYS',
                'API_MAX_BODY_BYTES', 'API_MAX_IN_FLIGHT_REQUESTS', 'API_REQUEST_TIMEOUT_SECONDS',
                'API_SHUTDOWN_TIMEOUT_SECONDS', 'API_RATE_LIMIT_ENABLED', 'API_RATE_LIMIT_REQUESTS',
                'API_RATE_LIMIT_WINDOW_SECONDS', 'API_AUTH_ENABLED', 'API_AUTH_KEYS'
            )) {
            Remove-Item "Env:\$name" -ErrorAction SilentlyContinue
        }
    }

    It 'defaults every hardening setting when nothing is overridden' {
        $config = Get-AppConfig -RootPath $script:RootPath
        $config.MaxBodyBytes | Should -Be 1MB
        $config.MaxInFlightRequests | Should -Be 100
        $config.RequestTimeoutSeconds | Should -Be 30
        $config.ShutdownTimeoutSeconds | Should -Be 30
        $config.RateLimitEnabled | Should -BeFalse
        $config.RateLimitRequests | Should -Be 300
        $config.RateLimitWindowSeconds | Should -Be 60
        $config.AuthEnabled | Should -BeFalse
    }

    It 'applies a valid API_MAX_BODY_BYTES override' {
        $env:API_MAX_BODY_BYTES = '2097152'
        (Get-AppConfig -RootPath $script:RootPath).MaxBodyBytes | Should -Be 2097152
    }

    It 'accepts API_MAX_BODY_BYTES at the boundary value of 1' {
        $env:API_MAX_BODY_BYTES = '1'
        (Get-AppConfig -RootPath $script:RootPath).MaxBodyBytes | Should -Be 1
    }

    It 'throws (fail-fast) on a zero API_MAX_BODY_BYTES' {
        $env:API_MAX_BODY_BYTES = '0'
        { Get-AppConfig -RootPath $script:RootPath } | Should -Throw '*API_MAX_BODY_BYTES*'
    }

    It 'throws (fail-fast) on a negative API_MAX_BODY_BYTES' {
        $env:API_MAX_BODY_BYTES = '-1'
        { Get-AppConfig -RootPath $script:RootPath } | Should -Throw '*API_MAX_BODY_BYTES*'
    }

    It 'throws (fail-fast) on a non-numeric API_MAX_BODY_BYTES' {
        $env:API_MAX_BODY_BYTES = 'not-a-number'
        { Get-AppConfig -RootPath $script:RootPath } | Should -Throw '*API_MAX_BODY_BYTES*'
    }

    It 'applies a valid API_MAX_IN_FLIGHT_REQUESTS override' {
        $env:API_MAX_IN_FLIGHT_REQUESTS = '250'
        (Get-AppConfig -RootPath $script:RootPath).MaxInFlightRequests | Should -Be 250
    }

    It 'accepts API_MAX_IN_FLIGHT_REQUESTS at the boundary value of 1' {
        $env:API_MAX_IN_FLIGHT_REQUESTS = '1'
        (Get-AppConfig -RootPath $script:RootPath).MaxInFlightRequests | Should -Be 1
    }

    It 'throws (fail-fast) on a zero API_MAX_IN_FLIGHT_REQUESTS' {
        $env:API_MAX_IN_FLIGHT_REQUESTS = '0'
        { Get-AppConfig -RootPath $script:RootPath } | Should -Throw '*API_MAX_IN_FLIGHT_REQUESTS*'
    }

    It 'throws (fail-fast) on a non-numeric API_MAX_IN_FLIGHT_REQUESTS' {
        $env:API_MAX_IN_FLIGHT_REQUESTS = 'many'
        { Get-AppConfig -RootPath $script:RootPath } | Should -Throw '*API_MAX_IN_FLIGHT_REQUESTS*'
    }

    It 'applies a valid API_REQUEST_TIMEOUT_SECONDS override' {
        $env:API_REQUEST_TIMEOUT_SECONDS = '15'
        (Get-AppConfig -RootPath $script:RootPath).RequestTimeoutSeconds | Should -Be 15
    }

    It 'throws (fail-fast) on a zero or negative API_REQUEST_TIMEOUT_SECONDS' {
        $env:API_REQUEST_TIMEOUT_SECONDS = '-5'
        { Get-AppConfig -RootPath $script:RootPath } | Should -Throw '*API_REQUEST_TIMEOUT_SECONDS*'
    }

    It 'applies a valid API_SHUTDOWN_TIMEOUT_SECONDS override' {
        $env:API_SHUTDOWN_TIMEOUT_SECONDS = '45'
        (Get-AppConfig -RootPath $script:RootPath).ShutdownTimeoutSeconds | Should -Be 45
    }

    It 'throws (fail-fast) on an invalid API_SHUTDOWN_TIMEOUT_SECONDS' {
        $env:API_SHUTDOWN_TIMEOUT_SECONDS = '0'
        { Get-AppConfig -RootPath $script:RootPath } | Should -Throw '*API_SHUTDOWN_TIMEOUT_SECONDS*'
    }

    It 'accepts API_RATE_LIMIT_ENABLED truthy/falsy spellings' {
        $env:API_RATE_LIMIT_ENABLED = 'true'
        (Get-AppConfig -RootPath $script:RootPath).RateLimitEnabled | Should -BeTrue

        $env:API_RATE_LIMIT_ENABLED = 'off'
        (Get-AppConfig -RootPath $script:RootPath).RateLimitEnabled | Should -BeFalse
    }

    It 'throws (fail-fast) on a non-boolean API_RATE_LIMIT_ENABLED' {
        $env:API_RATE_LIMIT_ENABLED = 'maybe'
        { Get-AppConfig -RootPath $script:RootPath } | Should -Throw '*API_RATE_LIMIT_ENABLED*'
    }

    It 'applies a valid API_RATE_LIMIT_REQUESTS / API_RATE_LIMIT_WINDOW_SECONDS override' {
        $env:API_RATE_LIMIT_REQUESTS = '10'
        $env:API_RATE_LIMIT_WINDOW_SECONDS = '5'
        $config = Get-AppConfig -RootPath $script:RootPath
        $config.RateLimitRequests | Should -Be 10
        $config.RateLimitWindowSeconds | Should -Be 5
    }

    It 'throws (fail-fast) on an invalid API_RATE_LIMIT_REQUESTS even when rate limiting is disabled' {
        $env:API_RATE_LIMIT_ENABLED = 'false'
        $env:API_RATE_LIMIT_REQUESTS = '0'
        { Get-AppConfig -RootPath $script:RootPath } | Should -Throw '*API_RATE_LIMIT_REQUESTS*'
    }

    It 'throws (fail-fast) on an invalid API_RATE_LIMIT_WINDOW_SECONDS' {
        $env:API_RATE_LIMIT_WINDOW_SECONDS = 'never'
        { Get-AppConfig -RootPath $script:RootPath } | Should -Throw '*API_RATE_LIMIT_WINDOW_SECONDS*'
    }

    It 'accepts API_AUTH_ENABLED truthy/falsy spellings' {
        $env:API_AUTH_ENABLED = 'true'
        $env:API_AUTH_KEYS = 'some-key'
        (Get-AppConfig -RootPath $script:RootPath).AuthEnabled | Should -BeTrue

        $env:API_AUTH_ENABLED = 'off'
        (Get-AppConfig -RootPath $script:RootPath).AuthEnabled | Should -BeFalse
    }

    It 'throws (fail-fast) on a non-boolean API_AUTH_ENABLED' {
        $env:API_AUTH_ENABLED = 'maybe'
        { Get-AppConfig -RootPath $script:RootPath } | Should -Throw '*API_AUTH_ENABLED*'
    }

    It 'throws (fail-fast) when API_AUTH_ENABLED is true but API_AUTH_KEYS is not set' {
        $env:API_AUTH_ENABLED = 'true'
        { Get-AppConfig -RootPath $script:RootPath } | Should -Throw '*API_AUTH_KEYS*'
    }

    It 'throws (fail-fast) when API_AUTH_ENABLED is true but API_AUTH_KEYS is blank' {
        $env:API_AUTH_ENABLED = 'true'
        $env:API_AUTH_KEYS = '   '
        { Get-AppConfig -RootPath $script:RootPath } | Should -Throw '*API_AUTH_KEYS*'
    }

    It 'does not require API_AUTH_KEYS when auth is disabled' {
        $env:API_AUTH_ENABLED = 'false'
        { Get-AppConfig -RootPath $script:RootPath } | Should -Not -Throw
    }
}
