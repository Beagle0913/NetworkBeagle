function Test-NetworkDiagGuiIsAdmin {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-NetworkDiagGuiLimitations {
    return @{
        Ranges = @{
            DurationMinutes = @{ Min = 1; Max = [int]::MaxValue }
            IntervalSeconds = @{ Min = 1; Max = 3600 }
            HeartbeatMinutes = @{ Min = -1; Max = 1440 }
            SnapshotMinutes = @{ Min = -1; Max = 1440 }
            EventLogLookbackMinutes = @{ Min = -1; Max = 1440 }
            IcmpCountPerTarget = @{ Min = 1; Max = 6 }
            IcmpTimeoutSeconds = @{ Min = 1; Max = 60 }
            DnsTimeoutMs = @{ Min = 500; Max = 60000 }
            BurstIntervalSeconds = @{ Min = 1; Max = 3599 }
            BurstCycles = @{ Min = 1; Max = [int]::MaxValue }
            MaxBurstSeconds = @{ Min = 1; Max = [int]::MaxValue }
            GwIcmpPolicyConfirmCycles = @{ Min = 2; Max = 999 }
            RoutingRefreshIntervalCycles = @{ Min = 0; Max = 100000 }
            UdpProbeRateHz = @{ Min = 1; Max = 1000 }
            UdpProbePayloadBytes = @{ Min = 1; Max = 1400 }
            LongLivedTcpReconnectBackoffSeconds = @{ Min = 1; Max = 600 }
            AutoCaptureSeconds = @{ Min = 5; Max = 600 }
            AutoCaptureMax = @{ Min = 1; Max = 100 }
        }
        AllowedSets = @{
            MonitoringMode = @("Auto", "ShortRun", "LongRun")
            ProbeAddressFamily = @("IPv4", "IPv6")
            AutoCaptureMethod = @("pktmon", "netshtrace")
        }
        AdminCaveats = @(
            "Multi-NIC external probes are strict only when elevated.",
            "Non-admin runs still work but some evidence capture is less complete."
        )
        RuntimeRules = @(
            "ExternalIcmpHosts count must be 2..6.",
            "ExternalIcmpLabels count must be 0 or match ExternalIcmpHosts count.",
            "TcpProbeHosts count must be 0 or exactly 2.",
            "BurstIntervalSeconds must be less than IntervalSeconds when BurstOnFault is enabled.",
            "When MonitoringMode=Auto, duration >=120 min resolves to LongRun defaults; otherwise ShortRun defaults."
        )
        OutputFallback = @(
            "Script output root fallback order: script folder, Desktop\NetworkTest, TEMP\NetworkTest.",
            "Launcher always creates a dedicated run logs folder before process start."
        )
    }
}

function ConvertTo-NetworkDiagGuiList {
    param([string]$Raw)
    if (-not $Raw) { return @() }
    $parts = @(
        $Raw -split "(`r`n|`n|,|;)"
    ) | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    return @($parts)
}

function ConvertTo-NetworkDiagGuiInt {
    param(
        [string]$Name,
        [string]$Value,
        [hashtable]$Ranges
    )
    $iv = 0
    if (-not [int]::TryParse($Value, [ref]$iv)) {
        throw "$Name must be an integer."
    }
    $spec = $Ranges[$Name]
    if ($null -ne $spec) {
        if ($iv -lt [int]$spec.Min -or $iv -gt [int]$spec.Max) {
            throw "$Name must be between $($spec.Min) and $($spec.Max)."
        }
    }
    return $iv
}

function New-NetworkDiagGuiDefaultState {
    return @{
        DurationMinutes = 60
        IntervalSeconds = 3
        MonitoringMode = "Auto"
        HeartbeatMinutes = -1
        SnapshotMinutes = -1
        EventLogLookbackMinutes = -1
        OutputRoot = $PSScriptRoot
        RequireEthernet = $false
        SkipTcpProbe = $false
        DetailLog = $true
        LegacyCsvShape = $false
        ExternalIcmpHosts = @("1.1.1.1", "8.8.8.8", "9.9.9.9")
        ExternalIcmpLabels = @()
        TcpProbeHosts = @()
        DnsProbeName = "www.google.com"
        SkipDnsProbe = $false
        IcmpCountPerTarget = 2
        IcmpTimeoutSeconds = 2
        DnsTimeoutMs = 3000
        BurstOnFault = $false
        BurstIntervalSeconds = 1
        BurstCycles = 5
        MaxBurstSeconds = 60
        GwIcmpPolicyConfirmCycles = 8
        SkipGwIcmpPolicyAdaptation = $false
        RoutingRefreshIntervalCycles = 60
        PinExternalIcmpToResolvedIp = $false
        ProbeAddressFamily = "IPv4"
        SkipConfigAudit = $false
        SkipCableHints = $false
        SkipMultiNicCrossCheck = $false
        SkipIspEvidencePacket = $false
        IspEvidenceZip = $true
        PathMtuProbeTarget = "1.1.1.1"
        SkipWifiSignal = $false
        EnableTlsProbe = $true
        SkipJsonSummary = $false
        SelfTest = $false
        EnableUdpProbe = $false
        UdpProbeTarget = "8.8.8.8:443"
        UdpProbeRateHz = 30
        UdpProbePayloadBytes = 64
        EnableLongLivedTcp = $false
        LongLivedTcpTarget = "1.1.1.1:443"
        LongLivedTcpReconnectBackoffSeconds = 5
        PerProbeTimestamps = $false
        AutoCaptureOnFault = $false
        AutoCaptureMethod = "pktmon"
        AutoCaptureSeconds = 30
        AutoCaptureMax = 1
    }
}

function Get-NetworkDiagGuiStateSchema {
    return @{
        ScalarKeys = @(
            "DurationMinutes","IntervalSeconds","MonitoringMode","HeartbeatMinutes","SnapshotMinutes","EventLogLookbackMinutes",
            "OutputRoot","DnsProbeName","IcmpCountPerTarget","IcmpTimeoutSeconds","DnsTimeoutMs","BurstIntervalSeconds",
            "BurstCycles","MaxBurstSeconds","GwIcmpPolicyConfirmCycles","RoutingRefreshIntervalCycles","ProbeAddressFamily",
            "PathMtuProbeTarget","UdpProbeTarget","UdpProbeRateHz","UdpProbePayloadBytes","LongLivedTcpTarget",
            "LongLivedTcpReconnectBackoffSeconds","AutoCaptureMethod","AutoCaptureSeconds","AutoCaptureMax"
        )
        SwitchKeys = @(
            "RequireEthernet","SkipTcpProbe","DetailLog","LegacyCsvShape","SkipDnsProbe","BurstOnFault",
            "SkipGwIcmpPolicyAdaptation","PinExternalIcmpToResolvedIp","SkipConfigAudit","SkipCableHints",
            "SkipMultiNicCrossCheck","SkipIspEvidencePacket","IspEvidenceZip","SkipWifiSignal","EnableTlsProbe",
            "SkipJsonSummary","SelfTest","EnableUdpProbe","EnableLongLivedTcp","PerProbeTimestamps","AutoCaptureOnFault"
        )
        ListKeys = @("ExternalIcmpHosts","ExternalIcmpLabels","TcpProbeHosts")
    }
}

function Merge-NetworkDiagGuiState {
    param([hashtable]$Overrides)

    $state = New-NetworkDiagGuiDefaultState
    if ($null -eq $Overrides) { return $state }

    $schema = Get-NetworkDiagGuiStateSchema
    foreach ($key in @($schema.ScalarKeys + $schema.SwitchKeys + $schema.ListKeys)) {
        if (-not $Overrides.ContainsKey($key)) { continue }
        $value = $Overrides[$key]
        if ($schema.ListKeys -contains $key) {
            $state[$key] = @($value)
        } else {
            $state[$key] = $value
        }
    }

    return $state
}

function ConvertTo-NetworkDiagGuiParamMap {
    param([hashtable]$State)
    $params = [ordered]@{
        DurationMinutes = [int]$State.DurationMinutes
        IntervalSeconds = [int]$State.IntervalSeconds
        MonitoringMode = [string]$State.MonitoringMode
        HeartbeatMinutes = [int]$State.HeartbeatMinutes
        SnapshotMinutes = [int]$State.SnapshotMinutes
        EventLogLookbackMinutes = [int]$State.EventLogLookbackMinutes
        OutputFolder = [string]$State.OutputFolder
        ExternalIcmpHosts = @($State.ExternalIcmpHosts)
        DnsProbeName = [string]$State.DnsProbeName
        IcmpCountPerTarget = [int]$State.IcmpCountPerTarget
        IcmpTimeoutSeconds = [int]$State.IcmpTimeoutSeconds
        DnsTimeoutMs = [int]$State.DnsTimeoutMs
        BurstIntervalSeconds = [int]$State.BurstIntervalSeconds
        BurstCycles = [int]$State.BurstCycles
        MaxBurstSeconds = [int]$State.MaxBurstSeconds
        GwIcmpPolicyConfirmCycles = [int]$State.GwIcmpPolicyConfirmCycles
        RoutingRefreshIntervalCycles = [int]$State.RoutingRefreshIntervalCycles
        ProbeAddressFamily = [string]$State.ProbeAddressFamily
        PathMtuProbeTarget = [string]$State.PathMtuProbeTarget
    }

    if (@($State.ExternalIcmpLabels).Count -gt 0) { $params.ExternalIcmpLabels = @($State.ExternalIcmpLabels) }
    if (@($State.TcpProbeHosts).Count -gt 0) { $params.TcpProbeHosts = @($State.TcpProbeHosts) }

    if ($State.ContainsKey("EnableUdpProbe") -and [bool]$State.EnableUdpProbe) {
        $params.EnableUdpProbe = $true
        if ($State.UdpProbeTarget) { $params.UdpProbeTarget = [string]$State.UdpProbeTarget }
        $params.UdpProbeRateHz = [int]$State.UdpProbeRateHz
        $params.UdpProbePayloadBytes = [int]$State.UdpProbePayloadBytes
    }
    if ($State.ContainsKey("EnableLongLivedTcp") -and [bool]$State.EnableLongLivedTcp) {
        $params.EnableLongLivedTcp = $true
        if ($State.LongLivedTcpTarget) { $params.LongLivedTcpTarget = [string]$State.LongLivedTcpTarget }
        $params.LongLivedTcpReconnectBackoffSeconds = [int]$State.LongLivedTcpReconnectBackoffSeconds
    }
    if ($State.ContainsKey("AutoCaptureOnFault") -and [bool]$State.AutoCaptureOnFault) {
        $params.AutoCaptureOnFault = $true
        if ($State.AutoCaptureMethod) { $params.AutoCaptureMethod = [string]$State.AutoCaptureMethod }
        $params.AutoCaptureSeconds = [int]$State.AutoCaptureSeconds
        $params.AutoCaptureMax = [int]$State.AutoCaptureMax
    }

    foreach ($switchName in @(
        "RequireEthernet", "SkipTcpProbe", "DetailLog", "LegacyCsvShape", "SkipDnsProbe",
        "BurstOnFault", "SkipGwIcmpPolicyAdaptation", "PinExternalIcmpToResolvedIp",
        "SkipConfigAudit", "SkipCableHints", "SkipMultiNicCrossCheck", "SkipIspEvidencePacket",
        "IspEvidenceZip", "SkipWifiSignal", "EnableTlsProbe", "SkipJsonSummary", "SelfTest",
        "PerProbeTimestamps"
    )) {
        if ([bool]$State[$switchName]) { $params[$switchName] = $true }
    }
    return $params
}

function Get-NetworkDiagGuiStateFromControls {
    param(
        [hashtable]$Controls,
        [hashtable]$Limits
    )
    $state = @{}
    $state.DurationMinutes = ConvertTo-NetworkDiagGuiInt -Name "DurationMinutes" -Value $Controls.DurationMinutes.Text -Ranges $Limits.Ranges
    $state.IntervalSeconds = ConvertTo-NetworkDiagGuiInt -Name "IntervalSeconds" -Value $Controls.IntervalSeconds.Text -Ranges $Limits.Ranges
    $state.MonitoringMode = [string]$Controls.MonitoringMode.SelectedItem.Content
    $state.HeartbeatMinutes = ConvertTo-NetworkDiagGuiInt -Name "HeartbeatMinutes" -Value $Controls.HeartbeatMinutes.Text -Ranges $Limits.Ranges
    $state.SnapshotMinutes = ConvertTo-NetworkDiagGuiInt -Name "SnapshotMinutes" -Value $Controls.SnapshotMinutes.Text -Ranges $Limits.Ranges
    $state.EventLogLookbackMinutes = ConvertTo-NetworkDiagGuiInt -Name "EventLogLookbackMinutes" -Value $Controls.EventLogLookbackMinutes.Text -Ranges $Limits.Ranges
    $state.OutputRoot = [string]$Controls.OutputRoot.Text.Trim()
    $state.RequireEthernet = [bool]$Controls.RequireEthernet.IsChecked
    $state.SkipTcpProbe = [bool]$Controls.SkipTcpProbe.IsChecked
    $state.DetailLog = [bool]$Controls.DetailLog.IsChecked
    $state.LegacyCsvShape = [bool]$Controls.LegacyCsvShape.IsChecked
    $state.ExternalIcmpHosts = ConvertTo-NetworkDiagGuiList -Raw $Controls.ExternalIcmpHosts.Text
    $state.ExternalIcmpLabels = ConvertTo-NetworkDiagGuiList -Raw $Controls.ExternalIcmpLabels.Text
    $state.TcpProbeHosts = ConvertTo-NetworkDiagGuiList -Raw $Controls.TcpProbeHosts.Text
    $state.DnsProbeName = [string]$Controls.DnsProbeName.Text.Trim()
    $state.SkipDnsProbe = [bool]$Controls.SkipDnsProbe.IsChecked
    $state.IcmpCountPerTarget = ConvertTo-NetworkDiagGuiInt -Name "IcmpCountPerTarget" -Value $Controls.IcmpCountPerTarget.Text -Ranges $Limits.Ranges
    $state.IcmpTimeoutSeconds = ConvertTo-NetworkDiagGuiInt -Name "IcmpTimeoutSeconds" -Value $Controls.IcmpTimeoutSeconds.Text -Ranges $Limits.Ranges
    $state.DnsTimeoutMs = ConvertTo-NetworkDiagGuiInt -Name "DnsTimeoutMs" -Value $Controls.DnsTimeoutMs.Text -Ranges $Limits.Ranges
    $state.BurstOnFault = [bool]$Controls.BurstOnFault.IsChecked
    $state.BurstIntervalSeconds = ConvertTo-NetworkDiagGuiInt -Name "BurstIntervalSeconds" -Value $Controls.BurstIntervalSeconds.Text -Ranges $Limits.Ranges
    $state.BurstCycles = ConvertTo-NetworkDiagGuiInt -Name "BurstCycles" -Value $Controls.BurstCycles.Text -Ranges $Limits.Ranges
    $state.MaxBurstSeconds = ConvertTo-NetworkDiagGuiInt -Name "MaxBurstSeconds" -Value $Controls.MaxBurstSeconds.Text -Ranges $Limits.Ranges
    $state.GwIcmpPolicyConfirmCycles = ConvertTo-NetworkDiagGuiInt -Name "GwIcmpPolicyConfirmCycles" -Value $Controls.GwIcmpPolicyConfirmCycles.Text -Ranges $Limits.Ranges
    $state.SkipGwIcmpPolicyAdaptation = [bool]$Controls.SkipGwIcmpPolicyAdaptation.IsChecked
    $state.RoutingRefreshIntervalCycles = ConvertTo-NetworkDiagGuiInt -Name "RoutingRefreshIntervalCycles" -Value $Controls.RoutingRefreshIntervalCycles.Text -Ranges $Limits.Ranges
    $state.PinExternalIcmpToResolvedIp = [bool]$Controls.PinExternalIcmpToResolvedIp.IsChecked
    $state.ProbeAddressFamily = [string]$Controls.ProbeAddressFamily.SelectedItem.Content
    $state.SkipConfigAudit = [bool]$Controls.SkipConfigAudit.IsChecked
    $state.SkipCableHints = [bool]$Controls.SkipCableHints.IsChecked
    $state.SkipMultiNicCrossCheck = [bool]$Controls.SkipMultiNicCrossCheck.IsChecked
    $state.SkipIspEvidencePacket = [bool]$Controls.SkipIspEvidencePacket.IsChecked
    $state.IspEvidenceZip = [bool]$Controls.IspEvidenceZip.IsChecked
    $state.PathMtuProbeTarget = [string]$Controls.PathMtuProbeTarget.Text.Trim()
    $state.SkipWifiSignal = [bool]$Controls.SkipWifiSignal.IsChecked
    $state.EnableTlsProbe = [bool]$Controls.EnableTlsProbe.IsChecked
    $state.SkipJsonSummary = [bool]$Controls.SkipJsonSummary.IsChecked
    $state.SelfTest = [bool]$Controls.SelfTest.IsChecked
    if ($Controls.ContainsKey("EnableUdpProbe")) {
        $state.EnableUdpProbe = [bool]$Controls.EnableUdpProbe.IsChecked
        $state.UdpProbeTarget = [string]$Controls.UdpProbeTarget.Text.Trim()
        $state.UdpProbeRateHz = ConvertTo-NetworkDiagGuiInt -Name "UdpProbeRateHz" -Value $Controls.UdpProbeRateHz.Text -Ranges $Limits.Ranges
        $state.UdpProbePayloadBytes = ConvertTo-NetworkDiagGuiInt -Name "UdpProbePayloadBytes" -Value $Controls.UdpProbePayloadBytes.Text -Ranges $Limits.Ranges
    }
    if ($Controls.ContainsKey("EnableLongLivedTcp")) {
        $state.EnableLongLivedTcp = [bool]$Controls.EnableLongLivedTcp.IsChecked
        $state.LongLivedTcpTarget = [string]$Controls.LongLivedTcpTarget.Text.Trim()
        $state.LongLivedTcpReconnectBackoffSeconds = ConvertTo-NetworkDiagGuiInt -Name "LongLivedTcpReconnectBackoffSeconds" -Value $Controls.LongLivedTcpReconnectBackoffSeconds.Text -Ranges $Limits.Ranges
    }
    if ($Controls.ContainsKey("PerProbeTimestamps")) {
        $state.PerProbeTimestamps = [bool]$Controls.PerProbeTimestamps.IsChecked
    }
    if ($Controls.ContainsKey("AutoCaptureOnFault")) {
        $state.AutoCaptureOnFault = [bool]$Controls.AutoCaptureOnFault.IsChecked
        $sel = $Controls.AutoCaptureMethod.SelectedItem
        $state.AutoCaptureMethod = if ($sel) { [string]$sel.Content } else { "pktmon" }
        $state.AutoCaptureSeconds = ConvertTo-NetworkDiagGuiInt -Name "AutoCaptureSeconds" -Value $Controls.AutoCaptureSeconds.Text -Ranges $Limits.Ranges
        $state.AutoCaptureMax = ConvertTo-NetworkDiagGuiInt -Name "AutoCaptureMax" -Value $Controls.AutoCaptureMax.Text -Ranges $Limits.Ranges
    }
    return $state
}

function Set-NetworkDiagGuiControlState {
    param(
        [hashtable]$Controls,
        [hashtable]$State
    )
    $Controls.DurationMinutes.Text = [string]$State.DurationMinutes
    $Controls.IntervalSeconds.Text = [string]$State.IntervalSeconds
    foreach ($i in $Controls.MonitoringMode.Items) {
        if ([string]$i.Content -eq [string]$State.MonitoringMode) { $Controls.MonitoringMode.SelectedItem = $i; break }
    }
    $Controls.HeartbeatMinutes.Text = [string]$State.HeartbeatMinutes
    $Controls.SnapshotMinutes.Text = [string]$State.SnapshotMinutes
    $Controls.EventLogLookbackMinutes.Text = [string]$State.EventLogLookbackMinutes
    $Controls.OutputRoot.Text = [string]$State.OutputRoot
    $Controls.RequireEthernet.IsChecked = [bool]$State.RequireEthernet
    $Controls.SkipTcpProbe.IsChecked = [bool]$State.SkipTcpProbe
    $Controls.DetailLog.IsChecked = [bool]$State.DetailLog
    $Controls.LegacyCsvShape.IsChecked = [bool]$State.LegacyCsvShape
    $Controls.ExternalIcmpHosts.Text = [string](@($State.ExternalIcmpHosts) -join [Environment]::NewLine)
    $Controls.ExternalIcmpLabels.Text = [string](@($State.ExternalIcmpLabels) -join [Environment]::NewLine)
    $Controls.TcpProbeHosts.Text = [string](@($State.TcpProbeHosts) -join [Environment]::NewLine)
    $Controls.DnsProbeName.Text = [string]$State.DnsProbeName
    $Controls.SkipDnsProbe.IsChecked = [bool]$State.SkipDnsProbe
    $Controls.IcmpCountPerTarget.Text = [string]$State.IcmpCountPerTarget
    $Controls.IcmpTimeoutSeconds.Text = [string]$State.IcmpTimeoutSeconds
    $Controls.DnsTimeoutMs.Text = [string]$State.DnsTimeoutMs
    $Controls.BurstOnFault.IsChecked = [bool]$State.BurstOnFault
    $Controls.BurstIntervalSeconds.Text = [string]$State.BurstIntervalSeconds
    $Controls.BurstCycles.Text = [string]$State.BurstCycles
    $Controls.MaxBurstSeconds.Text = [string]$State.MaxBurstSeconds
    $Controls.GwIcmpPolicyConfirmCycles.Text = [string]$State.GwIcmpPolicyConfirmCycles
    $Controls.SkipGwIcmpPolicyAdaptation.IsChecked = [bool]$State.SkipGwIcmpPolicyAdaptation
    $Controls.RoutingRefreshIntervalCycles.Text = [string]$State.RoutingRefreshIntervalCycles
    $Controls.PinExternalIcmpToResolvedIp.IsChecked = [bool]$State.PinExternalIcmpToResolvedIp
    foreach ($i in $Controls.ProbeAddressFamily.Items) {
        if ([string]$i.Content -eq [string]$State.ProbeAddressFamily) { $Controls.ProbeAddressFamily.SelectedItem = $i; break }
    }
    $Controls.SkipConfigAudit.IsChecked = [bool]$State.SkipConfigAudit
    $Controls.SkipCableHints.IsChecked = [bool]$State.SkipCableHints
    $Controls.SkipMultiNicCrossCheck.IsChecked = [bool]$State.SkipMultiNicCrossCheck
    $Controls.SkipIspEvidencePacket.IsChecked = [bool]$State.SkipIspEvidencePacket
    $Controls.IspEvidenceZip.IsChecked = [bool]$State.IspEvidenceZip
    $Controls.PathMtuProbeTarget.Text = [string]$State.PathMtuProbeTarget
    $Controls.SkipWifiSignal.IsChecked = [bool]$State.SkipWifiSignal
    $Controls.EnableTlsProbe.IsChecked = [bool]$State.EnableTlsProbe
    $Controls.SkipJsonSummary.IsChecked = [bool]$State.SkipJsonSummary
    $Controls.SelfTest.IsChecked = [bool]$State.SelfTest
    if ($Controls.ContainsKey("EnableUdpProbe")) {
        $Controls.EnableUdpProbe.IsChecked = [bool]$State.EnableUdpProbe
        $Controls.UdpProbeTarget.Text = [string]$State.UdpProbeTarget
        $Controls.UdpProbeRateHz.Text = [string]$State.UdpProbeRateHz
        $Controls.UdpProbePayloadBytes.Text = [string]$State.UdpProbePayloadBytes
    }
    if ($Controls.ContainsKey("EnableLongLivedTcp")) {
        $Controls.EnableLongLivedTcp.IsChecked = [bool]$State.EnableLongLivedTcp
        $Controls.LongLivedTcpTarget.Text = [string]$State.LongLivedTcpTarget
        $Controls.LongLivedTcpReconnectBackoffSeconds.Text = [string]$State.LongLivedTcpReconnectBackoffSeconds
    }
    if ($Controls.ContainsKey("PerProbeTimestamps")) {
        $Controls.PerProbeTimestamps.IsChecked = [bool]$State.PerProbeTimestamps
    }
    if ($Controls.ContainsKey("AutoCaptureOnFault")) {
        $Controls.AutoCaptureOnFault.IsChecked = [bool]$State.AutoCaptureOnFault
        foreach ($i in $Controls.AutoCaptureMethod.Items) {
            if ([string]$i.Content -eq [string]$State.AutoCaptureMethod) { $Controls.AutoCaptureMethod.SelectedItem = $i; break }
        }
        $Controls.AutoCaptureSeconds.Text = [string]$State.AutoCaptureSeconds
        $Controls.AutoCaptureMax.Text = [string]$State.AutoCaptureMax
    }
}

function Get-NetworkDiagGuiStateSnapshot {
    try {
        return Get-NetworkDiagGuiStateFromControls -Controls $script:App.Ui.Controls -Limits $script:App.Config.Limits
    } catch {
        return $null
    }
}
