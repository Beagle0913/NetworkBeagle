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

function Test-NetworkDiagGuiHostPortToken {
    param([string]$Value)
    if (-not $Value) { return $false }
    $token = $Value.Trim()
    if (-not $token) { return $false }
    $hostToken = ""
    $port = 0
    if ($token -match "^\[(?<host>[^\]]+)\]:(?<port>\d{1,5})$") {
        $hostToken = [string]$Matches.host
        $port = [int]$Matches.port
    } elseif ($token -match "^(?<host>[^:]+):(?<port>\d{1,5})$") {
        $hostToken = [string]$Matches.host
        $port = [int]$Matches.port
    } else {
        return $false
    }
    if ($port -lt 1 -or $port -gt 65535) { return $false }
    return (Test-NetworkDiagGuiHostToken -Value $hostToken)
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

function Test-NetworkDiagGuiState {
    param(
        [hashtable]$State,
        [hashtable]$Limits
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $issues = [System.Collections.Generic.List[hashtable]]::new()
    $addIssue = {
        param(
            [string]$Id,
            [string]$Severity,
            [string]$Message,
            [string]$Field,
            [object[]]$Fixes = @()
        )
        $issue = @{
            Id = $Id
            Severity = $Severity
            Message = $Message
            Field = $Field
            Fixes = @($Fixes)
        }
        $issues.Add($issue)
        if ($Severity -eq "Error") { $errors.Add($Message) } else { $warnings.Add($Message) }
    }

    if (-not $State.OutputRoot) {
        & $addIssue "OutputRootRequired" "Error" "Choose an output folder so reports and logs have a save location." "OutputRoot"
    }
    if (@($State.ExternalIcmpHosts).Count -lt 2 -or @($State.ExternalIcmpHosts).Count -gt 6) {
        & $addIssue "ExternalHostsCount" "Error" "Internet check targets need 2 to 6 entries (one host or IP per line)." "ExternalIcmpHosts"
    }
    if (@($State.ExternalIcmpLabels).Count -gt 0 -and @($State.ExternalIcmpLabels).Count -ne @($State.ExternalIcmpHosts).Count) {
        & $addIssue "ExternalLabelsCount" "Error" "Target labels must be blank or match the number of internet check targets." "ExternalIcmpLabels"
    }
    if (@($State.TcpProbeHosts).Count -gt 0 -and @($State.TcpProbeHosts).Count -ne 2) {
        & $addIssue "TcpHostsCount" "Error" "TCP probe hosts must be blank or contain exactly 2 entries." "TcpProbeHosts"
    }
    if ($State.BurstOnFault -and $State.BurstIntervalSeconds -ge $State.IntervalSeconds) {
        & $addIssue "BurstIntervalRule" "Error" "When burst mode is enabled, burst interval must be shorter than the main interval." "BurstIntervalSeconds" @(
            @{ Label = "Auto-fix timing"; Action = "AutoFixBurstInterval" }
        )
    }
    if (-not $State.SkipDnsProbe -and -not $State.DnsProbeName) {
        & $addIssue "DnsNameRequired" "Error" "DNS name is required because DNS checks are enabled." "DnsProbeName" @(
            @{ Label = "Use default"; Action = "SetDnsDefault" },
            @{ Label = "Disable DNS check"; Action = "DisableDnsCheck" }
        )
    }
    if ($State.DurationMinutes -gt 10080) {
        & $addIssue "DurationHuge" "Warning" "Duration exceeds 7 days; logs can grow very large." "DurationMinutes"
    }
    if ($State.DurationMinutes -ge 1440 -and $State.DetailLog) {
        & $addIssue "DurationDetailLarge" "Warning" "DetailLog is enabled for a 24h+ run; launcher logs can become large." "DetailLog"
    }
    if (-not ($Limits.AllowedSets.MonitoringMode -contains $State.MonitoringMode)) {
        & $addIssue "MonitoringModeInvalid" "Error" "Monitoring mode must be one of: Auto, ShortRun, or LongRun." "MonitoringMode"
    }
    if (-not ($Limits.AllowedSets.ProbeAddressFamily -contains $State.ProbeAddressFamily)) {
        & $addIssue "ProbeFamilyInvalid" "Error" "ProbeAddressFamily must be IPv4 or IPv6." "ProbeAddressFamily"
    }
    foreach ($h in @($State.ExternalIcmpHosts)) {
        if (-not (Test-NetworkDiagGuiHostToken -Value $h)) {
            & $addIssue "ExternalHostInvalid" "Error" "Internet check target is not a valid host/IP: $h" "ExternalIcmpHosts"
        }
    }
    foreach ($h in @($State.TcpProbeHosts)) {
        if (-not (Test-NetworkDiagGuiHostToken -Value $h)) {
            & $addIssue "TcpHostInvalid" "Error" "TCP probe host is not a valid host/IP: $h" "TcpProbeHosts"
        }
    }
    if ($State.PathMtuProbeTarget -and -not (Test-NetworkDiagGuiHostToken -Value $State.PathMtuProbeTarget)) {
        & $addIssue "PathMtuInvalid" "Error" "Path MTU target must be a valid hostname or IP." "PathMtuProbeTarget"
    }
    if ($State.ContainsKey("EnableUdpProbe") -and [bool]$State.EnableUdpProbe) {
        if (-not (Test-NetworkDiagGuiHostPortToken -Value $State.UdpProbeTarget)) {
            & $addIssue "UdpTargetInvalid" "Error" "UDP target must use host:port format and include a valid host/IP and port." "UdpProbeTarget"
        }
    }
    if ($State.ContainsKey("EnableLongLivedTcp") -and [bool]$State.EnableLongLivedTcp) {
        if (-not (Test-NetworkDiagGuiHostPortToken -Value $State.LongLivedTcpTarget)) {
            & $addIssue "LongTcpTargetInvalid" "Error" "Long-lived TCP target must use host:port format and include a valid host/IP and port." "LongLivedTcpTarget"
        }
    }
    if ($State.ContainsKey("AutoCaptureOnFault") -and [bool]$State.AutoCaptureOnFault) {
        if (-not ($Limits.AllowedSets.AutoCaptureMethod -contains [string]$State.AutoCaptureMethod)) {
            & $addIssue "AutoCaptureMethodInvalid" "Error" "AutoCaptureMethod must be one of: pktmon, netshtrace." "AutoCaptureMethod"
        }
        if (-not [bool]$script:App.Context.IsAdminGui) {
            & $addIssue "AutoCaptureAdminWarning" "Warning" "Auto-capture is enabled in non-admin mode; runtime may skip capture due to permissions." "AutoCaptureOnFault"
        }
    }
    return @{ Errors = @($errors); Warnings = @($warnings); Issues = @($issues) }
}

function Invoke-NetworkDiagGuiValidationFix {
    param([Parameter(Mandatory = $true)][string]$Action)
    $controls = $script:App.Ui.Controls
    switch ($Action) {
        "SetDnsDefault" { $controls.DnsProbeName.Text = "cloudflare.com" }
        "DisableDnsCheck" { $controls.SkipDnsProbe.IsChecked = $true }
        "AutoFixBurstInterval" {
            $interval = 3
            [void][int]::TryParse([string]$controls.IntervalSeconds.Text, [ref]$interval)
            $controls.BurstIntervalSeconds.Text = [string][math]::Max(1, $interval - 1)
        }
    }
    Update-NetworkDiagDependentControls
    Invoke-NetworkDiagGuiValidation
}

function Update-NetworkDiagDependentControls {
    $controls = $script:App.Ui.Controls
    $burstEnabled = [bool]$controls.BurstOnFault.IsChecked
    foreach ($name in @("BurstIntervalSeconds","BurstCycles","MaxBurstSeconds")) {
        $controls[$name].IsEnabled = $burstEnabled
    }
    $dnsEnabled = -not [bool]$controls.SkipDnsProbe.IsChecked
    $controls.DnsProbeName.IsEnabled = $dnsEnabled
    $ispEnabled = -not [bool]$controls.SkipIspEvidencePacket.IsChecked
    if (-not $ispEnabled) { $controls.IspEvidenceZip.IsChecked = $false }
    $controls.IspEvidenceZip.IsEnabled = $ispEnabled

    $udpEnabled = [bool]$controls.EnableUdpProbe.IsChecked
    foreach ($name in @("UdpProbeTarget","UdpProbeRateHz","UdpProbePayloadBytes")) {
        $controls[$name].IsEnabled = $udpEnabled
    }

    $tcpSessEnabled = [bool]$controls.EnableLongLivedTcp.IsChecked
    foreach ($name in @("LongLivedTcpTarget","LongLivedTcpReconnectBackoffSeconds")) {
        $controls[$name].IsEnabled = $tcpSessEnabled
    }

    $captureEnabled = [bool]$controls.AutoCaptureOnFault.IsChecked
    foreach ($name in @("AutoCaptureMethod","AutoCaptureSeconds","AutoCaptureMax")) {
        $controls[$name].IsEnabled = $captureEnabled
    }
}

function Invoke-NetworkDiagGuiValidation {
    $controls = $script:App.Ui.Controls
    $state = $null
    try {
        $state = Get-NetworkDiagGuiStateFromControls -Controls $controls -Limits $script:App.Config.Limits
    } catch {
        $script:App.Run.ValidationHasErrors = $true
        $controls.ValidationText.Foreground = "DarkRed"
        $controls.ValidationText.Text = "Please fix this setting: $($_.Exception.Message)"
        Update-NetworkDiagGuiActionButtons
        return
    }

    $validation = Test-NetworkDiagGuiState -State $state -Limits $script:App.Config.Limits
    if ($validation.Errors.Count -gt 0) {
        $script:App.Run.ValidationHasErrors = $true
        $controls.ValidationText.Foreground = "DarkRed"
        $controls.ValidationText.Text = "Please fix before running: " + ($validation.Errors -join " | ")
    } elseif ($validation.Warnings.Count -gt 0) {
        $script:App.Run.ValidationHasErrors = $false
        $controls.ValidationText.Foreground = "DarkGoldenrod"
        $controls.ValidationText.Text = "Heads up: " + ($validation.Warnings -join " | ")
    } else {
        $script:App.Run.ValidationHasErrors = $false
        $controls.ValidationText.Foreground = "DarkOliveGreen"
        $controls.ValidationText.Text = "Looks good. Ready to run."
    }
    if ($controls.ContainsKey("AtGlanceSummary")) {
        $mode = if ($controls.ContainsKey("UserExperienceMode") -and $controls.UserExperienceMode.SelectedItem) { [string]$controls.UserExperienceMode.SelectedItem.Content } else { "n/a" }
        $goal = if ($controls.ContainsKey("CurrentGoalText")) { [string]$controls.CurrentGoalText.Text } else { "Goal: n/a" }
        $probeSet = @("ICMP")
        if (-not $state.SkipDnsProbe) { $probeSet += "DNS" }
        if (-not $state.SkipTcpProbe) { $probeSet += "TCP" }
        if ($state.EnableTlsProbe) { $probeSet += "TLS" }
        if ($state.EnableUdpProbe) { $probeSet += "UDP" }
        if ($state.EnableLongLivedTcp) { $probeSet += "LongTCP" }
        $outRoot = [string]$state.OutputRoot
        $outDisp = $outRoot
        if ($outRoot.Length -gt 72) {
            $tail = 69
            $start = [math]::Max(0, $outRoot.Length - $tail)
            $outDisp = "..." + $outRoot.Substring($start)
        }
        $priv = if ([bool]$script:App.Context.IsAdminGui) { "Administrator mode" } else { "Standard mode (limited diagnostics possible)" }
        $artifacts = "report + csv + logs + launch-config"
        $controls.AtGlanceSummary.Text = "$goal`nMode: $mode`nDuration: $($state.DurationMinutes) min | Interval: $($state.IntervalSeconds) sec | Monitoring: $($state.MonitoringMode)`nChecks: $($probeSet -join ', ')`nOutput: $outDisp`nPrivilege: $priv`nEstimated artifacts: $artifacts"
    }
    if ($controls.ContainsKey("SetupValidationStatus")) {
        if ($validation.Errors.Count -gt 0) {
            $controls.SetupValidationStatus.Text = "Cannot start test: " + (($validation.Issues | Where-Object { $_.Severity -eq "Error" } | ForEach-Object { $_.Message }) -join " | ")
            $controls.SetupValidationStatus.Foreground = "DarkRed"
        } elseif ($validation.Warnings.Count -gt 0) {
            $controls.SetupValidationStatus.Text = "Ready with warnings: " + (($validation.Issues | Where-Object { $_.Severity -eq "Warning" } | ForEach-Object { $_.Message }) -join " | ")
            $controls.SetupValidationStatus.Foreground = "DarkGoldenrod"
        } else {
            $controls.SetupValidationStatus.Text = "Ready to run."
            $controls.SetupValidationStatus.Foreground = "DarkGreen"
        }
    }
    if ($controls.ContainsKey("FixUseDefaultDns")) {
        $dnsReq = @($validation.Issues | Where-Object { $_.Id -eq "DnsNameRequired" }).Count -gt 0
        $burstReq = @($validation.Issues | Where-Object { $_.Id -eq "BurstIntervalRule" }).Count -gt 0
        $controls.FixUseDefaultDns.Visibility = if ($dnsReq) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
        $controls.FixDisableDns.Visibility = if ($dnsReq) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
        $controls.FixAutoTiming.Visibility = if ($burstReq) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    }
    Update-NetworkDiagGuiActionButtons
}
