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
    if ($token -notmatch "^(?<host>[^:]+):(?<port>\d{1,5})$") { return $false }
    $host = [string]$Matches.host
    $port = [int]$Matches.port
    if ($port -lt 1 -or $port -gt 65535) { return $false }
    return (Test-NetworkDiagGuiHostToken -Value $host)
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

    if (-not $State.OutputRoot) {
        $errors.Add("Choose an output folder so reports and logs have a save location.")
    }
    if (@($State.ExternalIcmpHosts).Count -lt 2 -or @($State.ExternalIcmpHosts).Count -gt 6) {
        $errors.Add("Internet check targets need 2 to 6 entries (one host or IP per line).")
    }
    if (@($State.ExternalIcmpLabels).Count -gt 0 -and @($State.ExternalIcmpLabels).Count -ne @($State.ExternalIcmpHosts).Count) {
        $errors.Add("Target labels must be blank or match the number of internet check targets.")
    }
    if (@($State.TcpProbeHosts).Count -gt 0 -and @($State.TcpProbeHosts).Count -ne 2) {
        $errors.Add("TCP probe hosts must be blank or contain exactly 2 entries.")
    }
    if ($State.BurstOnFault -and $State.BurstIntervalSeconds -ge $State.IntervalSeconds) {
        $errors.Add("When burst mode is enabled, burst interval must be shorter than the main interval.")
    }
    if (-not $State.SkipDnsProbe -and -not $State.DnsProbeName) {
        $errors.Add("Enter a DNS name to test, or enable SkipDnsProbe.")
    }
    if ($State.DurationMinutes -gt 10080) {
        $warnings.Add("Duration exceeds 7 days; logs can grow very large.")
    }
    if ($State.DurationMinutes -ge 1440 -and $State.DetailLog) {
        $warnings.Add("DetailLog is enabled for a 24h+ run; launcher logs can become large.")
    }
    if (-not ($Limits.AllowedSets.MonitoringMode -contains $State.MonitoringMode)) {
        $errors.Add("Monitoring mode must be one of: Auto, ShortRun, or LongRun.")
    }
    if (-not ($Limits.AllowedSets.ProbeAddressFamily -contains $State.ProbeAddressFamily)) {
        $errors.Add("ProbeAddressFamily must be IPv4 or IPv6.")
    }
    foreach ($h in @($State.ExternalIcmpHosts)) {
        if (-not (Test-NetworkDiagGuiHostToken -Value $h)) {
            $errors.Add("Internet check target is not a valid host/IP: $h")
        }
    }
    foreach ($h in @($State.TcpProbeHosts)) {
        if (-not (Test-NetworkDiagGuiHostToken -Value $h)) {
            $errors.Add("TCP probe host is not a valid host/IP: $h")
        }
    }
    if ($State.PathMtuProbeTarget -and -not (Test-NetworkDiagGuiHostToken -Value $State.PathMtuProbeTarget)) {
        $errors.Add("Path MTU target must be a valid hostname or IP.")
    }
    if ($State.ContainsKey("EnableUdpProbe") -and [bool]$State.EnableUdpProbe) {
        if (-not (Test-NetworkDiagGuiHostPortToken -Value $State.UdpProbeTarget)) {
            $errors.Add("UDP target must use host:port format and include a valid host/IP and port.")
        }
    }
    if ($State.ContainsKey("EnableLongLivedTcp") -and [bool]$State.EnableLongLivedTcp) {
        if (-not (Test-NetworkDiagGuiHostPortToken -Value $State.LongLivedTcpTarget)) {
            $errors.Add("Long-lived TCP target must use host:port format and include a valid host/IP and port.")
        }
    }
    if ($State.ContainsKey("AutoCaptureOnFault") -and [bool]$State.AutoCaptureOnFault) {
        if (-not ($Limits.AllowedSets.AutoCaptureMethod -contains [string]$State.AutoCaptureMethod)) {
            $errors.Add("AutoCaptureMethod must be one of: pktmon, netshtrace.")
        }
        if (-not [bool]$script:App.Context.IsAdminGui) {
            $warnings.Add("Auto-capture is enabled in non-admin mode; runtime may skip capture due to permissions.")
        }
    }
    return @{ Errors = @($errors); Warnings = @($warnings) }
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
        $controls.AtGlanceSummary.Text = "View=$mode | Time=$($state.DurationMinutes)m | CheckEvery=$($state.IntervalSeconds)s | Monitoring=$($state.MonitoringMode) | Checks=$($probeSet -join '+') | Output=$outDisp"
    }
    Update-NetworkDiagGuiActionButtons
}
