function Get-NetworkDiagGuiLayoutPath {
    return Join-Path $PSScriptRoot "..\ui\layout.xaml"
}

function Get-NetworkDiagGuiLayoutXml {
    $path = Get-NetworkDiagGuiLayoutPath
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8
}

function Get-NetworkDiagGuiControlNames {
    return @(
        "AdminBanner","DurationMinutes","IntervalSeconds","MonitoringMode","HeartbeatMinutes","SnapshotMinutes","EventLogLookbackMinutes",
        "ProbeAddressFamily","OutputRoot","BrowseOutputRoot","ExternalIcmpHosts","ExternalIcmpLabels","TcpProbeHosts","DnsProbeName",
        "IcmpCountPerTarget","IcmpTimeoutSeconds","DnsTimeoutMs","BurstOnFault","BurstIntervalSeconds","BurstCycles","MaxBurstSeconds",
        "GwIcmpPolicyConfirmCycles","RoutingRefreshIntervalCycles","RequireEthernet","SkipTcpProbe","DetailLog","LegacyCsvShape",
        "SkipDnsProbe","SkipGwIcmpPolicyAdaptation","PinExternalIcmpToResolvedIp","SkipConfigAudit","SkipCableHints","SkipMultiNicCrossCheck",
        "SkipIspEvidencePacket","IspEvidenceZip","PathMtuProbeTarget","SkipWifiSignal","EnableTlsProbe","SkipJsonSummary","SelfTest",
        "EnableUdpProbe","UdpProbeTarget","UdpProbeRateHz","UdpProbePayloadBytes",
        "EnableLongLivedTcp","LongLivedTcpTarget","LongLivedTcpReconnectBackoffSeconds",
        "PerProbeTimestamps","AutoCaptureOnFault","AutoCaptureMethod","AutoCaptureSeconds","AutoCaptureMax",
        "PresetSelector","ApplyPreset","SaveProfile","LoadProfile","RecentRunsList","ReRunSelected","OpenSelectedRun","OpenSelectedLogs",
        "RunNormal","RunAdmin","StopRun","OpenCurrentRun","OpenCurrentLogs","StatusText","ValidationText",
        "HealthRunVerdict","HealthDns","HealthGateway","HealthExternal","HealthTcp","HealthCycles","HealthLastUpdate","HealthSeverity","HealthTrend",
        "QuickAnalysis","IncidentReasonText","EpisodeTimelineList","LiveLog"
    )
}
