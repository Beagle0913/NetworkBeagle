#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ((Get-Module Pester).Version.Major -lt 5) { . (Join-Path $PSScriptRoot "pester5-compat.ps1") }

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot "lib\report.ps1")

Describe "Report helpers" {
    It "builds non-legacy manifest with advanced columns" {
        $manifest = Get-NetworkDiagCsvColumnManifest `
            -LegacyCsvShape:$false `
            -ExternalCount 3 `
            -IncludeUdp:$true `
            -IncludeTcpSession:$true `
            -IncludeAutoCapture:$true `
            -IncludePerProbeTimestamps:$true

        ($manifest -join ",") | Should -Match "Ext1_ms"
        ($manifest -join ",") | Should -Match "TLS_CF_ms"
        ($manifest -join ",") | Should -Match "Udp_PktsSent_d"
        ($manifest -join ",") | Should -Match "TcpSess_State"
        ($manifest -join ",") | Should -Match "AutoCap_State"
        ($manifest -join ",") | Should -Match "Ext1_t_ms"
    }

    It "fills missing manifest values with empty fields" {
        $cols = @("Timestamp", "Verdict", "Dns_ms")
        $line = ConvertTo-NetworkDiagCsvLineFromManifest -ColumnNames $cols -Values @{ Timestamp = "2026-05-02"; Verdict = "OK" }
        $line | Should -Be '"2026-05-02","OK",""'
    }

    It "formats DNS section when probe is disabled" {
        $text = Format-NetworkDiagDnsResolutionSection -S @{ DnsFailCycles = 0 } -Den 1 -DnsName "example.com" -DnsCapMs 3000 -SkipDns:$true
        $text | Should -Match "DNS probe was disabled"
    }

    It "includes monitoring metadata in run config section" {
        $s = @{}
        $r = @{
            BurstOnFault = $false
            RoutingContext = "Normal"
            SkipGwIcmpPolicyAdaptation = $false
            DoTcp = $true
            GwIcmpPolicyConfirmCycles = 8
            SkipDnsProbe = $false
            DnsProbeName = "www.google.com"
            DnsTimeoutMs = 3000
            DetailActive = $false
            DetailRequested = $false
            DetailDisabledReason = ""
            TcpHostA = "1.1.1.1"
            TcpHostB = "8.8.8.8"
            TunnelReason = ""
            TunnelDetail = ""
            UnderlayAvailable = $false
            UnderlayReason = "NoUnderlay"
            UnderlayAdapter = ""
            UnderlayGw = ""
            UnderlayMetric = $null
            UnderlayMayBeVirtual = $false
            RoutingRefreshIntervalCycles = 0
            MonitoringMode = "LongRun"
            HeartbeatMinutes = 15
            SnapshotMinutes = 60
            EventLogLookbackMinutes = 15
            OutputFolder = "C:\Temp\out"
            OutputResolutionLabel = "user"
            SchemaVersion = "2026-04"
            ProbeAddressFamily = "IPv4"
            Gateway = "192.168.1.1"
            AdapterSummary = "Ethernet ifIndex=5"
            BaselineEthMbps = 1000
            DurationMinutes = 60
            IntervalSeconds = 3
            IcmpCountPerTarget = 2
            IcmpTimeoutSeconds = 2
            EpisodeRecoveryConfirmCycles = 3
            ExternalTargets = @(@{ Host = "1.1.1.1" })
            LegacyCsvShape = $false
            PrimaryAdapter = "Ethernet"
            SkipConfigAudit = $false
            SkipCableHints = $false
            SkipMultiNicCrossCheck = $false
            MultiNicRosterCount = 1
            IsAdmin = $true
            EnableUdpProbe = $false
            UdpProbeTarget = ""
            UdpProbeRateHz = 0
            UdpProbePayloadBytes = 0
            EnableLongLivedTcp = $false
            TcpSessionTarget = ""
            EnableAutoCapture = $false
            AutoCaptureMethod = "pktmon"
            AutoCaptureSeconds = 30
            AutoCaptureMax = 1
            PerProbeTimestamps = $false
            SkipIspEvidencePacket = $true
            IspEvidenceBundlePath = ""
            IspEvidenceZip = $false
        }
        $section = Build-NetworkDiagRunConfigSection -S $s -R $r
        $section | Should -Match "Monitoring mode:\s+LongRun"
        $section | Should -Match "Heartbeat cadence:\s+every 15 min"
        $section | Should -Match "Partial snapshots:\s+every 60 min"
    }

    It "describes TLS trust-store validation in TLS section" {
        $s = @{
            CyclesCommitted = 10
            TlsProbeCycles = 10
            TlsHandshakeFailCycles = 1
            TcpUpTlsDownCycles = 1
        }
        $r = @{
            EnableTlsProbe = $true
        }
        $section = Build-NetworkDiagTlsProbeSection -S $s -R $r
        $section | Should -Match "OS trust store"
    }
}
