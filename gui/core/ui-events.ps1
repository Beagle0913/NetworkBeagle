function Register-NetworkDiagGuiEvents {
    $controls = $script:App.Ui.Controls

    Update-NetworkDiagDependentControls
    $controls.BurstOnFault.Add_Click({ Update-NetworkDiagDependentControls })
    $controls.SkipDnsProbe.Add_Click({ Update-NetworkDiagDependentControls })
    $controls.SkipIspEvidencePacket.Add_Click({ Update-NetworkDiagDependentControls })

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
}
