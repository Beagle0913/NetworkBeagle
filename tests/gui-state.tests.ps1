#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ((Get-Module Pester).Version.Major -lt 5) { . (Join-Path $PSScriptRoot "pester5-compat.ps1") }

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot "gui\core\state.ps1")
. (Join-Path $projectRoot "gui\core\validation.ps1")

Describe "GUI state helpers" {
    It "merges overrides into canonical defaults" {
        $merged = Merge-NetworkDiagGuiState -Overrides @{
            DurationMinutes = 15
            ExternalIcmpHosts = @("1.1.1.1", "8.8.8.8")
            EnableUdpProbe = $true
        }

        $merged.DurationMinutes | Should -Be 15
        $merged.IntervalSeconds | Should -Be 3
        @($merged.ExternalIcmpHosts).Count | Should -Be 2
        $merged.EnableUdpProbe | Should -Be $true
    }

    It "returns validation errors for invalid host configuration" {
        $limits = Get-NetworkDiagGuiLimitations
        $state = Merge-NetworkDiagGuiState -Overrides @{
            ExternalIcmpHosts = @("bad host", "8.8.8.8")
            DnsProbeName = ""
        }

        $result = Test-NetworkDiagGuiState -State $state -Limits $limits
        $result.Errors.Count | Should -BeGreaterThan 0
        ($result.Errors -join " | ") | Should -Match "invalid host/IP|not a valid host/IP"
        ($result.Errors -join " | ") | Should -Match "DNS name is required|DnsProbeName"
    }

    It "emits enabled optional probe parameters into cli map" {
        $state = Merge-NetworkDiagGuiState -Overrides @{
            EnableUdpProbe = $true
            UdpProbeTarget = "8.8.8.8:443"
            UdpProbeRateHz = 45
            UdpProbePayloadBytes = 96
            AutoCaptureOnFault = $true
            AutoCaptureMethod = "pktmon"
            AutoCaptureSeconds = 20
            AutoCaptureMax = 2
        }
        $state.OutputFolder = "C:\Temp\out"

        $params = ConvertTo-NetworkDiagGuiParamMap -State $state
        $params.EnableUdpProbe | Should -Be $true
        $params.UdpProbeRateHz | Should -Be 45
        $params.AutoCaptureOnFault | Should -Be $true
        $params.AutoCaptureMethod | Should -Be "pktmon"
    }

    It "validates host:port targets when advanced probes are enabled" {
        $limits = Get-NetworkDiagGuiLimitations
        $state = Merge-NetworkDiagGuiState -Overrides @{
            EnableUdpProbe = $true
            UdpProbeTarget = "bad_target"
            EnableLongLivedTcp = $true
            LongLivedTcpTarget = "stillbad"
        }
        $result = Test-NetworkDiagGuiState -State $state -Limits $limits
        ($result.Errors -join " | ") | Should -Match "UDP target must use host:port|UdpProbeTarget must be in host:port"
        ($result.Errors -join " | ") | Should -Match "Long-lived TCP target must use host:port|LongLivedTcpTarget must be in host:port"
    }

    It "accepts bracketed IPv6 host:port targets" {
        $limits = Get-NetworkDiagGuiLimitations
        $state = Merge-NetworkDiagGuiState -Overrides @{
            EnableUdpProbe = $true
            UdpProbeTarget = "[2606:4700:4700::1111]:443"
            EnableLongLivedTcp = $true
            LongLivedTcpTarget = "[2001:4860:4860::8888]:443"
        }
        $result = Test-NetworkDiagGuiState -State $state -Limits $limits
        ($result.Errors -join " | ") | Should -Not -Match "UdpProbeTarget"
        ($result.Errors -join " | ") | Should -Not -Match "LongLivedTcpTarget"
    }

    It "rejects out-of-range ports for advanced host:port targets" {
        $limits = Get-NetworkDiagGuiLimitations
        $state = Merge-NetworkDiagGuiState -Overrides @{
            EnableUdpProbe = $true
            UdpProbeTarget = "8.8.8.8:70000"
            EnableLongLivedTcp = $true
            LongLivedTcpTarget = "[2606:4700:4700::1111]:0"
        }
        $result = Test-NetworkDiagGuiState -State $state -Limits $limits
        ($result.Errors -join " | ") | Should -Match "UDP target must use host:port"
        ($result.Errors -join " | ") | Should -Match "Long-lived TCP target must use host:port"
    }

    It "exports a runnable cli command string from state" {
        $state = Merge-NetworkDiagGuiState -Overrides @{
            EnableUdpProbe = $true
            UdpProbeTarget = "8.8.8.8:443"
        }
        $state.OutputFolder = "C:\Temp\out"
        $cmd = ConvertTo-NetworkDiagGuiCliCommand -State $state
        $cmd | Should -Match "network-stability-test.ps1"
        $cmd | Should -Match "-EnableUdpProbe"
        $cmd | Should -Match "-UdpProbeTarget"
    }

    It "renders list parameters in CLI export syntax" {
        $state = Merge-NetworkDiagGuiState -Overrides @{
            ExternalIcmpHosts = @("1.1.1.1", "8.8.8.8")
            ExternalIcmpLabels = @("A", "B")
            TcpProbeHosts = @("1.1.1.1", "8.8.8.8")
        }
        $state.OutputFolder = "C:\Temp\out"
        $cmd = ConvertTo-NetworkDiagGuiCliCommand -State $state
        $cmd | Should -Match "-ExternalIcmpHosts @\("
        $cmd | Should -Match "-ExternalIcmpLabels @\("
        $cmd | Should -Match "-TcpProbeHosts @\("
    }
}
