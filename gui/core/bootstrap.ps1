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
    if (-not $defaultState.OutputRoot) { $defaultState.OutputRoot = $PSScriptRoot }
    $presetMap = Get-NetworkDiagGuiPresets -BaseState $defaultState

    if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        try {
            $loaded = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
            $defaultState = Merge-NetworkDiagGuiState -Overrides $loaded
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
        "Admin context: elevated. Full capability paths are available."
    } else {
        "Admin context: non-admin. Some features run in degraded/loose mode. Use 'Run Full Capabilities (Admin)' for strict behavior."
    }
    foreach ($cbName in @("SkipMultiNicCrossCheck","SkipConfigAudit","SkipCableHints","RequireEthernet","IspEvidenceZip")) {
        $controls[$cbName].ToolTip = ($limits.AdminCaveats -join " ")
    }
    $tooltips = @{
        DurationMinutes = "Total run duration in minutes."
        IntervalSeconds = "Main cycle interval in seconds."
        MonitoringMode = "Auto picks profile by duration; ShortRun/LongRun forces behavior."
        HeartbeatMinutes = "Heartbeat cadence; use -1 for script default."
        SnapshotMinutes = "Partial snapshot cadence; use -1 for script default."
        EventLogLookbackMinutes = "Event lookback window; use -1 for script default."
        ProbeAddressFamily = "Select IPv4 or IPv6 probing mode."
        OutputRoot = "Base folder where launcher run folders are created."
        BrowseOutputRoot = "Pick output root folder."
        ExternalIcmpHosts = "2 to 6 external hosts/IPs. One per line."
        ExternalIcmpLabels = "Optional labels matching host count."
        TcpProbeHosts = "Optional two hosts for TCP probe. Leave empty to auto-pick."
        DnsProbeName = "DNS name resolved each cycle when DNS probe is enabled."
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
        PresetSelector = "Select a preconfigured profile."
        ApplyPreset = "Apply selected preset to all controls."
        SaveProfile = "Save current settings to JSON profile."
        LoadProfile = "Load settings from JSON profile."
        ReRunSelected = "Load settings from selected recent run and start a new run."
        RecentRunsList = "Recent launcher runs in this session."
        OpenSelectedRun = "Open selected run folder in Explorer."
        OpenSelectedLogs = "Open selected logs folder in Explorer."
        RunNormal = "Start with current permissions."
        RunAdmin = "Relaunch elevated (UAC) for strict/full capabilities."
        StopRun = "Stop the currently running diagnostic process."
        OpenCurrentRun = "Open the active run folder."
        OpenCurrentLogs = "Open the active logs folder."
    }
    foreach ($name in $tooltips.Keys) {
        if ($controls.ContainsKey($name) -and $null -ne $controls[$name]) {
            $controls[$name].ToolTip = [string]$tooltips[$name]
        }
    }

    $script:App = @{
        Ui = @{
            Window = $window
            Controls = $controls
        }
        Config = @{
            Limits = $limits
            PresetMap = $presetMap
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
            CurrentProcess = $null
            ValidationHasErrors = $false
            State = "Idle"
            StopRequested = $false
            RecentRuns = [System.Collections.Generic.List[hashtable]]::new()
        }
        Health = @{}
        Hooks = New-NetworkDiagGuiHooks
    }

    Register-NetworkDiagGuiEvents

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
