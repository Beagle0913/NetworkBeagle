function Get-NetworkDiagGuiDraftStatePath {
    return Join-Path (Get-NetworkDiagGuiAppDataRoot) "draft-state.json"
}

function Save-NetworkDiagGuiDraftState {
    $state = Get-NetworkDiagGuiStateSnapshot
    if (-not $state) { return }
    try {
        $path = Get-NetworkDiagGuiDraftStatePath
        Write-NetworkDiagGuiStateDocument -Path $path -State $state
    } catch {
        Set-NetworkDiagGuiStatus -Text ("Warning: Could not save draft state: " + $_.Exception.Message)
    }
}

function Restore-NetworkDiagGuiDraftStateIfAvailable {
    try {
        $path = Get-NetworkDiagGuiDraftStatePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
        $loaded = Read-NetworkDiagGuiStateDocument -Path $path
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

function Set-NetworkDiagGuiGoalSelection {
    param([Parameter(Mandatory = $true)][string]$GoalId)
    $controls = $script:App.Ui.Controls
    if (-not $script:App.Config.GoalProfiles.Contains($GoalId)) { return }
    $profile = Apply-NetworkDiagGuiGoalPreset -GoalId $GoalId -Controls $controls -GoalProfiles $script:App.Config.GoalProfiles
    if ($controls.ContainsKey("CurrentGoalText")) {
        $adminRec = if ([bool]$profile.AdminRecommended) { "Admin recommended" } else { "Admin optional" }
        $controls.CurrentGoalText.Text = "Goal: $($profile.Name) - $($profile.Notes) ($adminRec)"
    }
    if ($GoalId -eq "custom" -and $controls.ContainsKey("MainTabs")) {
        $controls.MainTabs.SelectedIndex = 4
    }
    Update-NetworkDiagDependentControls
    Invoke-NetworkDiagGuiValidation
    Save-NetworkDiagGuiDraftState
}

function Show-NetworkDiagGuiOptionHelp {
    param([string]$ControlName)
    $controls = $script:App.Ui.Controls
    if (-not $controls.ContainsKey("OptionHelpText")) { return }
    $map = $script:App.Config.OptionHelpMap
    if ($map -and $map.ContainsKey($ControlName)) {
        $controls.OptionHelpText.Text = [string]$map[$ControlName]
    } else {
        $controls.OptionHelpText.Text = "No additional explanation is available for this option."
    }
}

function Invoke-NetworkDiagGuiShowPreviewCommand {
    $controls = $script:App.Ui.Controls
    $state = Get-NetworkDiagGuiStateFromControls -Controls $controls -Limits $script:App.Config.Limits
    $state.OutputFolder = "<output-folder>"
    $cmd = ConvertTo-NetworkDiagGuiCliCommand -State $state
    [System.Windows.MessageBox]::Show($cmd, "Preview command", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
}

function Invoke-NetworkDiagGuiCopyCliCommand {
    $controls = $script:App.Ui.Controls
    $state = Get-NetworkDiagGuiStateFromControls -Controls $controls -Limits $script:App.Config.Limits
    $state.OutputFolder = "<output-folder>"
    $cmd = ConvertTo-NetworkDiagGuiCliCommand -State $state
    [System.Windows.Clipboard]::SetText($cmd)
    Set-NetworkDiagGuiRunState -State "Idle" -Message "CLI command copied to clipboard."
}

function Update-NetworkDiagGuiAdvancedVisibility {
    $controls = $script:App.Ui.Controls
    if (-not $controls.ContainsKey("AdvancedTab")) { return }
    $filter = if ($controls.ContainsKey("AdvancedFilter")) { [string]$controls.AdvancedFilter.Text.Trim().ToLowerInvariant() } else { "" }
    $showNonDefault = if ($controls.ContainsKey("AdvancedShowNonDefault")) { [bool]$controls.AdvancedShowNonDefault.IsChecked } else { $false }
    $groups = Get-NetworkDiagGuiAdvancedKeyGroups
    $defaults = New-NetworkDiagGuiDefaultState
    $state = $null
    try { $state = Get-NetworkDiagGuiStateFromControls -Controls $controls -Limits $script:App.Config.Limits } catch { $state = $null }

    foreach ($groupName in $groups.Keys) {
        foreach ($k in @($groups[$groupName])) {
            if (-not $controls.ContainsKey($k)) { continue }
            $ctl = $controls[$k]
            if ($null -eq $ctl) { continue }
            $visible = $true
            if ($showNonDefault -and $null -ne $state) {
                $curr = if ($state.ContainsKey($k)) { $state[$k] } else { $null }
                $def = if ($defaults.ContainsKey($k)) { $defaults[$k] } else { $null }
                $visible = ([string]$curr -ne [string]$def)
            }
            $ctl.Visibility = if ($visible) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
        }
    }

    $groupTerms = @{
        RuntimeRulesGroup = @("runtime","rules","fallback","limits","defaults")
        TimingGroup = @("timing","icmp","dns","burst","routing")
        FeatureSwitchesGroup = @("switch","diagnostic","modules","tls","json","wifi","tcp","dns")
        PathMtuGroup = @("path","mtu")
        UdpGroup = @("udp","loss","micro")
        LongTcpGroup = @("long","tcp","session","reconnect")
        ProbeCaptureGroup = @("capture","timestamps","pktmon","netshtrace")
        HelpGroup = @("help")
    }

    foreach ($groupName in @("RuntimeRulesGroup","TimingGroup","FeatureSwitchesGroup","PathMtuGroup","UdpGroup","LongTcpGroup","ProbeCaptureGroup","HelpGroup")) {
        if (-not $controls.ContainsKey($groupName)) { continue }
        $group = $controls[$groupName]
        if ($null -eq $group) { continue }
        $filterOk = $true
        if ($filter) {
            $hay = (([string]$group.Header) + " " + ((@($groupTerms[$groupName])) -join " ")).ToLowerInvariant()
            $filterOk = $hay.Contains($filter)
        }
        $hasVisible = $true
        if ($showNonDefault -and $groups.Contains($groupName.Replace("Group",""))) {
            $hasVisible = $false
            $section = $groupName.Replace("Group","")
            foreach ($k in @($groups[$section])) {
                if ($controls.ContainsKey($k) -and $null -ne $controls[$k] -and $controls[$k].Visibility -eq [System.Windows.Visibility]::Visible) {
                    $hasVisible = $true
                    break
                }
            }
        }
        $group.Visibility = if ($filterOk -and $hasVisible) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    }
}

function Reset-NetworkDiagGuiAdvancedSection {
    param([Parameter(Mandatory = $true)][string]$Section)
    $controls = $script:App.Ui.Controls
    $current = Get-NetworkDiagGuiStateFromControls -Controls $controls -Limits $script:App.Config.Limits
    $defaults = New-NetworkDiagGuiDefaultState
    $groups = Get-NetworkDiagGuiAdvancedKeyGroups
    $keys = @()
    if ($Section -eq "All") {
        $keys = Get-NetworkDiagGuiAdvancedKeyAllowlist
    } elseif ($groups.Contains($Section)) {
        $keys = @($groups[$Section])
    }
    foreach ($k in $keys) {
        if ($defaults.ContainsKey($k)) {
            $current[$k] = $defaults[$k]
        }
    }
    $merged = Merge-NetworkDiagGuiState -Overrides $current
    Set-NetworkDiagGuiControlState -Controls $controls -State $merged
    Update-NetworkDiagDependentControls
    Invoke-NetworkDiagGuiValidation
}

function Invoke-NetworkDiagGuiApplyAdvancedBundle {
    $controls = $script:App.Ui.Controls
    $selected = [string]$controls.AdvancedBundleSelector.SelectedItem
    if (-not $selected) { return }
    if (-not $script:App.Config.AdvancedBundleMap.Contains($selected)) { return }
    $current = Get-NetworkDiagGuiStateFromControls -Controls $controls -Limits $script:App.Config.Limits
    $script:App.Run.LastAdvancedSnapshot = $current
    $overrides = [hashtable]$script:App.Config.AdvancedBundleMap[$selected]
    foreach ($k in $overrides.Keys) {
        $current[$k] = $overrides[$k]
    }
    $merged = Merge-NetworkDiagGuiState -Overrides $current
    Set-NetworkDiagGuiControlState -Controls $controls -State $merged
    Update-NetworkDiagDependentControls
    Invoke-NetworkDiagGuiValidation
    if ($controls.ContainsKey("UndoApplyAdvanced")) { $controls.UndoApplyAdvanced.IsEnabled = $true }
    Set-NetworkDiagGuiStatus -Text ("Applied advanced bundle: " + $selected)
}

function Invoke-NetworkDiagGuiUndoAdvancedBundle {
    $controls = $script:App.Ui.Controls
    $snap = if ($script:App.Run.ContainsKey("LastAdvancedSnapshot")) { $script:App.Run.LastAdvancedSnapshot } else { $null }
    if (-not $snap) { return }
    $merged = Merge-NetworkDiagGuiState -Overrides ([hashtable]$snap)
    Set-NetworkDiagGuiControlState -Controls $controls -State $merged
    Update-NetworkDiagDependentControls
    Invoke-NetworkDiagGuiValidation
    $script:App.Run.LastAdvancedSnapshot = $null
    if ($controls.ContainsKey("UndoApplyAdvanced")) { $controls.UndoApplyAdvanced.IsEnabled = $false }
    Set-NetworkDiagGuiStatus -Text "Restored previous advanced settings."
}

function Invoke-NetworkDiagGuiCopyAdvancedSnippet {
    $state = Get-NetworkDiagGuiStateSnapshot
    if (-not $state) { return }
    $snippet = Project-NetworkDiagGuiStateToAdvancedKeys -State $state
    [System.Windows.Clipboard]::SetText(($snippet | ConvertTo-Json -Depth 6))
    Set-NetworkDiagGuiStatus -Text "Advanced snippet copied to clipboard."
}

function Invoke-NetworkDiagGuiPasteAdvancedSnippet {
    $controls = $script:App.Ui.Controls
    $raw = [System.Windows.Clipboard]::GetText()
    if (-not $raw) { return }
    $obj = ConvertTo-NetworkDiagHashtable -InputObject ($raw | ConvertFrom-Json)
    if ($obj.ContainsKey("schemaVersion") -and $obj.ContainsKey("state")) {
        $obj = ConvertTo-NetworkDiagHashtable -InputObject $obj.state
    }
    $allow = @{}
    foreach ($k in (Get-NetworkDiagGuiAdvancedKeyAllowlist)) { $allow[$k] = $true }
    $over = @{}
    $ignored = 0
    foreach ($k in $obj.Keys) {
        if ($allow.ContainsKey([string]$k)) {
            $over[[string]$k] = $obj[$k]
        } else {
            $ignored++
        }
    }
    $current = Get-NetworkDiagGuiStateFromControls -Controls $controls -Limits $script:App.Config.Limits
    foreach ($k in $over.Keys) { $current[$k] = $over[$k] }
    $merged = Merge-NetworkDiagGuiState -Overrides $current
    Set-NetworkDiagGuiControlState -Controls $controls -State $merged
    Update-NetworkDiagDependentControls
    Invoke-NetworkDiagGuiValidation
    if ($ignored -gt 0 -and $controls.ContainsKey("OptionHelpText")) {
        $controls.OptionHelpText.Text = "Pasted advanced snippet; ignored $ignored unsupported key(s)."
    }
    Set-NetworkDiagGuiStatus -Text "Advanced snippet pasted from clipboard."
}

function Set-NetworkDiagGuiExperienceMode {
    $controls = $script:App.Ui.Controls
    $selected = if ($controls.UserExperienceMode.SelectedItem) { [string]$controls.UserExperienceMode.SelectedItem.Content } else { "Beginner (guided)" }
    $isBeginner = $selected -like "Beginner*"
    $advancedGroups = @(
        "FeatureSwitchesGroup", "UdpGroup", "LongTcpGroup", "ProbeCaptureGroup", "RuntimeRulesGroup", "TimingGroup", "PathMtuGroup",
        "ProfilesGroup", "AnalysisGroup", "IncidentGroup"
    )
    foreach ($groupName in $advancedGroups) {
        if ($controls.ContainsKey($groupName) -and $null -ne $controls[$groupName]) {
            $controls[$groupName].Visibility = if ($isBeginner) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }
        }
    }
    if ($controls.ContainsKey("QuickHelpText")) {
        if ($isBeginner) {
            $controls.QuickHelpText.Text = "Beginner mode: choose a goal, review run summary, then click Run basic test. Use Run full diagnostic as administrator for deeper checks."
        } else {
            $controls.QuickHelpText.Text = "Shortcuts: F5 run basic test, Ctrl+Shift+R run elevated, Ctrl+L focus log filter, Ctrl+E copy PowerShell command."
        }
    }
}

function Register-NetworkDiagGuiOptionHelpBindings {
    $controls = $script:App.Ui.Controls
    foreach ($name in @($script:App.Config.OptionHelpMap.Keys)) {
        if (-not $controls.ContainsKey($name)) { continue }
        $control = $controls[$name]
        if ($null -eq $control) { continue }
        try {
            $handler = {
                param($sender, $eventArgs)
                Show-NetworkDiagGuiOptionHelp -ControlName ([string]$sender.Name)
            }
            $control.Add_GotKeyboardFocus($handler)
            $control.Add_MouseEnter($handler)
        } catch {}
    }
}

function Register-NetworkDiagGuiEvents {
    $controls = $script:App.Ui.Controls

    Restore-NetworkDiagGuiDraftStateIfAvailable
    Update-NetworkDiagDependentControls
    Register-NetworkDiagGuiOptionHelpBindings
    Set-NetworkDiagGuiExperienceMode
    Show-NetworkDiagGuiOptionHelp -ControlName "UserExperienceMode"
    Set-NetworkDiagGuiGoalSelection -GoalId "quick"
    $controls.BurstOnFault.Add_Click({ Update-NetworkDiagDependentControls })
    $controls.SkipDnsProbe.Add_Click({ Update-NetworkDiagDependentControls })
    $controls.SkipIspEvidencePacket.Add_Click({ Update-NetworkDiagDependentControls })
    $controls.EnableUdpProbe.Add_Click({ Update-NetworkDiagDependentControls; Invoke-NetworkDiagGuiValidation })
    $controls.EnableLongLivedTcp.Add_Click({ Update-NetworkDiagDependentControls; Invoke-NetworkDiagGuiValidation })
    $controls.AutoCaptureOnFault.Add_Click({ Update-NetworkDiagDependentControls; Invoke-NetworkDiagGuiValidation })
    if ($controls.ContainsKey("AdvancedFilter")) { $controls.AdvancedFilter.Add_TextChanged({ Update-NetworkDiagGuiAdvancedVisibility }) }
    if ($controls.ContainsKey("AdvancedShowNonDefault")) { $controls.AdvancedShowNonDefault.Add_Click({ Update-NetworkDiagGuiAdvancedVisibility }) }
    if ($controls.ContainsKey("ApplyAdvancedBundle")) { $controls.ApplyAdvancedBundle.Add_Click({ Invoke-NetworkDiagGuiApplyAdvancedBundle }) }
    if ($controls.ContainsKey("UndoApplyAdvanced")) { $controls.UndoApplyAdvanced.Add_Click({ Invoke-NetworkDiagGuiUndoAdvancedBundle }) }
    if ($controls.ContainsKey("ResetAdvancedAll")) {
        $controls.ResetAdvancedAll.Add_Click({
            $ok = [System.Windows.MessageBox]::Show("Reset all advanced settings to defaults?", "Reset advanced", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
            if ($ok -eq [System.Windows.MessageBoxResult]::Yes) { Reset-NetworkDiagGuiAdvancedSection -Section "All" }
        })
    }
    if ($controls.ContainsKey("ResetAdvancedTiming")) { $controls.ResetAdvancedTiming.Add_Click({ Reset-NetworkDiagGuiAdvancedSection -Section "Timing" }) }
    if ($controls.ContainsKey("ResetAdvancedSwitches")) { $controls.ResetAdvancedSwitches.Add_Click({ Reset-NetworkDiagGuiAdvancedSection -Section "Switches" }) }
    if ($controls.ContainsKey("ResetAdvancedPathMtu")) { $controls.ResetAdvancedPathMtu.Add_Click({ Reset-NetworkDiagGuiAdvancedSection -Section "PathMtu" }) }
    if ($controls.ContainsKey("ResetAdvancedUdp")) { $controls.ResetAdvancedUdp.Add_Click({ Reset-NetworkDiagGuiAdvancedSection -Section "Udp" }) }
    if ($controls.ContainsKey("ResetAdvancedLongTcp")) { $controls.ResetAdvancedLongTcp.Add_Click({ Reset-NetworkDiagGuiAdvancedSection -Section "LongTcp" }) }
    if ($controls.ContainsKey("ResetAdvancedCapture")) { $controls.ResetAdvancedCapture.Add_Click({ Reset-NetworkDiagGuiAdvancedSection -Section "Capture" }) }
    if ($controls.ContainsKey("CopyAdvancedSnippet")) { $controls.CopyAdvancedSnippet.Add_Click({ Invoke-NetworkDiagGuiCopyAdvancedSnippet }) }
    if ($controls.ContainsKey("PasteAdvancedSnippet")) { $controls.PasteAdvancedSnippet.Add_Click({ Invoke-NetworkDiagGuiPasteAdvancedSnippet }) }
    if ($controls.ContainsKey("AdvancedPreviewCliCommand")) {
        $controls.AdvancedPreviewCliCommand.Add_Click({
            try { Invoke-NetworkDiagGuiShowPreviewCommand } catch {
                [System.Windows.MessageBox]::Show("Failed to preview command: $($_.Exception.Message)", "Preview command", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            }
        })
    }
    if ($controls.ContainsKey("AdvancedExportCliCommand")) {
        $controls.AdvancedExportCliCommand.Add_Click({
            try { Invoke-NetworkDiagGuiCopyCliCommand } catch {
                [System.Windows.MessageBox]::Show("Failed to copy command: $($_.Exception.Message)", "Copy command", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            }
        })
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
        if (-not $selected -or -not $script:App.Config.PresetMap.Contains($selected)) { return }
        $preset = $script:App.Config.PresetMap[$selected]
        Set-NetworkDiagGuiControlState -Controls $controls -State $preset
        Update-NetworkDiagDependentControls
        Invoke-NetworkDiagGuiValidation
        Set-NetworkDiagGuiRunState -State "Idle" -Message "Preset applied: $selected"
    })

    if ($controls.ContainsKey("GoalQuick")) { $controls.GoalQuick.Add_Click({ Set-NetworkDiagGuiGoalSelection -GoalId "quick" }) }
    if ($controls.ContainsKey("GoalWifi")) { $controls.GoalWifi.Add_Click({ Set-NetworkDiagGuiGoalSelection -GoalId "wifi" }) }
    if ($controls.ContainsKey("GoalDns")) { $controls.GoalDns.Add_Click({ Set-NetworkDiagGuiGoalSelection -GoalId "dns" }) }
    if ($controls.ContainsKey("GoalIsp")) { $controls.GoalIsp.Add_Click({ Set-NetworkDiagGuiGoalSelection -GoalId "isp" }) }
    if ($controls.ContainsKey("GoalVpn")) { $controls.GoalVpn.Add_Click({ Set-NetworkDiagGuiGoalSelection -GoalId "vpn" }) }
    if ($controls.ContainsKey("GoalCustom")) { $controls.GoalCustom.Add_Click({ Set-NetworkDiagGuiGoalSelection -GoalId "custom" }) }
    if ($controls.ContainsKey("FixUseDefaultDns")) { $controls.FixUseDefaultDns.Add_Click({ Invoke-NetworkDiagGuiValidationFix -Action "SetDnsDefault" }) }
    if ($controls.ContainsKey("FixDisableDns")) { $controls.FixDisableDns.Add_Click({ Invoke-NetworkDiagGuiValidationFix -Action "DisableDnsCheck" }) }
    if ($controls.ContainsKey("FixAutoTiming")) { $controls.FixAutoTiming.Add_Click({ Invoke-NetworkDiagGuiValidationFix -Action "AutoFixBurstInterval" }) }

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
            Write-NetworkDiagGuiStateDocument -Path $dialog.FileName -State $state
            Set-NetworkDiagGuiRunState -State "Idle" -Message "Profile saved: $($dialog.FileName)"
        }
    })

    $controls.LoadProfile.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = "JSON files (*.json)|*.json|All files (*.*)|*.*"
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            try {
                $merged = Read-NetworkDiagGuiStateDocument -Path $dialog.FileName
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
    if ($controls.ContainsKey("PreviewCliCommand") -and $null -ne $controls.PreviewCliCommand) {
        $controls.PreviewCliCommand.Add_Click({
            try {
                Invoke-NetworkDiagGuiShowPreviewCommand
            } catch {
                [System.Windows.MessageBox]::Show("Failed to preview command: $($_.Exception.Message)", "Preview command", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            }
        })
    }
    if ($controls.ContainsKey("RestartAsAdmin") -and $null -ne $controls.RestartAsAdmin) {
        $controls.RestartAsAdmin.Add_Click({ Invoke-NetworkDiagGuiRestartAsAdministrator })
    }
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
            Invoke-NetworkDiagGuiCopyCliCommand
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
    if ($controls.ContainsKey("CopyRunSummaryButton") -and $null -ne $controls.CopyRunSummaryButton) {
        $controls.CopyRunSummaryButton.Add_Click({
            $text = Build-NetworkDiagGuiHumanSummary
            [System.Windows.Clipboard]::SetText($text)
            Set-NetworkDiagGuiStatus -Text "Run summary copied to clipboard."
        })
    }
    if ($controls.ContainsKey("SupportBundleButton") -and $null -ne $controls.SupportBundleButton) {
        $controls.SupportBundleButton.Add_Click({
            $res = Invoke-NetworkDiagGuiCreateSupportBundle
            if ($res.Ok) {
                [System.Windows.MessageBox]::Show("Support bundle created:`n$($res.Path)", "Support bundle", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
            } else {
                [System.Windows.MessageBox]::Show("Support bundle unavailable: $($res.Message)", "Support bundle", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            }
        })
    }
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
            $merged = Read-NetworkDiagGuiStateDocument -Path $selected.StateConfigPath
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
    if ($controls.ContainsKey("CompareRunA")) {
        $controls.CompareRunA.Add_Click({
            $selected = Get-NetworkDiagGuiSelectedRecentRun
            if (-not $selected) { return }
            $script:App.History.CompareA = $selected
            Set-NetworkDiagGuiStatus -Text "Comparison A set: $($selected.StartedAt)"
        })
    }
    if ($controls.ContainsKey("CompareRunB")) {
        $controls.CompareRunB.Add_Click({
            $selected = Get-NetworkDiagGuiSelectedRecentRun
            if (-not $selected) { return }
            $script:App.History.CompareB = $selected
            Set-NetworkDiagGuiStatus -Text "Comparison B set: $($selected.StartedAt)"
        })
    }
    if ($controls.ContainsKey("CompareRuns")) {
        $controls.CompareRuns.Add_Click({
            $a = $script:App.History.CompareA
            $b = $script:App.History.CompareB
            if (-not $a -or -not $b) { return }
            $txt = Build-NetworkDiagGuiRunComparisonText -RunA $a -RunB $b
            if ($controls.ContainsKey("RunComparisonText")) {
                $controls.RunComparisonText.Text = $txt
            }
        })
    }

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
    $controls.UserExperienceMode.Add_SelectionChanged({
        Set-NetworkDiagGuiExperienceMode
        Invoke-NetworkDiagGuiValidation
        Save-NetworkDiagGuiDraftState
        Show-NetworkDiagGuiOptionHelp -ControlName "UserExperienceMode"
        $sel = if ($controls.UserExperienceMode.SelectedItem) { [string]$controls.UserExperienceMode.SelectedItem.Content } else { "" }
        Set-NetworkDiagGuiStatus -Text ("Experience mode: " + $sel)
    })
    Update-NetworkDiagGuiAdvancedVisibility

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
