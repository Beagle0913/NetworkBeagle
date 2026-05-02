#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ((Get-Module Pester).Version.Major -lt 5) { . (Join-Path $PSScriptRoot "pester5-compat.ps1") }

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot "lib\common.ps1")
. (Join-Path $projectRoot "lib\probes.ps1")

Describe "Probe runtime helpers" {
    It "normalizes bracketed IPv6 literal endpoint" {
        $out = Normalize-NetworkDiagProbeEndpoint -Raw "[2606:4700:4700::1111]" -ProbeAddressFamily "IPv6" -InterfaceIndex -1
        $out | Should -Be "2606:4700:4700::1111"
    }

    It "rejects IPv6 literal in IPv4 mode" {
        { Normalize-NetworkDiagProbeEndpoint -Raw "2606:4700:4700::1111" -ProbeAddressFamily "IPv4" -InterfaceIndex -1 } | Should -Throw
    }

    It "passes unresolved hostname when explicitly allowed" {
        $out = Normalize-NetworkDiagProbeEndpoint -Raw "example.invalid" -ProbeAddressFamily "IPv4" -AllowHostnameOrUnresolved
        $out | Should -Be "example.invalid"
    }

    It "returns literal IPv4 immediately in resolver helper" {
        $out = Resolve-NetworkDiagHostnameForProbeFamilyWithTimeout -Name "8.8.8.8" -TimeoutMs 1000 -ProbeAddressFamily "IPv4"
        $out | Should -Be "8.8.8.8"
    }

    It "returns empty for wrong-family literal in resolver helper" {
        $out = Resolve-NetworkDiagHostnameForProbeFamilyWithTimeout -Name "8.8.8.8" -TimeoutMs 1000 -ProbeAddressFamily "IPv6"
        $out | Should -Be ""
    }

    It "identifies literal probe IP candidates by family" {
        (Test-NetworkDiagIsLiteralProbeIp -Candidate "1.1.1.1" -ProbeAddressFamily "IPv4") | Should -BeTrue
        (Test-NetworkDiagIsLiteralProbeIp -Candidate "1.1.1.1" -ProbeAddressFamily "IPv6") | Should -BeFalse
    }
}
