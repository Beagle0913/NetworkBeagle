#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ((Get-Module Pester).Version.Major -lt 5) { . (Join-Path $PSScriptRoot "pester5-compat.ps1") }

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "fixtures.runtime.ps1")
. (Join-Path $projectRoot "lib\cycle.ps1")

Describe "Cycle runtime verdict logic" {
    It "classifies GW up + external down as ISP_FAULT" {
        $state = New-TestCycleVerdictState
        $probes = New-TestCycleVerdictProbes -GwOk $true -ExtOk $false -ExtUnreachable 2 -TcpExtOk $false
        $ctx = New-TestCycleVerdictContext

        $v = Get-NetworkDiagCycleVerdict -Probes $probes -Ctx $ctx -State $state

        $v.Verdict | Should -Be "ISP_FAULT"
        $v.Color | Should -Be "Red"
    }

    It "classifies GW down + external down as LOCAL_FAULT" {
        $state = New-TestCycleVerdictState
        $probes = New-TestCycleVerdictProbes -GwOk $false -ExtOk $false -ExtUnreachable 3
        $ctx = New-TestCycleVerdictContext

        $v = Get-NetworkDiagCycleVerdict -Probes $probes -Ctx $ctx -State $state

        $v.Verdict | Should -Be "LOCAL_FAULT"
        $v.Color | Should -Be "Magenta"
    }

    It "activates normal gateway ICMP policy after confirmation streak" {
        $state = New-TestCycleVerdictState
        $probes = New-TestCycleVerdictProbes -GwOk $false -ExtOk $true -DoTcp $true -TcpExtOk $true
        $ctx = New-TestCycleVerdictContext -RoutingContext "Normal"
        $ctx.GwIcmpPolicyConfirmCycles = 2

        $first = Get-NetworkDiagCycleVerdict -Probes $probes -Ctx $ctx -State $state
        $second = Get-NetworkDiagCycleVerdict -Probes $probes -Ctx $ctx -State $state

        $first.PolicyActivated | Should -BeFalse
        $second.PolicyActivated | Should -BeTrue
        $second.NormalAdjusted | Should -BeTrue
        $second.Verdict | Should -Be "OK"
    }

    It "deactivates normal policy when candidate pattern breaks" {
        $state = New-TestCycleVerdictState
        $state.NormalGwPolicyState = "Active"
        $state.NormalGwPolicyStreak = 4
        $state.NormalGwPolicyArmedAt = "2026-05-03 00:00:00.000"
        $probes = New-TestCycleVerdictProbes -GwOk $true -ExtOk $true -TcpExtOk $true
        $ctx = New-TestCycleVerdictContext -RoutingContext "Normal"

        $v = Get-NetworkDiagCycleVerdict -Probes $probes -Ctx $ctx -State $state

        $v.PolicyDeactivated | Should -BeTrue
        $state.NormalGwPolicyState | Should -Be "Inactive"
    }

    It "marks VPN tunnel-only anomaly when underlay is unavailable" {
        $state = New-TestCycleVerdictState
        $probes = New-TestCycleVerdictProbes -GwOk $false -ExtOk $true
        $ctx = New-TestCycleVerdictContext -RoutingContext "VpnTunnelDefault"
        $ctx.UnderlayAvailable = $false

        $v = Get-NetworkDiagCycleVerdict -Probes $probes -Ctx $ctx -State $state

        $v.Verdict | Should -Be "ANOMALY"
        $v.VpnPolicyEvidence | Should -Be "VPN_TUNNEL_ONLY"
    }
}
