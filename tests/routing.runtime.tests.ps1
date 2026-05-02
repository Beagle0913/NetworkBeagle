#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ((Get-Module Pester).Version.Major -lt 5) { . (Join-Path $PSScriptRoot "pester5-compat.ps1") }

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "fixtures.runtime.ps1")
. (Join-Path $projectRoot "lib\routing.ps1")

Describe "Routing runtime helpers" {
    It "detects unspecified next-hop values by family" {
        (Test-NetworkDiagIsUnspecifiedNextHop -NextHop "0.0.0.0" -Family "IPv4") | Should -BeTrue
        (Test-NetworkDiagIsUnspecifiedNextHop -NextHop "::" -Family "IPv6") | Should -BeTrue
        (Test-NetworkDiagIsUnspecifiedNextHop -NextHop "192.168.1.1" -Family "IPv4") | Should -BeFalse
    }

    It "detects routing identity changes" {
        $a = New-TestRoutingIdentity
        $b = New-TestRoutingIdentity -Gateway "192.168.1.254"
        (Test-NetworkDiagRoutingIdentityChanged -A $a -B $b) | Should -BeTrue
    }

    It "returns false when routing identity is unchanged" {
        $a = New-TestRoutingIdentity
        $b = New-TestRoutingIdentity
        (Test-NetworkDiagRoutingIdentityChanged -A $a -B $b) | Should -BeFalse
    }

    It "formats route refresh incident line with baseline reset tag" {
        $line = Format-NetworkDiagRouteRefreshIncidentLine `
            -Timestamp "2026-05-03 00:00:00.000" `
            -OldSnap @{ gateway = "192.168.1.1"; routeIfIndex = "5"; routedAdapter = "Ethernet"; routingContext = "Normal"; underlayIfIndex = "na" } `
            -NewSnap @{ gateway = "192.168.1.254"; routeIfIndex = "5"; routedAdapter = "Ethernet"; routingContext = "Normal"; underlayIfIndex = "na" } `
            -BaselinesReset $true
        $line | Should -Match "ROUTE_REFRESH"
        $line | Should -Match "baselines_reset=yes"
    }
}
