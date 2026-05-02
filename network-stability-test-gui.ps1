#Requires -Version 5.1
<#
.SYNOPSIS
    WPF launcher for network-stability-test.ps1.

.DESCRIPTION
    Modular GUI entrypoint that wires core modules and starts the launcher app.
#>

param(
    [switch]$ElevatedLaunch,
    [string]$ConfigPath = "",
    [switch]$AutoRunElevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$guiRoot = Join-Path $PSScriptRoot "gui\core"
foreach ($moduleFile in @(
    "hooks.ps1",
    "layout.ps1",
    "state.ps1",
    "profiles.ps1",
    "validation.ps1",
    "health-dashboard.ps1",
    "insights.ps1",
    "run-service.ps1",
    "ui-events.ps1",
    "bootstrap.ps1"
)) {
    $modulePath = Join-Path $guiRoot $moduleFile
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Missing GUI module: $modulePath"
    }
    . $modulePath
}

$script:NetworkDiagGuiEntryPath = $PSCommandPath
Start-NetworkDiagGuiApp -ElevatedLaunch:$ElevatedLaunch -ConfigPath $ConfigPath -AutoRunElevated:$AutoRunElevated
#Requires -Version 5.1
<#
.SYNOPSIS
    WPF launcher for network-stability-test.ps1.

.DESCRIPTION
    Modular GUI entrypoint that wires core modules and starts the launcher app.
#>

param(
    [switch]$ElevatedLaunch,
    [string]$ConfigPath = "",
    [switch]$AutoRunElevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$guiRoot = Join-Path $PSScriptRoot "gui\core"
foreach ($moduleFile in @(
    "hooks.ps1",
    "layout.ps1",
    "state.ps1",
    "profiles.ps1",
    "validation.ps1",
    "health-dashboard.ps1",
    "insights.ps1",
    "run-service.ps1",
    "ui-events.ps1",
    "bootstrap.ps1"
)) {
    $modulePath = Join-Path $guiRoot $moduleFile
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Missing GUI module: $modulePath"
    }
    . $modulePath
}

$script:NetworkDiagGuiEntryPath = $PSCommandPath
Start-NetworkDiagGuiApp -ElevatedLaunch:$ElevatedLaunch -ConfigPath $ConfigPath -AutoRunElevated:$AutoRunElevated
#Requires -Version 5.1
<#
.SYNOPSIS
    WPF launcher for network-stability-test.ps1.

.DESCRIPTION
    Provides a GUI for all script parameters, validates known constraints from
    the codebase, supports optional UAC relaunch for full-capability runs, and
    keeps launcher logs in a dedicated per-run logs folder.
#>

param(
    [switch]$ElevatedLaunch,
    [string]$ConfigPath = "",
    [switch]$AutoRunElevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

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
        }
        AllowedSets = @{
            MonitoringMode = @("Auto", "ShortRun", "LongRun")
            ProbeAddressFamily = @("IPv4", "IPv6")
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

function Test-NetworkDiagGuiHostToken {
    param([string]$Value)
    if (-not $Value) { return $false }
    $token = $Value.Trim()
    if (-not $token) { return $false }

    $ip = $null
    if ([System.Net.IPAddress]::TryParse($token, [ref]$ip)) {
        return $true
    }

    $kind = [System.Uri]::CheckHostName($token)
    return ($kind -eq [System.UriHostNameType]::Dns)
}

function Test-NetworkDiagGuiCanWriteDirectory {
    param([string]$Path)
    if (-not $Path) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $Path -Force)
        }
        $probe = Join-Path $Path (".__networkdiag_write_probe_" + [guid]::NewGuid().ToString("N") + ".tmp")
        [System.IO.File]::WriteAllText($probe, "ok", (New-Object System.Text.UTF8Encoding $false))
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
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
    }
}

function Get-NetworkDiagGuiPresets {
    param([hashtable]$BaseState)
    $quick = @{}
    foreach ($k in $BaseState.Keys) { $quick[$k] = $BaseState[$k] }
    $quick.MonitoringMode = "ShortRun"
    $quick.DurationMinutes = 20
    $quick.IntervalSeconds = 3
    $quick.DetailLog = $true
    $quick.BurstOnFault = $true

    $long = @{}
    foreach ($k in $BaseState.Keys) { $long[$k] = $BaseState[$k] }
    $long.MonitoringMode = "LongRun"
    $long.DurationMinutes = 480
    $long.IntervalSeconds = 5
    $long.DetailLog = $true
    $long.BurstOnFault = $true
    $long.BurstCycles = 10

    $isp = @{}
    foreach ($k in $BaseState.Keys) { $isp[$k] = $BaseState[$k] }
    $isp.MonitoringMode = "LongRun"
    $isp.DurationMinutes = 240
    $isp.DetailLog = $true
    $isp.IspEvidenceZip = $true
    $isp.SkipIspEvidencePacket = $false
    $isp.EnableTlsProbe = $true
    $isp.SkipJsonSummary = $false
    $isp.BurstOnFault = $true

    return [ordered]@{
        "Quick Smoke (20m)" = $quick
        "Long Soak (8h)" = $long
        "ISP Escalation (4h)" = $isp
    }
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

    foreach ($switchName in @(
        "RequireEthernet", "SkipTcpProbe", "DetailLog", "LegacyCsvShape", "SkipDnsProbe",
        "BurstOnFault", "SkipGwIcmpPolicyAdaptation", "PinExternalIcmpToResolvedIp",
        "SkipConfigAudit", "SkipCableHints", "SkipMultiNicCrossCheck", "SkipIspEvidencePacket",
        "IspEvidenceZip", "SkipWifiSignal", "EnableTlsProbe", "SkipJsonSummary", "SelfTest"
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
    return $state
}

function Test-NetworkDiagGuiState {
    param(
        [hashtable]$State,
        [hashtable]$Limits
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    if (-not $State.OutputRoot) {
        $errors.Add("Output root cannot be empty.")
    }
    if (@($State.ExternalIcmpHosts).Count -lt 2 -or @($State.ExternalIcmpHosts).Count -gt 6) {
        $errors.Add("ExternalIcmpHosts must contain 2 to 6 items.")
    }
    if (@($State.ExternalIcmpLabels).Count -gt 0 -and @($State.ExternalIcmpLabels).Count -ne @($State.ExternalIcmpHosts).Count) {
        $errors.Add("ExternalIcmpLabels must be empty or match ExternalIcmpHosts count.")
    }
    if (@($State.TcpProbeHosts).Count -gt 0 -and @($State.TcpProbeHosts).Count -ne 2) {
        $errors.Add("TcpProbeHosts must be empty or contain exactly 2 items.")
    }
    if ($State.BurstOnFault -and $State.BurstIntervalSeconds -ge $State.IntervalSeconds) {
        $errors.Add("BurstIntervalSeconds must be less than IntervalSeconds when BurstOnFault is enabled.")
    }
    if (-not $State.SkipDnsProbe -and -not $State.DnsProbeName) {
        $errors.Add("DnsProbeName cannot be empty unless SkipDnsProbe is enabled.")
    }
    if ($State.DurationMinutes -gt 10080) {
        $warnings.Add("Duration exceeds 7 days; logs can grow very large.")
    }
    if ($State.DurationMinutes -ge 1440 -and $State.DetailLog) {
        $warnings.Add("DetailLog is enabled for a 24h+ run; launcher logs can become large.")
    }
    if (-not ($Limits.AllowedSets.MonitoringMode -contains $State.MonitoringMode)) {
        $errors.Add("MonitoringMode must be one of: Auto, ShortRun, LongRun.")
    }
    if (-not ($Limits.AllowedSets.ProbeAddressFamily -contains $State.ProbeAddressFamily)) {
        $errors.Add("ProbeAddressFamily must be IPv4 or IPv6.")
    }
    foreach ($h in @($State.ExternalIcmpHosts)) {
        if (-not (Test-NetworkDiagGuiHostToken -Value $h)) {
            $errors.Add("ExternalIcmpHosts contains an invalid host/IP: $h")
        }
    }
    foreach ($h in @($State.TcpProbeHosts)) {
        if (-not (Test-NetworkDiagGuiHostToken -Value $h)) {
            $errors.Add("TcpProbeHosts contains an invalid host/IP: $h")
        }
    }
    if ($State.PathMtuProbeTarget -and -not (Test-NetworkDiagGuiHostToken -Value $State.PathMtuProbeTarget)) {
        $errors.Add("PathMtuProbeTarget must be a valid hostname or IP.")
    }
    return @{ Errors = @($errors); Warnings = @($warnings) }
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
}

function New-NetworkDiagGuiLauncherPaths {
    param([string]$BaseRoot)
    $ts = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $root = Join-Path (Join-Path $BaseRoot "gui-launcher-runs") "run_$ts"
    $logs = Join-Path $root "logs"
    $scriptRoot = Join-Path $root "script-output-root"
    foreach ($p in @($root, $logs, $scriptRoot)) {
        if (-not (Test-Path -LiteralPath $p -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $p -Force)
        }
    }
    return @{
        LauncherRunRoot = $root
        LogsFolder = $logs
        ScriptOutputRoot = $scriptRoot
    }
}

function Write-NetworkDiagGuiLogLine {
    param([string]$Path, [string]$Text)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Text"
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Get-NetworkDiagGuiScriptPath {
    $p = Join-Path $PSScriptRoot "network-stability-test.ps1"
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        throw "Could not find network-stability-test.ps1 next to GUI launcher: $p"
    }
    return $p
}

function Save-NetworkDiagGuiConfig {
    param([hashtable]$State)
    $cfgPath = Join-Path $env:TEMP ("networkdiag_gui_state_" + [guid]::NewGuid().ToString("N") + ".json")
    $json = $State | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($cfgPath, $json, (New-Object System.Text.UTF8Encoding $false))
    return $cfgPath
}

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Network Stability Test Launcher"
        Height="860" Width="1120"
        WindowStartupLocation="CenterScreen">
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="220"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="#FFF2CC" Padding="8" CornerRadius="4" Margin="0,0,0,8">
            <TextBlock Name="AdminBanner" TextWrapping="Wrap"/>
        </Border>

        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto">
            <StackPanel>
                <GroupBox Header="Run Basics" Margin="0,0,0,8">
                    <Grid Margin="8">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="180"/>
                            <ColumnDefinition Width="200"/>
                            <ColumnDefinition Width="180"/>
                            <ColumnDefinition Width="200"/>
                            <ColumnDefinition Width="180"/>
                            <ColumnDefinition Width="200"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="DurationMinutes" VerticalAlignment="Center"/>
                        <TextBox Name="DurationMinutes" Grid.Row="0" Grid.Column="1" Margin="4"/>
                        <TextBlock Grid.Row="0" Grid.Column="2" Text="IntervalSeconds" VerticalAlignment="Center"/>
                        <TextBox Name="IntervalSeconds" Grid.Row="0" Grid.Column="3" Margin="4"/>
                        <TextBlock Grid.Row="0" Grid.Column="4" Text="MonitoringMode" VerticalAlignment="Center"/>
                        <ComboBox Name="MonitoringMode" Grid.Row="0" Grid.Column="5" Margin="4">
                            <ComboBoxItem Content="Auto"/>
                            <ComboBoxItem Content="ShortRun"/>
                            <ComboBoxItem Content="LongRun"/>
                        </ComboBox>
                        <TextBlock Grid.Row="1" Grid.Column="0" Text="HeartbeatMinutes" VerticalAlignment="Center"/>
                        <TextBox Name="HeartbeatMinutes" Grid.Row="1" Grid.Column="1" Margin="4"/>
                        <TextBlock Grid.Row="1" Grid.Column="2" Text="SnapshotMinutes" VerticalAlignment="Center"/>
                        <TextBox Name="SnapshotMinutes" Grid.Row="1" Grid.Column="3" Margin="4"/>
                        <TextBlock Grid.Row="1" Grid.Column="4" Text="EventLogLookbackMinutes" VerticalAlignment="Center"/>
                        <TextBox Name="EventLogLookbackMinutes" Grid.Row="1" Grid.Column="5" Margin="4"/>
                        <TextBlock Grid.Row="2" Grid.Column="0" Text="ProbeAddressFamily" VerticalAlignment="Center"/>
                        <ComboBox Name="ProbeAddressFamily" Grid.Row="2" Grid.Column="1" Margin="4">
                            <ComboBoxItem Content="IPv4"/>
                            <ComboBoxItem Content="IPv6"/>
                        </ComboBox>
                    </Grid>
                </GroupBox>

                <GroupBox Header="Output + Lists" Margin="0,0,0,8">
                    <Grid Margin="8">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="180"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="100"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="120"/>
                            <RowDefinition Height="120"/>
                            <RowDefinition Height="120"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="Output root" VerticalAlignment="Center"/>
                        <TextBox Name="OutputRoot" Grid.Row="0" Grid.Column="1" Margin="4"/>
                        <Button Name="BrowseOutputRoot" Grid.Row="0" Grid.Column="2" Margin="4" Content="Browse"/>

                        <TextBlock Grid.Row="1" Grid.Column="0" Text="ExternalIcmpHosts (2..6)" VerticalAlignment="Top"/>
                        <TextBox Name="ExternalIcmpHosts" Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="2" Margin="4" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>

                        <TextBlock Grid.Row="2" Grid.Column="0" Text="ExternalIcmpLabels (optional)" VerticalAlignment="Top"/>
                        <TextBox Name="ExternalIcmpLabels" Grid.Row="2" Grid.Column="1" Grid.ColumnSpan="2" Margin="4" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>

                        <TextBlock Grid.Row="3" Grid.Column="0" Text="TcpProbeHosts (optional; exactly 2)" VerticalAlignment="Top"/>
                        <TextBox Name="TcpProbeHosts" Grid.Row="3" Grid.Column="1" Grid.ColumnSpan="2" Margin="4" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>

                        <TextBlock Grid.Row="4" Grid.Column="0" Text="DnsProbeName" VerticalAlignment="Center"/>
                        <TextBox Name="DnsProbeName" Grid.Row="4" Grid.Column="1" Margin="4"/>
                    </Grid>
                </GroupBox>

                <GroupBox Header="Timing + Burst + Routing" Margin="0,0,0,8">
                    <Grid Margin="8">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="180"/>
                            <ColumnDefinition Width="200"/>
                            <ColumnDefinition Width="180"/>
                            <ColumnDefinition Width="200"/>
                            <ColumnDefinition Width="180"/>
                            <ColumnDefinition Width="200"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="IcmpCountPerTarget"/>
                        <TextBox Name="IcmpCountPerTarget" Grid.Row="0" Grid.Column="1" Margin="4"/>
                        <TextBlock Grid.Row="0" Grid.Column="2" Text="IcmpTimeoutSeconds"/>
                        <TextBox Name="IcmpTimeoutSeconds" Grid.Row="0" Grid.Column="3" Margin="4"/>
                        <TextBlock Grid.Row="0" Grid.Column="4" Text="DnsTimeoutMs"/>
                        <TextBox Name="DnsTimeoutMs" Grid.Row="0" Grid.Column="5" Margin="4"/>
                        <CheckBox Name="BurstOnFault" Grid.Row="1" Grid.Column="0" Content="BurstOnFault" Margin="4"/>
                        <TextBlock Grid.Row="1" Grid.Column="2" Text="BurstIntervalSeconds"/>
                        <TextBox Name="BurstIntervalSeconds" Grid.Row="1" Grid.Column="3" Margin="4"/>
                        <TextBlock Grid.Row="1" Grid.Column="4" Text="BurstCycles"/>
                        <TextBox Name="BurstCycles" Grid.Row="1" Grid.Column="5" Margin="4"/>
                        <TextBlock Grid.Row="2" Grid.Column="0" Text="MaxBurstSeconds"/>
                        <TextBox Name="MaxBurstSeconds" Grid.Row="2" Grid.Column="1" Margin="4"/>
                        <TextBlock Grid.Row="2" Grid.Column="2" Text="GwIcmpPolicyConfirmCycles"/>
                        <TextBox Name="GwIcmpPolicyConfirmCycles" Grid.Row="2" Grid.Column="3" Margin="4"/>
                        <TextBlock Grid.Row="2" Grid.Column="4" Text="RoutingRefreshIntervalCycles"/>
                        <TextBox Name="RoutingRefreshIntervalCycles" Grid.Row="2" Grid.Column="5" Margin="4"/>
                    </Grid>
                </GroupBox>

                <GroupBox Header="Feature Switches" Margin="0,0,0,8">
                    <WrapPanel Margin="8">
                        <CheckBox Name="RequireEthernet" Content="RequireEthernet" Margin="8,4"/>
                        <CheckBox Name="SkipTcpProbe" Content="SkipTcpProbe" Margin="8,4"/>
                        <CheckBox Name="DetailLog" Content="DetailLog" Margin="8,4"/>
                        <CheckBox Name="LegacyCsvShape" Content="LegacyCsvShape" Margin="8,4"/>
                        <CheckBox Name="SkipDnsProbe" Content="SkipDnsProbe" Margin="8,4"/>
                        <CheckBox Name="SkipGwIcmpPolicyAdaptation" Content="SkipGwIcmpPolicyAdaptation" Margin="8,4"/>
                        <CheckBox Name="PinExternalIcmpToResolvedIp" Content="PinExternalIcmpToResolvedIp" Margin="8,4"/>
                        <CheckBox Name="SkipConfigAudit" Content="SkipConfigAudit" Margin="8,4"/>
                        <CheckBox Name="SkipCableHints" Content="SkipCableHints" Margin="8,4"/>
                        <CheckBox Name="SkipMultiNicCrossCheck" Content="SkipMultiNicCrossCheck" Margin="8,4"/>
                        <CheckBox Name="SkipIspEvidencePacket" Content="SkipIspEvidencePacket" Margin="8,4"/>
                        <CheckBox Name="IspEvidenceZip" Content="IspEvidenceZip" Margin="8,4"/>
                        <CheckBox Name="SkipWifiSignal" Content="SkipWifiSignal" Margin="8,4"/>
                        <CheckBox Name="EnableTlsProbe" Content="EnableTlsProbe" Margin="8,4"/>
                        <CheckBox Name="SkipJsonSummary" Content="SkipJsonSummary" Margin="8,4"/>
                        <CheckBox Name="SelfTest" Content="SelfTest" Margin="8,4"/>
                    </WrapPanel>
                </GroupBox>

                <GroupBox Header="Optional Path MTU Target" Margin="0,0,0,8">
                    <Grid Margin="8">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="180"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="PathMtuProbeTarget"/>
                        <TextBox Name="PathMtuProbeTarget" Grid.Column="1" Margin="4"/>
                    </Grid>
                </GroupBox>

                <GroupBox Header="Profiles + Recent Runs" Margin="0,0,0,8">
                    <Grid Margin="8">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="160"/>
                            <ColumnDefinition Width="280"/>
                            <ColumnDefinition Width="140"/>
                            <ColumnDefinition Width="140"/>
                            <ColumnDefinition Width="140"/>
                            <ColumnDefinition Width="140"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="120"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="Built-in preset" VerticalAlignment="Center"/>
                        <ComboBox Name="PresetSelector" Grid.Row="0" Grid.Column="1" Margin="4"/>
                        <Button Name="ApplyPreset" Grid.Row="0" Grid.Column="2" Margin="4" Content="Apply preset"/>
                        <Button Name="SaveProfile" Grid.Row="0" Grid.Column="3" Margin="4" Content="Save profile"/>
                        <Button Name="LoadProfile" Grid.Row="0" Grid.Column="4" Margin="4" Content="Load profile"/>
                        <Button Name="ReRunSelected" Grid.Row="0" Grid.Column="5" Margin="4" Content="Re-run selected"/>

                        <TextBlock Grid.Row="1" Grid.Column="0" Text="Recent runs" VerticalAlignment="Top"/>
                        <ListBox Name="RecentRunsList" Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="5" Margin="4"/>

                        <Button Name="OpenSelectedRun" Grid.Row="2" Grid.Column="4" Margin="4" Content="Open selected run"/>
                        <Button Name="OpenSelectedLogs" Grid.Row="2" Grid.Column="5" Margin="4" Content="Open selected logs"/>
                    </Grid>
                </GroupBox>

                <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" Margin="0,0,0,8">
                    <Button Name="RunNormal" Content="Run (Standard)" Width="160" Margin="0,0,8,0"/>
                    <Button Name="RunAdmin" Content="Run Full Capabilities (Admin)" Width="240" Margin="0,0,8,0"/>
                    <Button Name="StopRun" Content="Stop Active Run" Width="140" Margin="0,0,8,0"/>
                    <Button Name="OpenCurrentRun" Content="Open Current Run Folder" Width="180" Margin="0,0,8,0"/>
                    <Button Name="OpenCurrentLogs" Content="Open Current Logs Folder" Width="180"/>
                </StackPanel>

                <TextBlock Name="StatusText" Foreground="DarkSlateBlue" Margin="0,0,0,8" TextWrapping="Wrap"/>
                <TextBlock Name="ValidationText" Foreground="DarkOliveGreen" Margin="0,0,0,8" TextWrapping="Wrap"/>

                <GroupBox Header="Live Health Dashboard" Margin="0,0,0,8">
                    <Grid Margin="8">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="180"/>
                            <ColumnDefinition Width="180"/>
                            <ColumnDefinition Width="180"/>
                            <ColumnDefinition Width="180"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <TextBlock Grid.Row="0" Grid.Column="0" Name="HealthRunVerdict" Margin="4" Text="Verdict: n/a"/>
                        <TextBlock Grid.Row="0" Grid.Column="1" Name="HealthDns" Margin="4" Text="DNS: n/a"/>
                        <TextBlock Grid.Row="0" Grid.Column="2" Name="HealthGateway" Margin="4" Text="Gateway: n/a"/>
                        <TextBlock Grid.Row="0" Grid.Column="3" Name="HealthExternal" Margin="4" Text="External: n/a"/>
                        <TextBlock Grid.Row="0" Grid.Column="4" Name="HealthTcp" Margin="4" Text="TCP/TLS: n/a"/>

                        <TextBlock Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="2" Name="HealthCycles" Margin="4" Text="Cycles: 0"/>
                        <TextBlock Grid.Row="1" Grid.Column="2" Grid.ColumnSpan="3" Name="HealthLastUpdate" Margin="4" Text="Last update: n/a"/>
                        <TextBlock Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="2" Name="HealthSeverity" Margin="4" Text="Severity: n/a"/>
                        <TextBlock Grid.Row="2" Grid.Column="2" Grid.ColumnSpan="3" Name="HealthTrend" Margin="4" Text="Trend(20): DNS=n/a GW=n/a EXT=n/a TCP=n/a"/>
                    </Grid>
                </GroupBox>

                <GroupBox Header="Post-run Quick Analysis" Margin="0,0,0,8">
                    <TextBox Name="QuickAnalysis"
                             Margin="8"
                             Height="130"
                             AcceptsReturn="True"
                             IsReadOnly="True"
                             TextWrapping="Wrap"
                             VerticalScrollBarVisibility="Auto"/>
                </GroupBox>

                <GroupBox Header="Incident / Episode Timeline" Margin="0,0,0,8">
                    <Grid Margin="8">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="120"/>
                        </Grid.RowDefinitions>
                        <TextBlock Name="IncidentReasonText" Grid.Row="0" Margin="4" Text="Top incident reasons: n/a"/>
                        <ListBox Name="EpisodeTimelineList" Grid.Row="1" Margin="4"/>
                    </Grid>
                </GroupBox>
            </StackPanel>
        </ScrollViewer>

        <TextBox Grid.Row="2" Name="LiveLog" AcceptsReturn="True" IsReadOnly="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>
    </Grid>
</Window>
"@

[xml]$xamlXml = $xaml
$reader = New-Object System.Xml.XmlNodeReader $xamlXml
$window = [Windows.Markup.XamlReader]::Load($reader)

$controlNames = @(
    "AdminBanner","DurationMinutes","IntervalSeconds","MonitoringMode","HeartbeatMinutes","SnapshotMinutes","EventLogLookbackMinutes",
    "ProbeAddressFamily","OutputRoot","BrowseOutputRoot","ExternalIcmpHosts","ExternalIcmpLabels","TcpProbeHosts","DnsProbeName",
    "IcmpCountPerTarget","IcmpTimeoutSeconds","DnsTimeoutMs","BurstOnFault","BurstIntervalSeconds","BurstCycles","MaxBurstSeconds",
    "GwIcmpPolicyConfirmCycles","RoutingRefreshIntervalCycles","RequireEthernet","SkipTcpProbe","DetailLog","LegacyCsvShape",
    "SkipDnsProbe","SkipGwIcmpPolicyAdaptation","PinExternalIcmpToResolvedIp","SkipConfigAudit","SkipCableHints","SkipMultiNicCrossCheck",
    "SkipIspEvidencePacket","IspEvidenceZip","PathMtuProbeTarget","SkipWifiSignal","EnableTlsProbe","SkipJsonSummary","SelfTest",
    "PresetSelector","ApplyPreset","SaveProfile","LoadProfile","RecentRunsList","ReRunSelected","OpenSelectedRun","OpenSelectedLogs",
    "RunNormal","RunAdmin","StopRun","OpenCurrentRun","OpenCurrentLogs","StatusText","ValidationText",
    "HealthRunVerdict","HealthDns","HealthGateway","HealthExternal","HealthTcp","HealthCycles","HealthLastUpdate","HealthSeverity","HealthTrend",
    "QuickAnalysis","IncidentReasonText","EpisodeTimelineList","LiveLog"
)
$controls = @{}
foreach ($n in $controlNames) { $controls[$n] = $window.FindName($n) }

$limits = Get-NetworkDiagGuiLimitations
$defaultState = New-NetworkDiagGuiDefaultState
if (-not $defaultState.OutputRoot) { $defaultState.OutputRoot = $PSScriptRoot }
$script:PresetMap = Get-NetworkDiagGuiPresets -BaseState $defaultState
if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    try {
        $loaded = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        foreach ($k in $loaded.Keys) { $defaultState[$k] = $loaded[$k] }
    } catch { }
}
Set-NetworkDiagGuiControlState -Controls $controls -State $defaultState
$controls.PresetSelector.Items.Clear()
foreach ($presetName in $script:PresetMap.Keys) {
    [void]$controls.PresetSelector.Items.Add($presetName)
}
if ($controls.PresetSelector.Items.Count -gt 0) { $controls.PresetSelector.SelectedIndex = 0 }

$script:IsAdminGui = Test-NetworkDiagGuiIsAdmin
$controls.AdminBanner.Text = if ($script:IsAdminGui) {
    "Admin context: elevated. Full capability paths are available."
} else {
    "Admin context: non-admin. Some features run in degraded/loose mode. Use 'Run Full Capabilities (Admin)' for strict behavior."
}

foreach ($cbName in @("SkipMultiNicCrossCheck","SkipConfigAudit","SkipCableHints","RequireEthernet","IspEvidenceZip")) {
    $controls[$cbName].ToolTip = ($limits.AdminCaveats -join " ")
}

$script:CurrentRunFolder = ""
$script:CurrentLogsFolder = ""
$script:CurrentProcess = $null
$script:ValidationHasErrors = $false
$script:RunState = "Idle"
$script:StopRequested = $false
$script:RecentRuns = [System.Collections.Generic.List[hashtable]]::new()
$script:LiveHealth = @{}

function New-NetworkDiagGuiLiveHealthState {
    return @{
        TrendWindow = 20
        CycleCount = 0
        OkCount = 0
        IspFaultCount = 0
        LocalFaultCount = 0
        AnomalyCount = 0
        LastVerdict = "n/a"
        DnsStatus = "n/a"
        GatewayStatus = "n/a"
        ExternalStatus = "n/a"
        TcpTlsStatus = "n/a"
        Severity = "n/a"
        DnsTrend = [System.Collections.Generic.List[int]]::new()
        GatewayTrend = [System.Collections.Generic.List[int]]::new()
        ExternalTrend = [System.Collections.Generic.List[int]]::new()
        TcpTrend = [System.Collections.Generic.List[int]]::new()
        LastUpdate = "n/a"
    }
}

function Get-NetworkDiagGuiStatusBrush {
    param([string]$Status)
    $s = [string]$Status
    if ($s -match "^(OK|PASS)") { return "DarkGreen" }
    if ($s -match "^(DEGRADED|WARN|WARNING|MIXED)") { return "DarkGoldenrod" }
    if ($s -match "^(n/a|N/A|WAITING)") { return "DimGray" }
    return "DarkRed"
}

function Add-NetworkDiagGuiTrendPoint {
    param(
        [System.Collections.Generic.List[int]]$Series,
        [int]$Value,
        [int]$Window
    )
    $Series.Add($Value)
    while ($Series.Count -gt $Window) {
        $Series.RemoveAt(0)
    }
}

function ConvertTo-NetworkDiagGuiTrendScore {
    param([string]$Status)
    $s = [string]$Status
    if ($s -match "^(OK|PASS)") { return 1 }
    if ($s -match "^(n/a|N/A|WAITING)$") { return -1 }
    return 0
}

function Get-NetworkDiagGuiTrendPercentText {
    param([System.Collections.Generic.List[int]]$Series)
    $valid = @($Series | Where-Object { $_ -ge 0 })
    if ($valid.Count -eq 0) { return "n/a" }
    $pass = @($valid | Where-Object { $_ -eq 1 }).Count
    $pct = [math]::Round((100.0 * $pass / $valid.Count), 0)
    return "$pct%"
}

function Get-NetworkDiagGuiSeverity {
    param([hashtable]$Health)
    if ($Health.LastVerdict -and $Health.LastVerdict -ne "n/a" -and $Health.LastVerdict -ne "OK") { return "CRITICAL" }
    foreach ($v in @($Health.DnsStatus, $Health.GatewayStatus, $Health.ExternalStatus, $Health.TcpTlsStatus)) {
        if ([string]$v -match "FAIL") { return "CRITICAL" }
    }
    foreach ($v in @($Health.DnsStatus, $Health.GatewayStatus, $Health.ExternalStatus, $Health.TcpTlsStatus)) {
        if ([string]$v -match "DEGRADED") { return "WARN" }
    }
    if ([int]$Health.IspFaultCount -gt 0 -or [int]$Health.LocalFaultCount -gt 0 -or [int]$Health.AnomalyCount -gt 0) { return "WARN" }
    if ([int]$Health.CycleCount -gt 0) { return "OK" }
    return "n/a"
}

function Set-NetworkDiagGuiQuickAnalysisText {
    param([string]$Text)
    $window.Dispatcher.Invoke([Action]{
        $controls.QuickAnalysis.Text = $Text
    })
}

function Reset-NetworkDiagGuiIncidentInsights {
    $window.Dispatcher.Invoke([Action]{
        $controls.IncidentReasonText.Text = "Top incident reasons: n/a"
        $controls.IncidentReasonText.Foreground = "DimGray"
        $controls.EpisodeTimelineList.Items.Clear()
        [void]$controls.EpisodeTimelineList.Items.Add("No completed run timeline available yet.")
    })
}

function Set-NetworkDiagGuiIncidentInsights {
    param(
        [string]$ReasonSummary,
        [string[]]$TimelineItems
    )
    $window.Dispatcher.Invoke([Action]{
        $controls.IncidentReasonText.Text = $ReasonSummary
        $controls.IncidentReasonText.Foreground = if ($ReasonSummary -match "none|n/a") { "DimGray" } else { "DarkSlateBlue" }
        $controls.EpisodeTimelineList.Items.Clear()
        if ($TimelineItems -and $TimelineItems.Count -gt 0) {
            foreach ($item in $TimelineItems) { [void]$controls.EpisodeTimelineList.Items.Add($item) }
        } else {
            [void]$controls.EpisodeTimelineList.Items.Add("No timeline events available in summary.")
        }
    })
}

function Reset-NetworkDiagGuiLiveHealth {
    $script:LiveHealth = New-NetworkDiagGuiLiveHealthState
    $window.Dispatcher.Invoke([Action]{
        $controls.HealthRunVerdict.Text = "Verdict: n/a"
        $controls.HealthRunVerdict.Foreground = "DimGray"
        $controls.HealthDns.Text = "DNS: n/a"
        $controls.HealthDns.Foreground = "DimGray"
        $controls.HealthGateway.Text = "Gateway: n/a"
        $controls.HealthGateway.Foreground = "DimGray"
        $controls.HealthExternal.Text = "External: n/a"
        $controls.HealthExternal.Foreground = "DimGray"
        $controls.HealthTcp.Text = "TCP/TLS: n/a"
        $controls.HealthTcp.Foreground = "DimGray"
        $controls.HealthCycles.Text = "Cycles: 0"
        $controls.HealthLastUpdate.Text = "Last update: n/a"
        $controls.HealthSeverity.Text = "Severity: n/a"
        $controls.HealthSeverity.Foreground = "DimGray"
        $controls.HealthTrend.Text = "Trend(20): DNS=n/a GW=n/a EXT=n/a TCP=n/a"
        $controls.HealthTrend.Foreground = "DimGray"
    })
}

function Update-NetworkDiagGuiHealthUi {
    $h = $script:LiveHealth
    $dnsTrend = Get-NetworkDiagGuiTrendPercentText -Series $h.DnsTrend
    $gwTrend = Get-NetworkDiagGuiTrendPercentText -Series $h.GatewayTrend
    $extTrend = Get-NetworkDiagGuiTrendPercentText -Series $h.ExternalTrend
    $tcpTrend = Get-NetworkDiagGuiTrendPercentText -Series $h.TcpTrend
    $h.Severity = Get-NetworkDiagGuiSeverity -Health $h
    $window.Dispatcher.Invoke([Action]{
        $controls.HealthRunVerdict.Text = "Verdict: $($h.LastVerdict)"
        $controls.HealthRunVerdict.Foreground = Get-NetworkDiagGuiStatusBrush -Status $h.LastVerdict
        $controls.HealthDns.Text = "DNS: $($h.DnsStatus)"
        $controls.HealthDns.Foreground = Get-NetworkDiagGuiStatusBrush -Status $h.DnsStatus
        $controls.HealthGateway.Text = "Gateway: $($h.GatewayStatus)"
        $controls.HealthGateway.Foreground = Get-NetworkDiagGuiStatusBrush -Status $h.GatewayStatus
        $controls.HealthExternal.Text = "External: $($h.ExternalStatus)"
        $controls.HealthExternal.Foreground = Get-NetworkDiagGuiStatusBrush -Status $h.ExternalStatus
        $controls.HealthTcp.Text = "TCP/TLS: $($h.TcpTlsStatus)"
        $controls.HealthTcp.Foreground = Get-NetworkDiagGuiStatusBrush -Status $h.TcpTlsStatus
        $controls.HealthCycles.Text = "Cycles: $($h.CycleCount) | OK=$($h.OkCount) ISP=$($h.IspFaultCount) Local=$($h.LocalFaultCount) Anomaly=$($h.AnomalyCount)"
        $controls.HealthLastUpdate.Text = "Last update: $($h.LastUpdate)"
        $controls.HealthSeverity.Text = "Severity: $($h.Severity)"
        $controls.HealthSeverity.Foreground = Get-NetworkDiagGuiStatusBrush -Status $h.Severity
        $controls.HealthTrend.Text = "Trend($($h.TrendWindow)): DNS=$dnsTrend GW=$gwTrend EXT=$extTrend TCP=$tcpTrend"
        $controls.HealthTrend.Foreground = "SlateGray"
    })
}

function Update-NetworkDiagGuiHealthFromLine {
    param([string]$Line)
    if (-not $Line) { return }
    $text = [string]$Line

    $hasCycle = $false
    if ($text -match "Verdict=([A-Z_]+)") {
        $verdict = $Matches[1]
        $hasCycle = $true
        $script:LiveHealth.CycleCount = [int]$script:LiveHealth.CycleCount + 1
        $script:LiveHealth.LastVerdict = $verdict
        if ($verdict -eq "OK") {
            $script:LiveHealth.OkCount = [int]$script:LiveHealth.OkCount + 1
        } elseif ($verdict -match "ISP") {
            $script:LiveHealth.IspFaultCount = [int]$script:LiveHealth.IspFaultCount + 1
        } elseif ($verdict -match "LOCAL") {
            $script:LiveHealth.LocalFaultCount = [int]$script:LiveHealth.LocalFaultCount + 1
        } else {
            $script:LiveHealth.AnomalyCount = [int]$script:LiveHealth.AnomalyCount + 1
        }
    }

    if ($text -match "DNS=DNS:([\-0-9]+)ms") {
        $dns = [int]$Matches[1]
        $script:LiveHealth.DnsStatus = if ($dns -ge 0) { "OK (${dns}ms)" } else { "FAIL" }
    } elseif ($text -match "DNS=(na|NA)") {
        $script:LiveHealth.DnsStatus = "n/a"
    }

    if ($text -match "\bGW=([\-0-9]+)ms\b") {
        $gw = [int]$Matches[1]
        $script:LiveHealth.GatewayStatus = if ($gw -ge 0) { "OK (${gw}ms)" } else { "FAIL" }
    } elseif ($text -match "\bGW=(na|NA)\b") {
        $script:LiveHealth.GatewayStatus = "n/a"
    }

    if ($text -match "EXT=(.+?)\s+DNS=") {
        $extSegment = $Matches[1]
        if ($extSegment -match ":-1ms|:na|:NA") {
            $script:LiveHealth.ExternalStatus = "DEGRADED"
        } else {
            $script:LiveHealth.ExternalStatus = "OK"
        }
    }

    if ($text -match "TCP_CF_ms=([\-0-9a-zA-Z]+)\s+TCP_GG_ms=([\-0-9a-zA-Z]+)") {
        $cf = $Matches[1]
        $gg = $Matches[2]
        if ($cf -eq "na" -or $gg -eq "na") {
            $script:LiveHealth.TcpTlsStatus = "n/a"
        } elseif ([int]$cf -ge 0 -and [int]$gg -ge 0) {
            $script:LiveHealth.TcpTlsStatus = "OK"
        } else {
            $script:LiveHealth.TcpTlsStatus = "FAIL"
        }
    }

    if ($text -match "TLS_.*=-1") {
        $script:LiveHealth.TcpTlsStatus = "DEGRADED"
    }

    if ($hasCycle) {
        Add-NetworkDiagGuiTrendPoint -Series $script:LiveHealth.DnsTrend -Value (ConvertTo-NetworkDiagGuiTrendScore -Status $script:LiveHealth.DnsStatus) -Window ([int]$script:LiveHealth.TrendWindow)
        Add-NetworkDiagGuiTrendPoint -Series $script:LiveHealth.GatewayTrend -Value (ConvertTo-NetworkDiagGuiTrendScore -Status $script:LiveHealth.GatewayStatus) -Window ([int]$script:LiveHealth.TrendWindow)
        Add-NetworkDiagGuiTrendPoint -Series $script:LiveHealth.ExternalTrend -Value (ConvertTo-NetworkDiagGuiTrendScore -Status $script:LiveHealth.ExternalStatus) -Window ([int]$script:LiveHealth.TrendWindow)
        Add-NetworkDiagGuiTrendPoint -Series $script:LiveHealth.TcpTrend -Value (ConvertTo-NetworkDiagGuiTrendScore -Status $script:LiveHealth.TcpTlsStatus) -Window ([int]$script:LiveHealth.TrendWindow)
    }

    $script:LiveHealth.LastUpdate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Update-NetworkDiagGuiHealthUi
}

function Get-NetworkDiagGuiSummaryPath {
    param([string]$RunFolder)
    if (-not $RunFolder -or -not (Test-Path -LiteralPath $RunFolder -PathType Container)) { return "" }
    $match = Get-ChildItem -LiteralPath $RunFolder -Filter "network_summary_*.json" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($match) { return $match.FullName }
    return ""
}

function Update-NetworkDiagGuiIncidentInsightsFromRunFolder {
    param([string]$RunFolder)
    $summaryPath = Get-NetworkDiagGuiSummaryPath -RunFolder $RunFolder
    if (-not $summaryPath) {
        Set-NetworkDiagGuiIncidentInsights -ReasonSummary "Top incident reasons: n/a (summary JSON not found)" -TimelineItems @("Run folder: $RunFolder")
        return
    }
    try {
        $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $reasonCounts = @{}
        foreach ($raw in @($summary.incidents.sample)) {
            if (-not $raw) { continue }
            $line = [string]$raw
            $code = "UNCLASSIFIED"
            if ($line -match "^\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?\s+([A-Z0-9_]+)\b") {
                $code = $Matches[1]
            }
            if (-not $reasonCounts.ContainsKey($code)) { $reasonCounts[$code] = 0 }
            $reasonCounts[$code] = [int]$reasonCounts[$code] + 1
        }

        $orderedReasons = @($reasonCounts.GetEnumerator() | Sort-Object -Property @("Value","Name") -Descending | Select-Object -First 3)
        $reasonSummary = if ($orderedReasons.Count -gt 0) {
            "Top incident reasons: " + (($orderedReasons | ForEach-Object { "$($_.Key) x$($_.Value)" }) -join ", ")
        } else {
            "Top incident reasons: none captured in summary sample."
        }

        $timeline = [System.Collections.Generic.List[string]]::new()
        if ([int]$summary.episodes.completed -gt 0) {
            foreach ($ep in @($summary.episodes.sample)) {
                if ($ep) { $timeline.Add("[Episode] " + [string]$ep) }
            }
            if ($timeline.Count -eq 0) {
                $timeline.Add("[Episode] Completed episodes: $($summary.episodes.completed) (details truncated/not sampled)")
            }
        } else {
            $timeline.Add("[Episode] Completed episodes: 0")
        }
        foreach ($evt in @($summary.incidents.sample)) {
            if ($evt) { $timeline.Add("[Incident] " + [string]$evt) }
        }
        Set-NetworkDiagGuiIncidentInsights -ReasonSummary $reasonSummary -TimelineItems @($timeline)
    } catch {
        Set-NetworkDiagGuiIncidentInsights -ReasonSummary ("Top incident reasons: parse error - " + $_.Exception.Message) -TimelineItems @("Summary path: $summaryPath")
    }
}

function Build-NetworkDiagGuiQuickAnalysis {
    param(
        [string]$RunFolder,
        [int]$ExitCode
    )
    $summaryPath = Get-NetworkDiagGuiSummaryPath -RunFolder $RunFolder
    if (-not $summaryPath) {
        return "Quick analysis unavailable: summary JSON not found. Exit code=$ExitCode.`r`nRun folder: $RunFolder"
    }

    try {
        $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("Summary source: $summaryPath")
        $lines.Add("Result mix: OK=$($summary.cycles.pctAllOk)% ISP=$($summary.cycles.pctIspFault)% Local=$($summary.cycles.pctLocalFault)% Anomaly=$($summary.cycles.pctAnomaly)%")
        $dnsPass = if ([int]$summary.cycles.committed -gt 0) { [math]::Round(100.0 * ([int]$summary.cycles.committed - [int]$summary.pcLink.dnsFailCycles) / [int]$summary.cycles.committed, 0) } else { 0 }
        $gwFail = [int]$summary.cycles.committed - [int]$summary.latency.gateway.count
        $gwPass = if ([int]$summary.cycles.committed -gt 0) { [math]::Round(100.0 * ([int]$summary.latency.gateway.count) / [int]$summary.cycles.committed, 0) } else { 0 }
        $tcpPass = if ([int]$summary.cycles.committed -gt 0) { [math]::Round(100.0 * (([int]$summary.cycles.committed) - [int]$summary.pcLink.icmpUpTcpDownCycles) / [int]$summary.cycles.committed, 0) } else { 0 }
        $lines.Add("Reliability estimate: DNS=$dnsPass% Gateway=$gwPass% TCP-Path~$tcpPass% (committed-window estimate)")

        if ([int]$summary.cycles.pctAllOk -ge 95) {
            $lines.Add("Likely state: stable window; no dominant link-path degradation.")
        } elseif ([int]$summary.cycles.pctIspFault -gt [int]$summary.cycles.pctLocalFault) {
            $lines.Add("Likely state: upstream/ISP-side instability is dominant.")
        } elseif ([int]$summary.cycles.pctLocalFault -gt 0) {
            $lines.Add("Likely state: local LAN/NIC/router segment contributes to failures.")
        } else {
            $lines.Add("Likely state: mixed or transient anomalies; inspect incident episodes.")
        }

        if ([int]$summary.pcLink.dnsFailCycles -gt 0) {
            $lines.Add("Signal: DNS failures observed ($($summary.pcLink.dnsFailCycles) cycles).")
        }
        if ($gwFail -gt 0) {
            $lines.Add("Signal: gateway ICMP not answered on $gwFail committed cycle(s).")
        }
        if ([int]$summary.tls.tcpUpTlsDownCycles -gt 0) {
            $lines.Add("Signal: TCP-up/TLS-down cycles ($($summary.tls.tcpUpTlsDownCycles)) suggest TLS interception/certificate/time issues.")
        }
        if ([int]$summary.pcLink.icmpDownTcpUpCycles -gt 0) {
            $lines.Add("Signal: ICMP-down while TCP-up cycles ($($summary.pcLink.icmpDownTcpUpCycles)) indicate protocol-specific filtering/de-prioritization.")
        }
        if ([int]$summary.pcLink.icmpUpTcpDownCycles -gt 0) {
            $lines.Add("Signal: TCP failures while ICMP survives ($($summary.pcLink.icmpUpTcpDownCycles)) indicate app-layer path/port filtering risk.")
        }
        if ($summary.configAudit.lastCodes -and $summary.configAudit.lastCodes.Count -gt 0) {
            $lines.Add("Config audit latest codes: " + (($summary.configAudit.lastCodes | Where-Object { $_ }) -join ", "))
        }
        if ($summary.cableHints.lastCodes -and $summary.cableHints.lastCodes.Count -gt 0) {
            $lines.Add("Cable/NIC latest hints: " + (($summary.cableHints.lastCodes | Where-Object { $_ }) -join ", "))
        }
        $lines.Add("Committed cycles: $($summary.cycles.committed) | Attempted cycles: $($summary.cycles.attempted)")
        $lines.Add("Exit code: $ExitCode")
        return ($lines -join [Environment]::NewLine)
    } catch {
        return "Quick analysis failed: $($_.Exception.Message)`r`nSummary path: $summaryPath"
    }
}

function Get-NetworkDiagGuiStateSnapshot {
    try {
        return Get-NetworkDiagGuiStateFromControls -Controls $controls -Limits $limits
    } catch {
        return $null
    }
}

function Update-NetworkDiagGuiActionButtons {
    $isRunning = ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited)
    $controls.RunNormal.IsEnabled = (-not $isRunning) -and (-not $script:ValidationHasErrors)
    $controls.RunAdmin.IsEnabled = (-not $isRunning) -and (-not $script:ValidationHasErrors)
    $controls.StopRun.IsEnabled = $isRunning
}

function Set-NetworkDiagGuiRunState {
    param(
        [string]$State,
        [string]$Message = ""
    )
    $script:RunState = $State
    $status = if ($Message) { "${State}: $Message" } else { $State }
    $window.Dispatcher.Invoke([Action]{
        $controls.StatusText.Text = $status
    })
    Update-NetworkDiagGuiActionButtons
}

function Refresh-NetworkDiagGuiRecentRuns {
    $controls.RecentRunsList.Items.Clear()
    foreach ($item in $script:RecentRuns) {
        $exitCodeLabel = if ($null -eq $item.ExitCode) { "running" } else { "exit=$($item.ExitCode)" }
        $display = "{0}  ({1})  {2}" -f $item.StartedAt, $exitCodeLabel, $item.LauncherRunRoot
        [void]$controls.RecentRunsList.Items.Add($display)
    }
}

function Add-NetworkDiagGuiRecentRun {
    param([hashtable]$Item)
    $script:RecentRuns.Insert(0, $Item)
    while ($script:RecentRuns.Count -gt 15) {
        $script:RecentRuns.RemoveAt($script:RecentRuns.Count - 1)
    }
    Refresh-NetworkDiagGuiRecentRuns
}

function Get-NetworkDiagGuiSelectedRecentRun {
    $idx = $controls.RecentRunsList.SelectedIndex
    if ($idx -lt 0 -or $idx -ge $script:RecentRuns.Count) { return $null }
    return $script:RecentRuns[$idx]
}

function Invoke-NetworkDiagGuiValidation {
    $state = $null
    try {
        $state = Get-NetworkDiagGuiStateFromControls -Controls $controls -Limits $limits
    } catch {
        $script:ValidationHasErrors = $true
        $controls.ValidationText.Foreground = "DarkRed"
        $controls.ValidationText.Text = "Validation: $($_.Exception.Message)"
        Update-NetworkDiagGuiActionButtons
        return
    }

    $validation = Test-NetworkDiagGuiState -State $state -Limits $limits
    if ($validation.Errors.Count -gt 0) {
        $script:ValidationHasErrors = $true
        $controls.ValidationText.Foreground = "DarkRed"
        $controls.ValidationText.Text = "Validation errors: " + ($validation.Errors -join " | ")
    } elseif ($validation.Warnings.Count -gt 0) {
        $script:ValidationHasErrors = $false
        $controls.ValidationText.Foreground = "DarkGoldenrod"
        $controls.ValidationText.Text = "Validation warnings: " + ($validation.Warnings -join " | ")
    } else {
        $script:ValidationHasErrors = $false
        $controls.ValidationText.Foreground = "DarkOliveGreen"
        $controls.ValidationText.Text = "Validation: ready to run."
    }
    Update-NetworkDiagGuiActionButtons
}

function Append-NetworkDiagGuiLiveLog {
    param([string]$Line)
    $window.Dispatcher.Invoke([Action]{
        $controls.LiveLog.AppendText($Line + [Environment]::NewLine)
        $controls.LiveLog.ScrollToEnd()
    })
}

function Set-NetworkDiagGuiStatus {
    param([string]$Text)
    $window.Dispatcher.Invoke([Action]{ $controls.StatusText.Text = $Text })
}

function Update-NetworkDiagDependentControls {
    $burstEnabled = [bool]$controls.BurstOnFault.IsChecked
    foreach ($name in @("BurstIntervalSeconds","BurstCycles","MaxBurstSeconds")) {
        $controls[$name].IsEnabled = $burstEnabled
    }
    $dnsEnabled = -not [bool]$controls.SkipDnsProbe.IsChecked
    $controls.DnsProbeName.IsEnabled = $dnsEnabled
    $ispEnabled = -not [bool]$controls.SkipIspEvidencePacket.IsChecked
    if (-not $ispEnabled) { $controls.IspEvidenceZip.IsChecked = $false }
    $controls.IspEvidenceZip.IsEnabled = $ispEnabled
}
Update-NetworkDiagDependentControls
$controls.BurstOnFault.Add_Click({ Update-NetworkDiagDependentControls })
$controls.SkipDnsProbe.Add_Click({ Update-NetworkDiagDependentControls })
$controls.SkipIspEvidencePacket.Add_Click({ Update-NetworkDiagDependentControls })

function Stop-NetworkDiagGuiRun {
    if (-not $script:CurrentProcess -or $script:CurrentProcess.HasExited) {
        Set-NetworkDiagGuiRunState -State "Idle" -Message "No active run."
        return
    }
    $script:StopRequested = $true
    Set-NetworkDiagGuiRunState -State "Stopping" -Message "Stopping active process..."
    try {
        $script:CurrentProcess.Kill()
    } catch {
        Set-NetworkDiagGuiRunState -State "Failed" -Message ("Stop failed: " + $_.Exception.Message)
    }
}

$controls.BrowseOutputRoot.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select the output root for launcher runs"
    $dialog.SelectedPath = $controls.OutputRoot.Text
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $controls.OutputRoot.Text = $dialog.SelectedPath
    }
    Invoke-NetworkDiagGuiValidation
})

$controls.ApplyPreset.Add_Click({
    $selected = [string]$controls.PresetSelector.SelectedItem
    if (-not $selected -or -not $script:PresetMap.ContainsKey($selected)) { return }
    $preset = $script:PresetMap[$selected]
    Set-NetworkDiagGuiControlState -Controls $controls -State $preset
    Update-NetworkDiagDependentControls
    Invoke-NetworkDiagGuiValidation
    Set-NetworkDiagGuiRunState -State "Idle" -Message "Preset applied: $selected"
})

$controls.SaveProfile.Add_Click({
    $state = Get-NetworkDiagGuiStateSnapshot
    if (-not $state) {
        [System.Windows.MessageBox]::Show("Cannot save profile: current form has invalid values.", "Save profile", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = "JSON files (*.json)|*.json|All files (*.*)|*.*"
    $dialog.FileName = "networkdiag_profile.json"
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        [System.IO.File]::WriteAllText($dialog.FileName, ($state | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding $false))
        Set-NetworkDiagGuiRunState -State "Idle" -Message "Profile saved: $($dialog.FileName)"
    }
})

$controls.LoadProfile.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "JSON files (*.json)|*.json|All files (*.*)|*.*"
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $loaded = Get-Content -LiteralPath $dialog.FileName -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            $merged = New-NetworkDiagGuiDefaultState
            foreach ($k in $loaded.Keys) { $merged[$k] = $loaded[$k] }
            Set-NetworkDiagGuiControlState -Controls $controls -State $merged
            Update-NetworkDiagDependentControls
            Invoke-NetworkDiagGuiValidation
            Set-NetworkDiagGuiRunState -State "Idle" -Message "Profile loaded: $($dialog.FileName)"
        } catch {
            [System.Windows.MessageBox]::Show("Failed to load profile: $($_.Exception.Message)", "Load profile", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        }
    }
})

function Start-NetworkDiagGuiRun {
    param([switch]$PreferAdmin)
    if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
        [System.Windows.MessageBox]::Show("A run is already active. Wait for it to finish.", "Run in progress", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }

    Reset-NetworkDiagGuiLiveHealth
    Set-NetworkDiagGuiQuickAnalysisText -Text "Quick analysis will appear after the run completes."
    Reset-NetworkDiagGuiIncidentInsights
    Set-NetworkDiagGuiRunState -State "Validating" -Message "Checking inputs..."
    $state = $null
    try {
        $state = Get-NetworkDiagGuiStateFromControls -Controls $controls -Limits $limits
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Invalid input", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        return
    }
    $validation = Test-NetworkDiagGuiState -State $state -Limits $limits
    if ($validation.Errors.Count -gt 0) {
        [System.Windows.MessageBox]::Show(($validation.Errors -join [Environment]::NewLine), "Validation failed", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        Set-NetworkDiagGuiRunState -State "Idle" -Message "Validation failed."
        return
    }
    if ($validation.Warnings.Count -gt 0) {
        Set-NetworkDiagGuiStatus ($validation.Warnings -join " | ")
    } else {
        Set-NetworkDiagGuiStatus "Validation passed."
    }

    if ($PreferAdmin -and -not $script:IsAdminGui) {
        try {
            $cfg = Save-NetworkDiagGuiConfig -State $state
            $args = @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", "`"$PSCommandPath`"",
                "-ElevatedLaunch",
                "-AutoRunElevated",
                "-ConfigPath", "`"$cfg`""
            ) -join " "
            Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $args | Out-Null
            Set-NetworkDiagGuiStatus "Requested admin relaunch. Approve UAC to continue."
            Set-NetworkDiagGuiRunState -State "Idle" -Message "Waiting for elevated relaunch."
            return
        } catch {
            Set-NetworkDiagGuiStatus "Admin relaunch was canceled or failed: $($_.Exception.Message)"
            Set-NetworkDiagGuiRunState -State "Idle" -Message "Admin relaunch canceled or failed."
            return
        }
    }

    $scriptPath = Get-NetworkDiagGuiScriptPath
    if (-not (Test-NetworkDiagGuiCanWriteDirectory -Path $state.OutputRoot)) {
        [System.Windows.MessageBox]::Show("Output root is not writable: $($state.OutputRoot)", "Output folder error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        Set-NetworkDiagGuiRunState -State "Idle" -Message "Output root is not writable."
        return
    }
    $paths = $null
    try {
        $paths = New-NetworkDiagGuiLauncherPaths -BaseRoot $state.OutputRoot
    } catch {
        [System.Windows.MessageBox]::Show("Could not create launcher run folders: $($_.Exception.Message)", "Output folder error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        return
    }

    $state.OutputFolder = $paths.ScriptOutputRoot
    $script:CurrentRunFolder = $paths.LauncherRunRoot
    $script:CurrentLogsFolder = $paths.LogsFolder

    $launcherLogPath = Join-Path $paths.LogsFolder "launcher.log"
    $stdoutPath = Join-Path $paths.LogsFolder "stdout.log"
    $stderrPath = Join-Path $paths.LogsFolder "stderr.log"
    $paramsJsonPath = Join-Path $paths.LogsFolder "launch-config.json"
    $stateJsonPath = Join-Path $paths.LogsFolder "gui-state.json"
    $runnerPath = Join-Path $paths.LogsFolder "invoke-networkdiag.ps1"

    $paramMap = ConvertTo-NetworkDiagGuiParamMap -State $state
    [System.IO.File]::WriteAllText($paramsJsonPath, ($paramMap | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllText($stateJsonPath, ($state | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding $false))
    $runnerScript = @"
`$ErrorActionPreference = "Stop"
`$scriptPath = "$($scriptPath.Replace('"','`"'))"
`$jsonPath = "$($paramsJsonPath.Replace('"','`"'))"
`$json = Get-Content -LiteralPath `$jsonPath -Raw -Encoding UTF8
`$params = ConvertFrom-Json -InputObject `$json -AsHashtable
& `$scriptPath @params
"@
    [System.IO.File]::WriteAllText($runnerPath, $runnerScript, (New-Object System.Text.UTF8Encoding $false))

    Write-NetworkDiagGuiLogLine -Path $launcherLogPath -Text "Starting run. launcherRun=$($paths.LauncherRunRoot)"
    Append-NetworkDiagGuiLiveLog "Launcher run folder: $($paths.LauncherRunRoot)"
    Append-NetworkDiagGuiLiveLog "Logs folder: $($paths.LogsFolder)"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$runnerPath`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $PSScriptRoot

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $p.EnableRaisingEvents = $true

    $outHandler = [System.Diagnostics.DataReceivedEventHandler]{
        param($sender, $e)
        if ($null -eq $e.Data) { return }
        Add-Content -LiteralPath $stdoutPath -Value $e.Data -Encoding UTF8
        Write-NetworkDiagGuiLogLine -Path $launcherLogPath -Text ("OUT " + $e.Data)
        Update-NetworkDiagGuiHealthFromLine -Line $e.Data
        if ($e.Data -match "^Run folder\s*:\s*(.+)$") {
            $script:CurrentRunFolder = $Matches[1].Trim()
            $recent = if ($script:RecentRuns.Count -gt 0) { $script:RecentRuns[0] } else { $null }
            if ($recent -and $recent.LauncherRunRoot -eq $paths.LauncherRunRoot) {
                $recent.ScriptRunFolder = $script:CurrentRunFolder
                Refresh-NetworkDiagGuiRecentRuns
            }
        }
        if ($e.Data -match "^Output root\s*:\s*(.+?)(\s+\(.+\))?$") {
            # keep for traceability only
            Write-NetworkDiagGuiLogLine -Path $launcherLogPath -Text ("Detected output root: " + $Matches[1].Trim())
        }
        Append-NetworkDiagGuiLiveLog $e.Data
    }
    $errHandler = [System.Diagnostics.DataReceivedEventHandler]{
        param($sender, $e)
        if ($null -eq $e.Data) { return }
        Add-Content -LiteralPath $stderrPath -Value $e.Data -Encoding UTF8
        Write-NetworkDiagGuiLogLine -Path $launcherLogPath -Text ("ERR " + $e.Data)
        $script:LiveHealth.LastUpdate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Update-NetworkDiagGuiHealthUi
        Append-NetworkDiagGuiLiveLog ("[stderr] " + $e.Data)
    }
    $exitHandler = [System.EventHandler]{
        param($sender, $e)
        $code = $sender.ExitCode
        $script:CurrentProcess = $null
        Write-NetworkDiagGuiLogLine -Path $launcherLogPath -Text "Process exited with code $code"
        $recent = if ($script:RecentRuns.Count -gt 0) { $script:RecentRuns[0] } else { $null }
        if ($recent -and $recent.LauncherRunRoot -eq $paths.LauncherRunRoot) {
            $recent.ExitCode = $code
            Refresh-NetworkDiagGuiRecentRuns
        }
        $analysisRunFolder = ""
        if ($recent -and $recent.ScriptRunFolder) {
            $analysisRunFolder = [string]$recent.ScriptRunFolder
        } elseif ($script:CurrentRunFolder) {
            $analysisRunFolder = [string]$script:CurrentRunFolder
        }
        Set-NetworkDiagGuiQuickAnalysisText -Text (Build-NetworkDiagGuiQuickAnalysis -RunFolder $analysisRunFolder -ExitCode $code)
        Update-NetworkDiagGuiIncidentInsightsFromRunFolder -RunFolder $analysisRunFolder
        if ($script:StopRequested) {
            Set-NetworkDiagGuiRunState -State "Completed" -Message "Run stopped by user. Exit code: $code"
        } elseif ($code -eq 0) {
            Set-NetworkDiagGuiRunState -State "Completed" -Message "Run finished. Exit code: 0"
        } else {
            Set-NetworkDiagGuiRunState -State "Failed" -Message "Run finished with exit code: $code"
        }
        $script:StopRequested = $false
        Set-NetworkDiagGuiStatus "Run finished. Exit code: $code. Logs: $script:CurrentLogsFolder"
        Append-NetworkDiagGuiLiveLog "Run complete. Exit code: $code"
    }

    $p.add_OutputDataReceived($outHandler)
    $p.add_ErrorDataReceived($errHandler)
    $p.add_Exited($exitHandler)

    $null = $p.Start()
    $p.BeginOutputReadLine()
    $p.BeginErrorReadLine()
    $script:CurrentProcess = $p
    Add-NetworkDiagGuiRecentRun -Item @{
        StartedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        LauncherRunRoot = $paths.LauncherRunRoot
        LogsFolder = $paths.LogsFolder
        ScriptRunFolder = ""
        StateConfigPath = $stateJsonPath
        ExitCode = $null
    }
    Set-NetworkDiagGuiRunState -State "Running" -Message "Run started."
}

$controls.RunNormal.Add_Click({ Start-NetworkDiagGuiRun })
$controls.RunAdmin.Add_Click({ Start-NetworkDiagGuiRun -PreferAdmin })
$controls.StopRun.Add_Click({ Stop-NetworkDiagGuiRun })
$controls.OpenCurrentRun.Add_Click({
    if ($script:CurrentRunFolder -and (Test-Path -LiteralPath $script:CurrentRunFolder)) {
        Start-Process -FilePath "explorer.exe" -ArgumentList "`"$script:CurrentRunFolder`""
    } else {
        [System.Windows.MessageBox]::Show("No current run folder is available yet.", "Open run folder", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
    }
})
$controls.OpenCurrentLogs.Add_Click({
    if ($script:CurrentLogsFolder -and (Test-Path -LiteralPath $script:CurrentLogsFolder)) {
        Start-Process -FilePath "explorer.exe" -ArgumentList "`"$script:CurrentLogsFolder`""
    } else {
        [System.Windows.MessageBox]::Show("No current logs folder is available yet.", "Open logs folder", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
    }
})
$controls.ReRunSelected.Add_Click({
    $selected = Get-NetworkDiagGuiSelectedRecentRun
    if (-not $selected) {
        [System.Windows.MessageBox]::Show("Select a recent run first.", "Re-run selected", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        return
    }
    if (-not (Test-Path -LiteralPath $selected.StateConfigPath -PathType Leaf)) {
        [System.Windows.MessageBox]::Show("Saved GUI state file was not found for this run.", "Re-run selected", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }
    try {
        $loaded = Get-Content -LiteralPath $selected.StateConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        $merged = New-NetworkDiagGuiDefaultState
        foreach ($k in $loaded.Keys) { $merged[$k] = $loaded[$k] }
        Set-NetworkDiagGuiControlState -Controls $controls -State $merged
        Update-NetworkDiagDependentControls
        Invoke-NetworkDiagGuiValidation
        Start-NetworkDiagGuiRun
    } catch {
        [System.Windows.MessageBox]::Show("Failed to re-run selected config: $($_.Exception.Message)", "Re-run selected", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    }
})
$controls.OpenSelectedRun.Add_Click({
    $selected = Get-NetworkDiagGuiSelectedRecentRun
    if ($selected -and (Test-Path -LiteralPath $selected.LauncherRunRoot -PathType Container)) {
        Start-Process -FilePath "explorer.exe" -ArgumentList "`"$($selected.LauncherRunRoot)`""
    } else {
        [System.Windows.MessageBox]::Show("Selected run folder is not available.", "Open selected run", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
    }
})
$controls.OpenSelectedLogs.Add_Click({
    $selected = Get-NetworkDiagGuiSelectedRecentRun
    if ($selected -and (Test-Path -LiteralPath $selected.LogsFolder -PathType Container)) {
        Start-Process -FilePath "explorer.exe" -ArgumentList "`"$($selected.LogsFolder)`""
    } else {
        [System.Windows.MessageBox]::Show("Selected logs folder is not available.", "Open selected logs", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
    }
})
$controls.RecentRunsList.Add_SelectionChanged({
    $selected = Get-NetworkDiagGuiSelectedRecentRun
    if ($selected -and $selected.ScriptRunFolder) {
        $code = if ($null -eq $selected.ExitCode) { -999 } else { [int]$selected.ExitCode }
        Set-NetworkDiagGuiQuickAnalysisText -Text (Build-NetworkDiagGuiQuickAnalysis -RunFolder $selected.ScriptRunFolder -ExitCode $code)
        Update-NetworkDiagGuiIncidentInsightsFromRunFolder -RunFolder $selected.ScriptRunFolder
    }
})

foreach ($name in @(
    "DurationMinutes","IntervalSeconds","HeartbeatMinutes","SnapshotMinutes","EventLogLookbackMinutes",
    "OutputRoot","ExternalIcmpHosts","ExternalIcmpLabels","TcpProbeHosts","DnsProbeName","IcmpCountPerTarget",
    "IcmpTimeoutSeconds","DnsTimeoutMs","BurstIntervalSeconds","BurstCycles","MaxBurstSeconds",
    "GwIcmpPolicyConfirmCycles","RoutingRefreshIntervalCycles","PathMtuProbeTarget"
)) {
    $controls[$name].Add_TextChanged({ Invoke-NetworkDiagGuiValidation })
}
foreach ($name in @(
    "RequireEthernet","SkipTcpProbe","DetailLog","LegacyCsvShape","SkipDnsProbe","BurstOnFault",
    "SkipGwIcmpPolicyAdaptation","PinExternalIcmpToResolvedIp","SkipConfigAudit","SkipCableHints",
    "SkipMultiNicCrossCheck","SkipIspEvidencePacket","IspEvidenceZip","SkipWifiSignal",
    "EnableTlsProbe","SkipJsonSummary","SelfTest"
)) {
    $controls[$name].Add_Click({ Invoke-NetworkDiagGuiValidation })
}
$controls.MonitoringMode.Add_SelectionChanged({ Invoke-NetworkDiagGuiValidation })
$controls.ProbeAddressFamily.Add_SelectionChanged({ Invoke-NetworkDiagGuiValidation })

Invoke-NetworkDiagGuiValidation
Reset-NetworkDiagGuiLiveHealth
Set-NetworkDiagGuiQuickAnalysisText -Text "Quick analysis will appear after a run completes."
Reset-NetworkDiagGuiIncidentInsights
Set-NetworkDiagGuiRunState -State "Idle" -Message "Ready."

if ($ElevatedLaunch -and $AutoRunElevated) {
    $window.Add_ContentRendered({
        Set-NetworkDiagGuiStatus "Elevated relaunch complete. Starting run automatically..."
        Start-NetworkDiagGuiRun
    })
}

[void]$window.ShowDialog()
