function Get-NetworkDiagGuiDraftStatePath {
    return Join-Path (Get-NetworkDiagGuiAppDataRoot) "draft-state.json"
}

function Save-NetworkDiagGuiDraftState {
    $state = Get-NetworkDiagGuiStateSnapshot
    if (-not $state) { return }
    try {
        $path = Get-NetworkDiagGuiDraftStatePath
        [System.IO.File]::WriteAllText($path, ($state | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding $false))
    } catch {
        Set-NetworkDiagGuiStatus -Text ("Warning: Could not save draft state: " + $_.Exception.Message)
    }
}

function Restore-NetworkDiagGuiDraftStateIfAvailable {
    try {
        $path = Get-NetworkDiagGuiDraftStatePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
        $loaded = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        if (-not $loaded) { return }
        $result = [System.Windows.MessageBox]::Show(
            "A previous GUI draft state was found. Restore it?",
            "Restore previous state",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
            $merged = Merge-NetworkDiagGuiState -Overrides $loaded
            Set-NetworkDiagGuiControlState -Controls $script:App.Ui.Controls -State $merged
            Update-NetworkDiagDependentControls
            Invoke-NetworkDiagGuiValidation
            Set-NetworkDiagGuiStatus -Text "Recovered previous launcher draft state."
        }
    } catch {
        Set-NetworkDiagGuiStatus -Text ("Warning: Draft state restore failed: " + $_.Exception.Message)
    }
}

function Register-NetworkDiagGuiEvents {
    $controls = $script:App.Ui.Controls

    Restore-NetworkDiagGuiDraftStateIfAvailable
    Update-NetworkDiagDependentControls
    $controls.BurstOnFault.Add_Click({ Update-NetworkDiagDependentControls })
    $controls.SkipDnsProbe.Add_Click({ Update-NetworkDiagDependentControls })
    $controls.SkipIspEvidencePacket.Add_Click({ Update-NetworkDiagDependentControls })
    $controls.EnableUdpProbe.Add_Click({ Update-NetworkDiagDependentControls; Invoke-NetworkDiagGuiValidation })
    $controls.EnableLongLivedTcp.Add_Click({ Update-NetworkDiagDependentControls; Invoke-NetworkDiagGuiValidation })
    $controls.AutoCaptureOnFault.Add_Click({ Update-NetworkDiagDependentControls; Invoke-NetworkDiagGuiValidation })

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
        if (-not $selected -or -not $script:App.Config.PresetMap.ContainsKey($selected)) { return }
        $preset = $script:App.Config.PresetMap[$selected]
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
                $merged = Merge-NetworkDiagGuiState -Overrides $loaded
                Set-NetworkDiagGuiControlState -Controls $controls -State $merged
                Update-NetworkDiagDependentControls
                Invoke-NetworkDiagGuiValidation
                Set-NetworkDiagGuiRunState -State "Idle" -Message "Profile loaded: $($dialog.FileName)"
            } catch {
                [System.Windows.MessageBox]::Show("Failed to load profile: $($_.Exception.Message)", "Load profile", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
            }
        }
    })

    $controls.RunNormal.Add_Click({ Start-NetworkDiagGuiRun })
    $controls.RunAdmin.Add_Click({ Start-NetworkDiagGuiRun -PreferAdmin })
    $controls.StopRun.Add_Click({ Stop-NetworkDiagGuiRun })
    $controls.ClearLiveLog.Add_Click({ $controls.LiveLog.Clear() })
    $controls.LiveLogFilter.Add_TextChanged({
        Set-NetworkDiagGuiStatus -Text ("Log filter updated: '" + [string]$controls.LiveLogFilter.Text + "'")
    })
    $controls.RecentRunsFilter.Add_TextChanged({
        Refresh-NetworkDiagGuiRecentRuns
    })
    $controls.LiveLogStderrOnly.Add_Click({
        Set-NetworkDiagGuiStatus -Text ("Log mode: " + $(if ([bool]$controls.LiveLogStderrOnly.IsChecked) { "stderr only" } else { "stdout + stderr" }))
    })

    $controls.ExportCliCommand.Add_Click({
        try {
            $state = Get-NetworkDiagGuiStateFromControls -Controls $controls -Limits $script:App.Config.Limits
            $state.OutputFolder = "<output-folder>"
            $cmd = ConvertTo-NetworkDiagGuiCliCommand -State $state
            [System.Windows.Clipboard]::SetText($cmd)
            Set-NetworkDiagGuiRunState -State "Idle" -Message "CLI command copied to clipboard."
        } catch {
            [System.Windows.MessageBox]::Show("Failed to export CLI command: $($_.Exception.Message)", "Copy CLI command", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        }
    })
    $controls.CopyArtifactPaths.Add_Click({
        $paths = Get-NetworkDiagGuiArtifactPathsText
        if (-not $paths) {
            [System.Windows.MessageBox]::Show("No artifact paths are available yet.", "Copy artifact paths", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
            return
        }
        [System.Windows.Clipboard]::SetText($paths)
        Set-NetworkDiagGuiStatus -Text "Artifact paths copied to clipboard."
    })
    $controls.OpenLaunchConfig.Add_Click({
        $path = [string]$script:App.Run.CurrentLaunchConfigPath
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            Start-Process -FilePath "explorer.exe" -ArgumentList "/select,`"$path`""
        } else {
            [System.Windows.MessageBox]::Show("launch-config.json is not available yet.", "Open launch config", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        }
    })
    $controls.OpenGuiState.Add_Click({
        $path = [string]$script:App.Run.CurrentGuiStatePath
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            Start-Process -FilePath "explorer.exe" -ArgumentList "/select,`"$path`""
        } else {
            [System.Windows.MessageBox]::Show("gui-state.json is not available yet.", "Open gui-state", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        }
    })

    $controls.OpenCurrentRun.Add_Click({
        if ($script:App.Run.CurrentRunFolder -and (Test-Path -LiteralPath $script:App.Run.CurrentRunFolder)) {
            Start-Process -FilePath "explorer.exe" -ArgumentList "`"$($script:App.Run.CurrentRunFolder)`""
        } else {
            [System.Windows.MessageBox]::Show("No current run folder is available yet.", "Open run folder", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        }
    })

    $controls.OpenCurrentLogs.Add_Click({
        if ($script:App.Run.CurrentLogsFolder -and (Test-Path -LiteralPath $script:App.Run.CurrentLogsFolder)) {
            Start-Process -FilePath "explorer.exe" -ArgumentList "`"$($script:App.Run.CurrentLogsFolder)`""
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
            $merged = Merge-NetworkDiagGuiState -Overrides $loaded
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
        "GwIcmpPolicyConfirmCycles","RoutingRefreshIntervalCycles","PathMtuProbeTarget",
        "UdpProbeTarget","UdpProbeRateHz","UdpProbePayloadBytes","LongLivedTcpTarget",
        "LongLivedTcpReconnectBackoffSeconds","AutoCaptureSeconds","AutoCaptureMax"
    )) {
        $controls[$name].Add_TextChanged({ Invoke-NetworkDiagGuiValidation; Save-NetworkDiagGuiDraftState })
    }
    foreach ($name in @(
        "RequireEthernet","SkipTcpProbe","DetailLog","LegacyCsvShape","SkipDnsProbe","BurstOnFault",
        "SkipGwIcmpPolicyAdaptation","PinExternalIcmpToResolvedIp","SkipConfigAudit","SkipCableHints",
        "SkipMultiNicCrossCheck","SkipIspEvidencePacket","IspEvidenceZip","SkipWifiSignal",
        "EnableTlsProbe","SkipJsonSummary","SelfTest","EnableUdpProbe","EnableLongLivedTcp",
        "PerProbeTimestamps","AutoCaptureOnFault"
    )) {
        $controls[$name].Add_Click({ Invoke-NetworkDiagGuiValidation; Save-NetworkDiagGuiDraftState })
    }
    $controls.MonitoringMode.Add_SelectionChanged({ Invoke-NetworkDiagGuiValidation; Save-NetworkDiagGuiDraftState })
    $controls.ProbeAddressFamily.Add_SelectionChanged({ Invoke-NetworkDiagGuiValidation; Save-NetworkDiagGuiDraftState })
    $controls.AutoCaptureMethod.Add_SelectionChanged({ Invoke-NetworkDiagGuiValidation; Save-NetworkDiagGuiDraftState })

    $script:App.Ui.Window.Add_KeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.Key -eq [System.Windows.Input.Key]::F5) {
            Start-NetworkDiagGuiRun
            $eventArgs.Handled = $true
            return
        }
        if (($eventArgs.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -and
            ($eventArgs.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -and
            $eventArgs.Key -eq [System.Windows.Input.Key]::R) {
            Start-NetworkDiagGuiRun -PreferAdmin
            $eventArgs.Handled = $true
            return
        }
        if (($eventArgs.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -and $eventArgs.Key -eq [System.Windows.Input.Key]::L) {
            $controls.LiveLogFilter.Focus() | Out-Null
            $eventArgs.Handled = $true
            return
        }
        if (($eventArgs.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -and $eventArgs.Key -eq [System.Windows.Input.Key]::E) {
            $controls.ExportCliCommand.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
            $eventArgs.Handled = $true
            return
        }
    })

    $script:App.Ui.Window.Add_Closing({
        Save-NetworkDiagGuiDraftState
    })
}
