#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ((Get-Module Pester).Version.Major -lt 5) { . (Join-Path $PSScriptRoot "pester5-compat.ps1") }

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot "lib\host-port.ps1")
. (Join-Path $projectRoot "gui\core\validation.ps1")

Describe "Shared host/port validation parity" {
    It "accepts valid IPv4 host:port in both shared and GUI validators" {
        (Test-NetworkDiagHostPortTokenShared -Value "8.8.8.8:443") | Should -BeTrue
        (Test-NetworkDiagGuiHostPortToken -Value "8.8.8.8:443") | Should -BeTrue
    }

    It "accepts valid bracketed IPv6 host:port in both validators" {
        (Test-NetworkDiagHostPortTokenShared -Value "[2606:4700:4700::1111]:443") | Should -BeTrue
        (Test-NetworkDiagGuiHostPortToken -Value "[2606:4700:4700::1111]:443") | Should -BeTrue
    }

    It "rejects out-of-range ports in both validators" {
        (Test-NetworkDiagHostPortTokenShared -Value "8.8.8.8:70000") | Should -BeFalse
        (Test-NetworkDiagGuiHostPortToken -Value "8.8.8.8:70000") | Should -BeFalse
    }

    It "parses host and port from shared parser" {
        $parsed = Split-NetworkDiagHostPortShared -Raw "1.1.1.1:443"
        $parsed.Host | Should -Be "1.1.1.1"
        $parsed.Port | Should -Be 443
    }

    It "throws on malformed bracketed IPv6 in shared parser" {
        { Split-NetworkDiagHostPortShared -Raw "[2606:4700:4700::1111:443" } | Should -Throw
    }
}
