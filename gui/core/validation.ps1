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
}

function Invoke-NetworkDiagGuiValidation {
    $controls = $script:App.Ui.Controls
    $state = $null
    try {
        $state = Get-NetworkDiagGuiStateFromControls -Controls $controls -Limits $script:App.Config.Limits
    } catch {
        $script:App.Run.ValidationHasErrors = $true
        $controls.ValidationText.Foreground = "DarkRed"
        $controls.ValidationText.Text = "Validation: $($_.Exception.Message)"
        Update-NetworkDiagGuiActionButtons
        return
    }

    $validation = Test-NetworkDiagGuiState -State $state -Limits $script:App.Config.Limits
    if ($validation.Errors.Count -gt 0) {
        $script:App.Run.ValidationHasErrors = $true
        $controls.ValidationText.Foreground = "DarkRed"
        $controls.ValidationText.Text = "Validation errors: " + ($validation.Errors -join " | ")
    } elseif ($validation.Warnings.Count -gt 0) {
        $script:App.Run.ValidationHasErrors = $false
        $controls.ValidationText.Foreground = "DarkGoldenrod"
        $controls.ValidationText.Text = "Validation warnings: " + ($validation.Warnings -join " | ")
    } else {
        $script:App.Run.ValidationHasErrors = $false
        $controls.ValidationText.Foreground = "DarkOliveGreen"
        $controls.ValidationText.Text = "Validation: ready to run."
    }
    Update-NetworkDiagGuiActionButtons
}
