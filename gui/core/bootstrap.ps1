function Start-NetworkDiagGuiApp {
    param(
        [switch]$ElevatedLaunch,
        [string]$ConfigPath = "",
        [switch]$AutoRunElevated
    )

    [xml]$xamlXml = Get-NetworkDiagGuiLayoutXml
    $reader = New-Object System.Xml.XmlNodeReader $xamlXml
    $window = [Windows.Markup.XamlReader]::Load($reader)

    $controls = @{}
    foreach ($n in (Get-NetworkDiagGuiControlNames)) { $controls[$n] = $window.FindName($n) }

    $limits = Get-NetworkDiagGuiLimitations
    $defaultState = New-NetworkDiagGuiDefaultState
    if (-not $defaultState.OutputRoot) { $defaultState.OutputRoot = Get-NetworkDiagGuiDefaultOutputRoot }
    $presetMap = Get-NetworkDiagGuiPresets -BaseState $defaultState
    $goalProfiles = Get-NetworkDiagGuiGoalProfiles -BaseState $defaultState

    if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        try {
            $defaultState = Read-NetworkDiagGuiStateDocument -Path $ConfigPath
        } catch {
            Write-Warning ("Failed to load GUI config from '" + $ConfigPath + "': " + $_.Exception.Message)
        }
    }
    Set-NetworkDiagGuiControlState -Controls $controls -State $defaultState
    $controls.PresetSelector.Items.Clear()
    foreach ($presetName in $presetMap.Keys) {
        [void]$controls.PresetSelector.Items.Add($presetName)
    }
    if ($controls.PresetSelector.Items.Count -gt 0) { $controls.PresetSelector.SelectedIndex = 0 }

    $isAdmin = Test-NetworkDiagGuiIsAdmin
    $controls.AdminBanner.Text = if ($isAdmin) {
        "Administrator mode: full diagnostics available."
    } else {
        "Standard mode: some diagnostics may be limited. Use 'Run full diagnostic as administrator' for complete capability."
    }
    $controls.RunabilityHint.Text = "Easy path: use this window and click Run. Power users can also run the same test directly from PowerShell."
    if ($controls.ContainsKey("RestartAsAdmin") -and $null -ne $controls.RestartAsAdmin) {
        $controls.RestartAsAdmin.Visibility = [System.Windows.Visibility]::Collapsed
    }
    foreach ($cbName in @("SkipMultiNicCrossCheck","SkipConfigAudit","SkipCableHints","RequireEthernet","IspEvidenceZip")) {
        $controls[$cbName].ToolTip = ($limits.AdminCaveats -join " ")
    }
    $tooltips = @{
        UserExperienceMode = "Beginner keeps the screen focused on core settings. Expert shows every advanced control."
        GoalQuick = "Use a short 2-5 minute baseline check."
        GoalWifi = "Use a profile tuned for Wi-Fi/router instability patterns."
        GoalDns = "Use a DNS-focused profile."
        GoalIsp = "Use a longer external monitoring profile for ISP issues."
        GoalVpn = "Use route/MTU-focused settings for VPN path problems."
        GoalCustom = "Keep advanced custom controls in charge."
        CurrentGoalText = "Shows the currently selected diagnostic goal."
        DurationMinutes = "How long to run the test, in minutes."
        IntervalSeconds = "How often each network check cycle runs."
        MonitoringMode = "Auto chooses defaults by run length; ShortRun and LongRun force a specific behavior profile."
        HeartbeatMinutes = "Heartbeat cadence; use -1 for script default."
        SnapshotMinutes = "Partial snapshot cadence; use -1 for script default."
        EventLogLookbackMinutes = "Event lookback window; use -1 for script default."
        ProbeAddressFamily = "Select IPv4 or IPv6 probing mode."
        OutputRoot = "Folder where run reports, logs, and exports are saved."
        BrowseOutputRoot = "Pick output root folder."
        ExternalIcmpHosts = "Internet targets to check (2 to 6). Use one hostname or IP per line."
        ExternalIcmpLabels = "Optional labels matching host count."
        TcpProbeHosts = "Optional two hosts for TCP probe. Leave empty to auto-pick."
        DnsProbeName = "Domain name to resolve during each cycle when DNS checks are on."
        IcmpCountPerTarget = "ICMP attempts per target each cycle."
        IcmpTimeoutSeconds = "Timeout per ICMP attempt."
        DnsTimeoutMs = "DNS resolution timeout cap in milliseconds."
        BurstOnFault = "Use short interval cycles after a non-OK cycle."
        BurstIntervalSeconds = "Short interval used during burst mode."
        BurstCycles = "Number of short cycles during each burst."
        MaxBurstSeconds = "Max wall-clock burst duration per episode."
        GwIcmpPolicyConfirmCycles = "Cycles needed before classifying GW ICMP policy behavior."
        RoutingRefreshIntervalCycles = "Re-resolve routes every N cycles (0 disables)."
        PathMtuProbeTarget = "Optional host/IP for path MTU probing during audits."
        RequireEthernet = "Stop startup if the active route is not Ethernet-based."
        SkipTcpProbe = "Disable TCP/443 probe checks."
        DetailLog = "Write a detailed narrative log file per run."
        LegacyCsvShape = "Use legacy CSV columns for compatibility."
        SkipDnsProbe = "Disable DNS probe checks."
        SkipGwIcmpPolicyAdaptation = "Disable automatic gateway ICMP policy adaptation."
        PinExternalIcmpToResolvedIp = "Probe resolved IP instead of hostname each cycle."
        SkipConfigAudit = "Disable config-audit checks on non-OK cycles."
        SkipCableHints = "Disable cable/NIC hint checks."
        SkipMultiNicCrossCheck = "Disable alternate-adapter cross-check on faults."
        SkipIspEvidencePacket = "Disable end-of-run ISP evidence bundle."
        IspEvidenceZip = "Zip ISP evidence bundle after generation."
        SkipWifiSignal = "Disable Wi-Fi signal snapshot checks."
        EnableTlsProbe = "Add TLS handshake checks on top of TCP probes."
        SkipJsonSummary = "Disable summary JSON output."
        SelfTest = "Run preflight self-test and exit."
        EnableUdpProbe = "Enable high-frequency UDP probe for short drop detection."
        UdpProbeTarget = "UDP destination in host:port format."
        UdpProbeRateHz = "UDP send rate in packets per second."
        UdpProbePayloadBytes = "UDP payload size in bytes."
        EnableLongLivedTcp = "Keep a long-lived TCP session and detect resets."
        LongLivedTcpTarget = "Long-lived TCP target in host:port format."
        LongLivedTcpReconnectBackoffSeconds = "Reconnect wait after long-lived TCP resets."
        PerProbeTimestamps = "Include per-probe start timestamps in outputs."
        AutoCaptureOnFault = "Auto-start bounded capture on first non-OK cycle."
        AutoCaptureMethod = "Capture backend (pktmon or netshtrace)."
        AutoCaptureSeconds = "Duration per auto-capture event."
        AutoCaptureMax = "Maximum number of auto-capture events."
        PresetSelector = "Select a preconfigured profile."
        ApplyPreset = "Apply selected preset to all controls."
        SaveProfile = "Save current settings to JSON profile."
        LoadProfile = "Load settings from JSON profile."
        ReRunSelected = "Load settings from selected recent run and start a new run."
        RecentRunsList = "Recent launcher runs in this session."
        OpenSelectedRun = "Open selected run folder in Explorer."
        OpenSelectedLogs = "Open selected logs folder in Explorer."
        RunNormal = "Run basic diagnostic test with current permissions."
        RunAdmin = "Run full diagnostic as Administrator (UAC prompt if needed)."
        PreviewCliCommand = "Preview the PowerShell command generated from current settings."
        RestartAsAdmin = "Save current settings and reopen this launcher with Administrator rights (UAC). Does not start a run automatically."
        StopRun = "Stop the currently running diagnostic process."
        OpenCurrentRun = "Open the active run folder."
        OpenCurrentLogs = "Open the active logs folder."
        ExportCliCommand = "Copy a PowerShell command equivalent to current GUI selections."
        CopyArtifactPaths = "Copy run artifact paths (logs, config, gui-state, PID)."
        OpenLaunchConfig = "Open the current launch-config.json file location."
        OpenGuiState = "Open the current gui-state.json file location."
        LiveLogFilter = "Filter lines shown in the live log view."
        LiveLogStderrOnly = "Show only stderr lines in the live log view."
        RecentRunsFilter = "Search/filter recent runs by timestamp, exit code, or path."
        RuntimeRulesText = "Script-side runtime constraints shown for reference."
        OutputFallbackText = "Output folder fallback order used by the script."
        AtGlanceSummary = "Compact summary of key run settings and mode."
        SupportBundleButton = "Create a ZIP support bundle from the latest run artifacts."
        CopyRunSummaryButton = "Copy a human-readable summary to clipboard."
        CompareRunA = "Set selected run as comparison A."
        CompareRunB = "Set selected run as comparison B."
        CompareRuns = "Compare run A and run B."
        RunComparisonText = "Comparison output across selected runs."
        SetupValidationStatus = "Current run-readiness status."
    }
    foreach ($name in $tooltips.Keys) {
        if ($controls.ContainsKey($name) -and $null -ne $controls[$name]) {
            $controls[$name].ToolTip = [string]$tooltips[$name]
        }
    }
    if ($controls.ContainsKey("SupportBundleButton")) {
        $controls.SupportBundleButton.ToolTip = "Available after at least one run has produced artifacts."
    }

    $script:App = @{
        Ui = @{
            Window = $window
            Controls = $controls
        }
        Config = @{
            Limits = $limits
            PresetMap = $presetMap
            GoalProfiles = $goalProfiles
            OptionHelpMap = $tooltips
        }
        Context = @{
            IsAdminGui = $isAdmin
            CommandPath = if ($script:NetworkDiagGuiEntryPath) { $script:NetworkDiagGuiEntryPath } else { $PSCommandPath }
            ElevatedLaunch = [bool]$ElevatedLaunch
            AutoRunElevated = [bool]$AutoRunElevated
        }
        Run = @{
            CurrentRunFolder = ""
            CurrentLogsFolder = ""
            CurrentLaunchConfigPath = ""
            CurrentGuiStatePath = ""
            CurrentProcess = $null
            ValidationHasErrors = $false
            State = "Idle"
            StopRequested = $false
            RecentRuns = [System.Collections.Generic.List[hashtable]]::new()
            TransitionHistory = [System.Collections.Generic.List[string]]::new()
        }
        Health = @{}
        Hooks = New-NetworkDiagGuiHooks
        History = @{
            CompareA = $null
            CompareB = $null
        }
    }

    Register-NetworkDiagGuiEvents
    Load-NetworkDiagGuiRecentRuns
    Refresh-NetworkDiagGuiRecentRuns

    $controls.RuntimeRulesText.Text = (($limits.RuntimeRules | ForEach-Object { " - $_" }) -join [Environment]::NewLine)
    $controls.OutputFallbackText.Text = (($limits.OutputFallback | ForEach-Object { " - $_" }) -join [Environment]::NewLine)
    $controls.QuickHelpText.Text = "Beginner mode: choose a goal, review summary, then click Run basic test. Use Run full diagnostic as administrator for deeper checks."
    $controls.UserExperienceMode.SelectedIndex = 0
    $controls.OptionHelpText.Text = "Tip: hover over any setting or tab into it to see a plain-language explanation."
    $controls.AtGlanceSummary.Text = "View=Beginner | Preset=default | Ready"
    if ($controls.ContainsKey("CurrentGoalText")) {
        $controls.CurrentGoalText.Text = "Goal: Quick internet sanity check"
    }
    if ($controls.ContainsKey("RunComparisonText")) {
        $controls.RunComparisonText.Text = "Select two runs and click Compare selected runs."
    }

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
}
