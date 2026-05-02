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

function Write-NetworkDiagGuiRunPointers {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Paths,
        [Parameter(Mandatory = $true)][hashtable]$State
    )
    $readmePath = Join-Path $Paths.LauncherRunRoot "RUN_README.txt"
    $lines = @(
        "NetworkBeagle launcher run"
        "Created: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Run folder: $($Paths.LauncherRunRoot)"
        "Report folder: $($Paths.ScriptOutputRoot)"
        "Logs folder: $($Paths.LogsFolder)"
        ""
        "Open this first:"
        " - logs\\launcher.log"
        " - logs\\stdout.log"
        " - logs\\stderr.log"
        " - script-output-root\\runs\\run_<timestamp>"
    )
    [System.IO.File]::WriteAllText($readmePath, ($lines -join [Environment]::NewLine), (New-Object System.Text.UTF8Encoding $false))

    try {
        $latestPath = Join-Path (Join-Path $State.OutputRoot "gui-launcher-runs") "latest-run.json"
        $latestObj = [ordered]@{
            updatedAt = (Get-Date).ToString("o")
            launcherRunRoot = $Paths.LauncherRunRoot
            logsFolder = $Paths.LogsFolder
            reportFolder = $Paths.ScriptOutputRoot
        }
        [System.IO.File]::WriteAllText($latestPath, ($latestObj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $false))
    } catch { }
}

function Write-NetworkDiagGuiLogLine {
    param([string]$Path, [string]$Text)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Text"
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Get-NetworkDiagGuiAppDataRoot {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:TEMP "NetworkBeagle" }
    $root = Join-Path $base "NetworkBeagle"
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        [void](New-Item -Path $root -ItemType Directory -Force)
    }
    return $root
}

function Get-NetworkDiagGuiRecentRunsManifestPath {
    return Join-Path (Get-NetworkDiagGuiAppDataRoot) "recent-runs.json"
}

function Save-NetworkDiagGuiRecentRuns {
    try {
        $path = Get-NetworkDiagGuiRecentRunsManifestPath
        $payload = [ordered]@{
            schemaVersion = 2
            savedAt = (Get-Date).ToUniversalTime().ToString("o")
            runs = @($script:App.Run.RecentRuns)
        }
        [System.IO.File]::WriteAllText($path, ($payload | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding $false))
    } catch {
        Set-NetworkDiagGuiStatus -Text ("Warning: Could not persist recent runs history: " + $_.Exception.Message)
    }
}

function Load-NetworkDiagGuiRecentRuns {
    try {
        $path = Get-NetworkDiagGuiRecentRunsManifestPath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
        $payloadRaw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $payload = ConvertTo-NetworkDiagHashtable -InputObject $payloadRaw
        $runs = @()
        if ($payload.ContainsKey("schemaVersion")) {
            $runs = @($payload.runs)
        } else {
            $runs = @($payload)
        }
        if ($runs -isnot [System.Collections.IEnumerable]) { return }
        foreach ($item in @($runs)) {
            if (-not $item) { continue }
            $script:App.Run.RecentRuns.Add(@{
                StartedAt = [string]$item.StartedAt
                LauncherRunRoot = [string]$item.LauncherRunRoot
                LogsFolder = [string]$item.LogsFolder
                ScriptRunFolder = [string]$item.ScriptRunFolder
                StateConfigPath = [string]$item.StateConfigPath
                LaunchConfigPath = [string]$item.LaunchConfigPath
                ExitCode = if ($null -eq $item.ExitCode -or $item.ExitCode -eq "") { $null } else { [int]$item.ExitCode }
            })
        }
        while ($script:App.Run.RecentRuns.Count -gt 25) {
            $script:App.Run.RecentRuns.RemoveAt($script:App.Run.RecentRuns.Count - 1)
        }
    } catch {
        Set-NetworkDiagGuiStatus -Text ("Warning: Could not load recent runs history: " + $_.Exception.Message)
    }
}

function Get-NetworkDiagGuiRunTransitionMap {
    return @{
        Idle = @("Idle", "Validating", "PreparingRun", "LaunchingElevated")
        Validating = @("Idle", "PreparingRun", "LaunchingElevated", "Failed", "Cancelled")
        PreparingRun = @("Running", "Failed", "Cancelled")
        LaunchingElevated = @("Idle", "Cancelled", "Failed")
        Running = @("Stopping", "Completed", "Failed", "Cancelled")
        Stopping = @("Completed", "Failed", "Cancelled")
        Completed = @("Idle", "Validating", "PreparingRun", "LaunchingElevated")
        Failed = @("Idle", "Validating", "PreparingRun", "LaunchingElevated")
        Cancelled = @("Idle", "Validating", "PreparingRun", "LaunchingElevated")
    }
}

function New-NetworkDiagGuiRunnerScriptContent {
    param(
        [string]$ScriptPath,
        [string]$JsonPath
    )

    return @"
`$ErrorActionPreference = "Stop"
`$scriptPath = "$($ScriptPath.Replace('"','`"'))"
`$jsonPath = "$($JsonPath.Replace('"','`"'))"
`$json = Get-Content -LiteralPath `$jsonPath -Raw -Encoding UTF8
`$paramsRaw = ConvertFrom-Json -InputObject `$json
if (`$paramsRaw -is [System.Collections.IDictionary]) {
    `$params = @{}
    foreach (`$k in `$paramsRaw.Keys) { `$params[[string]`$k] = `$paramsRaw[`$k] }
} else {
    `$params = @{}
    foreach (`$p in `$paramsRaw.PSObject.Properties) { `$params[[string]`$p.Name] = `$p.Value }
}
& `$scriptPath @params
"@
}

function New-NetworkDiagGuiLaunchCommand {
    param([string]$RunnerPath)

    $workingDir = if (Test-Path variable:script:NetworkDiagGuiRepoRoot) {
        [string]$script:NetworkDiagGuiRepoRoot
    } else {
        [string](Split-Path -Path $PSScriptRoot -Parent -ErrorAction SilentlyContinue)
    }
    if (-not $workingDir) { $workingDir = $PSScriptRoot }

    return @{
        FileName = "powershell.exe"
        Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$RunnerPath`""
        WorkingDirectory = $workingDir
    }
}

function Get-NetworkDiagGuiScriptPath {
    $root = if (Test-Path variable:script:NetworkDiagGuiRepoRoot) {
        [string]$script:NetworkDiagGuiRepoRoot
    } else {
        [string](Split-Path -Path $PSScriptRoot -Parent -ErrorAction SilentlyContinue)
    }
    if (-not $root) { $root = $PSScriptRoot }
    $p = Join-Path $root "network-stability-test.ps1"
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        throw "Could not find network-stability-test.ps1 next to GUI launcher: $p"
    }
    return $p
}

function Append-NetworkDiagGuiLiveLog {
    param([string]$Line)
    $window = $script:App.Ui.Window
    $controls = $script:App.Ui.Controls
    $filter = ""
    if ($controls.ContainsKey("LiveLogFilter") -and $controls.LiveLogFilter) {
        $filter = [string]$controls.LiveLogFilter.Text
    }
    $stderrOnly = $false
    if ($controls.ContainsKey("LiveLogStderrOnly") -and $controls.LiveLogStderrOnly) {
        $stderrOnly = [bool]$controls.LiveLogStderrOnly.IsChecked
    }
    if ($stderrOnly -and $Line -notmatch "^\[stderr\]") { return }
    if ($filter -and $Line -notmatch [regex]::Escape($filter)) { return }
    $window.Dispatcher.Invoke([Action]{
        $controls.LiveLog.AppendText($Line + [Environment]::NewLine)
        $controls.LiveLog.ScrollToEnd()
    })
}

function Set-NetworkDiagGuiStatus {
    param([string]$Text)
    $window = $script:App.Ui.Window
    $controls = $script:App.Ui.Controls
    $window.Dispatcher.Invoke([Action]{ $controls.StatusText.Text = $Text })
}

function Update-NetworkDiagGuiActionButtons {
    $controls = $script:App.Ui.Controls
    $state = if ($script:App.Run.State) { [string]$script:App.Run.State } else { "Idle" }
    $canRun = ($state -in @("Idle", "Completed", "Failed", "Cancelled")) -and (-not $script:App.Run.ValidationHasErrors)
    $canStop = ($state -eq "Running")
    $controls.RunNormal.IsEnabled = $canRun
    $controls.RunAdmin.IsEnabled = $canRun
    $controls.StopRun.IsEnabled = $canStop
    if ($controls.ContainsKey("RestartAsAdmin") -and $null -ne $controls.RestartAsAdmin) {
        $controls.RestartAsAdmin.IsEnabled = $canRun -and (-not $script:App.Context.IsAdminGui)
    }
    if ($controls.ContainsKey("SupportBundleButton") -and $null -ne $controls.SupportBundleButton) {
        $controls.SupportBundleButton.IsEnabled = $script:App.Run.CurrentRunFolder -and (Test-Path -LiteralPath $script:App.Run.CurrentRunFolder -PathType Container)
    }
}

function Start-NetworkDiagGuiAdminProcessRelaunch {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [switch]$AutoRunElevated
    )
    $cfgPath = Save-NetworkDiagGuiConfig -State $State
    $argPieces = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$($script:App.Context.CommandPath)`"",
        "-ElevatedLaunch",
        "-ConfigPath", "`"$cfgPath`""
    )
    if ($AutoRunElevated) { $argPieces += "-AutoRunElevated" }
    $argStr = $argPieces -join " "
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argStr | Out-Null
}

function Invoke-NetworkDiagGuiRestartAsAdministrator {
    if ($script:App.Context.IsAdminGui) {
        [System.Windows.MessageBox]::Show(
            "This window is already running as Administrator.",
            "Restart as Administrator",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
        return
    }
    if ($script:App.Run.CurrentProcess -and -not $script:App.Run.CurrentProcess.HasExited) {
        [System.Windows.MessageBox]::Show(
            "Stop the active run before restarting the launcher as Administrator.",
            "Run in progress",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        ) | Out-Null
        return
    }

    Set-NetworkDiagGuiRunState -State "Validating" -Message "Checking inputs for elevated restart..."
    $state = $null
    try {
        $state = Get-NetworkDiagGuiStateFromControls -Controls $script:App.Ui.Controls -Limits $script:App.Config.Limits
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Invalid input", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        Set-NetworkDiagGuiRunState -State "Idle" -Message "Validation failed before elevated restart."
        return
    }

    $validation = Test-NetworkDiagGuiState -State $state -Limits $script:App.Config.Limits
    if ($validation.Errors.Count -gt 0) {
        [System.Windows.MessageBox]::Show(($validation.Errors -join [Environment]::NewLine), "Validation failed", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        Set-NetworkDiagGuiRunState -State "Idle" -Message "Validation failed."
        return
    }
    if ($validation.Warnings.Count -gt 0) {
        Set-NetworkDiagGuiStatus ($validation.Warnings -join " | ")
        if ($state.DurationMinutes -ge 1440 -and $state.DetailLog) {
            $ans = [System.Windows.MessageBox]::Show(
                "This run is 24h+ with DetailLog enabled. Logs may become very large. Continue?",
                "Long run confirmation",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($ans -ne [System.Windows.MessageBoxResult]::Yes) {
                Set-NetworkDiagGuiRunState -State "Idle" -Message "Elevated restart canceled by user."
                return
            }
        }
    } else {
        Set-NetworkDiagGuiStatus "Validation passed."
    }

    try {
        Start-NetworkDiagGuiAdminProcessRelaunch -State $state
        Set-NetworkDiagGuiStatus "Requested elevated restart. Approve UAC to open a new Administrator window with these settings."
        Set-NetworkDiagGuiRunState -State "Idle" -Message "Waiting for elevated relaunch."
    } catch {
        Set-NetworkDiagGuiStatus "Elevated restart was canceled or failed: $($_.Exception.Message)"
        Set-NetworkDiagGuiRunState -State "Idle" -Message "Elevated restart canceled or failed."
    }
}

function Set-NetworkDiagGuiRunState {
    param(
        [string]$State,
        [string]$Message = ""
    )
    $currentState = if ($script:App.Run.State) { [string]$script:App.Run.State } else { "Idle" }
    $requestedState = [string]$State
    $transitions = Get-NetworkDiagGuiRunTransitionMap
    $allowedTargets = if ($transitions.ContainsKey($currentState)) { @($transitions[$currentState]) } else { @("Idle", "Failed") }
    if (-not ($allowedTargets -contains $requestedState)) {
        $requestedState = "Failed"
        if ($Message) {
            $Message = "Invalid state transition $currentState->$State. $Message"
        } else {
            $Message = "Invalid state transition $currentState->$State."
        }
    }

    $script:App.Run.State = $requestedState
    if (-not $script:App.Run.ContainsKey("TransitionHistory")) {
        $script:App.Run.TransitionHistory = [System.Collections.Generic.List[string]]::new()
    }
    $script:App.Run.TransitionHistory.Add(("$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $currentState -> $requestedState : $Message"))
    while ($script:App.Run.TransitionHistory.Count -gt 50) {
        $script:App.Run.TransitionHistory.RemoveAt(0)
    }
    $status = if ($Message) { "${requestedState}: $Message" } else { $requestedState }
    if ($requestedState -ne $State) {
        $status = "${requestedState}: $Message"
    }
    Set-NetworkDiagGuiStatus -Text $status
    Update-NetworkDiagGuiActionButtons
}

function Invoke-NetworkDiagGuiCreateSupportBundle {
    $runFolder = [string]$script:App.Run.CurrentRunFolder
    $logsFolder = [string]$script:App.Run.CurrentLogsFolder
    if (-not $runFolder -or -not (Test-Path -LiteralPath $runFolder -PathType Container)) {
        return @{ Ok = $false; Message = "No completed run folder is available yet." }
    }
    try {
        $bundleRoot = Join-Path $runFolder "support_bundle"
        if (-not (Test-Path -LiteralPath $bundleRoot -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $bundleRoot -Force)
        }
        $summaryTxt = Join-Path $bundleRoot "summary.txt"
        $summaryJson = Join-Path $bundleRoot "summary.json"
        [System.IO.File]::WriteAllText($summaryTxt, (Build-NetworkDiagGuiHumanSummary), (New-Object System.Text.UTF8Encoding $false))
        $summaryObj = [ordered]@{
            createdAt = (Get-Date).ToString("o")
            runFolder = $runFolder
            logsFolder = $logsFolder
            launcherState = [string]$script:App.Run.State
            health = $script:App.Health
        }
        [System.IO.File]::WriteAllText($summaryJson, ($summaryObj | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding $false))

        foreach ($candidate in @($script:App.Run.CurrentLaunchConfigPath, $script:App.Run.CurrentGuiStatePath)) {
            if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                Copy-Item -LiteralPath $candidate -Destination (Join-Path $bundleRoot (Split-Path -Leaf $candidate)) -Force
            }
        }
        if ($logsFolder -and (Test-Path -LiteralPath $logsFolder -PathType Container)) {
            Copy-Item -LiteralPath (Join-Path $logsFolder "*") -Destination $bundleRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        Copy-Item -LiteralPath (Join-Path $runFolder "*") -Destination $bundleRoot -Recurse -Force -ErrorAction SilentlyContinue

        $zipPath = Join-Path $runFolder ("support_bundle_" + (Get-Date -Format "yyyy-MM-dd_HH-mm-ss") + ".zip")
        if (Test-Path -LiteralPath $zipPath -PathType Leaf) { Remove-Item -LiteralPath $zipPath -Force }
        Compress-Archive -Path (Join-Path $bundleRoot "*") -DestinationPath $zipPath -CompressionLevel Optimal -Force
        return @{ Ok = $true; Path = $zipPath }
    } catch {
        return @{ Ok = $false; Message = $_.Exception.Message }
    }
}

function Refresh-NetworkDiagGuiRecentRuns {
    $controls = $script:App.Ui.Controls
    $controls.RecentRunsList.Items.Clear()
    $filter = ""
    if ($controls.ContainsKey("RecentRunsFilter") -and $controls.RecentRunsFilter) {
        $filter = [string]$controls.RecentRunsFilter.Text
    }
    foreach ($item in $script:App.Run.RecentRuns) {
        $exitCodeLabel = if ($null -eq $item.ExitCode) { "running" } else { "exit=$($item.ExitCode)" }
        $display = "{0}  ({1})  {2}" -f $item.StartedAt, $exitCodeLabel, $item.LauncherRunRoot
        if ($filter -and $display -notmatch [regex]::Escape($filter)) { continue }
        [void]$controls.RecentRunsList.Items.Add($display)
    }
    Save-NetworkDiagGuiRecentRuns
}

function Add-NetworkDiagGuiRecentRun {
    param([hashtable]$Item)
    $script:App.Run.RecentRuns.Insert(0, $Item)
    while ($script:App.Run.RecentRuns.Count -gt 15) {
        $script:App.Run.RecentRuns.RemoveAt($script:App.Run.RecentRuns.Count - 1)
    }
    Refresh-NetworkDiagGuiRecentRuns
}

function Get-NetworkDiagGuiSelectedRecentRun {
    $controls = $script:App.Ui.Controls
    $idx = $controls.RecentRunsList.SelectedIndex
    if ($idx -lt 0 -or $idx -ge $script:App.Run.RecentRuns.Count) { return $null }
    return $script:App.Run.RecentRuns[$idx]
}

function Get-NetworkDiagGuiArtifactPathsText {
    $paths = [System.Collections.Generic.List[string]]::new()
    if ($script:App.Run.CurrentLogsFolder) { $paths.Add("LogsFolder: $($script:App.Run.CurrentLogsFolder)") }
    if ($script:App.Run.CurrentRunFolder) { $paths.Add("RunFolder: $($script:App.Run.CurrentRunFolder)") }
    if ($script:App.Run.CurrentLaunchConfigPath) { $paths.Add("LaunchConfig: $($script:App.Run.CurrentLaunchConfigPath)") }
    if ($script:App.Run.CurrentGuiStatePath) { $paths.Add("GuiState: $($script:App.Run.CurrentGuiStatePath)") }
    if ($script:App.Run.CurrentProcess -and -not $script:App.Run.CurrentProcess.HasExited) { $paths.Add("PID: $($script:App.Run.CurrentProcess.Id)") }
    return ($paths -join [Environment]::NewLine)
}

function Stop-NetworkDiagGuiRun {
    if (-not $script:App.Run.CurrentProcess -or $script:App.Run.CurrentProcess.HasExited) {
        Set-NetworkDiagGuiRunState -State "Idle" -Message "No active run."
        return
    }
    $script:App.Run.StopRequested = $true
    Set-NetworkDiagGuiRunState -State "Stopping" -Message "Attempting graceful stop..."
    try {
        $stoppedGracefully = $false
        if ($script:App.Run.CurrentProcess.CloseMainWindow()) {
            $stoppedGracefully = $script:App.Run.CurrentProcess.WaitForExit(2500)
        }
        if (-not $stoppedGracefully -and -not $script:App.Run.CurrentProcess.HasExited) {
            $script:App.Run.CurrentProcess.Kill()
            Set-NetworkDiagGuiStatus -Text "Hard stop used after graceful stop timeout."
        } else {
            Set-NetworkDiagGuiStatus -Text "Graceful stop requested."
        }
    } catch {
        Set-NetworkDiagGuiRunState -State "Failed" -Message ("Stop failed: " + $_.Exception.Message)
    }
}

function Start-NetworkDiagGuiRun {
    param([switch]$PreferAdmin)
    if ($script:App.Run.CurrentProcess -and -not $script:App.Run.CurrentProcess.HasExited) {
        [System.Windows.MessageBox]::Show("A run is already active. Wait for it to finish.", "Run in progress", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }

    Reset-NetworkDiagGuiLiveHealth
    Set-NetworkDiagGuiQuickAnalysisText -Text "Quick analysis will appear after the run completes."
    Reset-NetworkDiagGuiIncidentInsights
    Set-NetworkDiagGuiRunState -State "Validating" -Message "Checking inputs..."
    $state = $null
    try {
        $state = Get-NetworkDiagGuiStateFromControls -Controls $script:App.Ui.Controls -Limits $script:App.Config.Limits
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Invalid input", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        Set-NetworkDiagGuiRunState -State "Idle" -Message "Validation failed before launch."
        return
    }

    $validation = Test-NetworkDiagGuiState -State $state -Limits $script:App.Config.Limits
    if ($validation.Errors.Count -gt 0) {
        [System.Windows.MessageBox]::Show(($validation.Errors -join [Environment]::NewLine), "Validation failed", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        Set-NetworkDiagGuiRunState -State "Idle" -Message "Validation failed."
        return
    }
    if ($validation.Warnings.Count -gt 0) {
        Set-NetworkDiagGuiStatus ($validation.Warnings -join " | ")
        if ($state.DurationMinutes -ge 1440 -and $state.DetailLog) {
            $ans = [System.Windows.MessageBox]::Show(
                "This run is 24h+ with DetailLog enabled. Logs may become very large. Continue?",
                "Long run confirmation",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($ans -ne [System.Windows.MessageBoxResult]::Yes) {
                Set-NetworkDiagGuiRunState -State "Idle" -Message "Run canceled by user."
                return
            }
        }
    } else {
        Set-NetworkDiagGuiStatus "Validation passed."
    }

    Invoke-NetworkDiagGuiHook -Hooks $script:App.Hooks -EventName "RunStarting" -Payload @{ PreferAdmin = [bool]$PreferAdmin; State = $state }

    if ($PreferAdmin -and -not $script:App.Context.IsAdminGui) {
        try {
            Start-NetworkDiagGuiAdminProcessRelaunch -State $state -AutoRunElevated
            Set-NetworkDiagGuiStatus "Requested admin relaunch. Approve UAC to continue."
            Set-NetworkDiagGuiRunState -State "LaunchingElevated" -Message "Waiting for elevated relaunch."
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

    Set-NetworkDiagGuiRunState -State "PreparingRun" -Message "Preparing run folders and launch command..."

    $paths = $null
    try {
        $paths = New-NetworkDiagGuiLauncherPaths -BaseRoot $state.OutputRoot
    } catch {
        [System.Windows.MessageBox]::Show("Could not create launcher run folders: $($_.Exception.Message)", "Output folder error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        Set-NetworkDiagGuiRunState -State "Failed" -Message ("Failed to prepare run folders: " + $_.Exception.Message)
        return
    }
    $state.OutputFolder = $paths.ScriptOutputRoot
    Write-NetworkDiagGuiRunPointers -Paths $paths -State $state
    $script:App.Run.CurrentRunFolder = $paths.LauncherRunRoot
    $script:App.Run.CurrentLogsFolder = $paths.LogsFolder

    $launcherLogPath = Join-Path $paths.LogsFolder "launcher.log"
    $stdoutPath = Join-Path $paths.LogsFolder "stdout.log"
    $stderrPath = Join-Path $paths.LogsFolder "stderr.log"
    $paramsJsonPath = Join-Path $paths.LogsFolder "launch-config.json"
    $stateJsonPath = Join-Path $paths.LogsFolder "gui-state.json"
    $runnerPath = Join-Path $paths.LogsFolder "invoke-networkdiag.ps1"
    $script:App.Run.CurrentLaunchConfigPath = $paramsJsonPath
    $script:App.Run.CurrentGuiStatePath = $stateJsonPath

    $paramMap = ConvertTo-NetworkDiagGuiParamMap -State $state
    [System.IO.File]::WriteAllText($paramsJsonPath, ($paramMap | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding $false))
    Write-NetworkDiagGuiStateDocument -Path $stateJsonPath -State $state
    $runnerScript = New-NetworkDiagGuiRunnerScriptContent -ScriptPath $scriptPath -JsonPath $paramsJsonPath
    [System.IO.File]::WriteAllText($runnerPath, $runnerScript, (New-Object System.Text.UTF8Encoding $false))

    Write-NetworkDiagGuiLogLine -Path $launcherLogPath -Text "Starting run. launcherRun=$($paths.LauncherRunRoot)"
    Append-NetworkDiagGuiLiveLog "Launcher run folder: $($paths.LauncherRunRoot)"
    Append-NetworkDiagGuiLiveLog "Logs folder: $($paths.LogsFolder)"

    $launch = New-NetworkDiagGuiLaunchCommand -RunnerPath $runnerPath
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $launch.FileName
    $psi.Arguments = $launch.Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $launch.WorkingDirectory

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
            $script:App.Run.CurrentRunFolder = $Matches[1].Trim()
            $recent = if ($script:App.Run.RecentRuns.Count -gt 0) { $script:App.Run.RecentRuns[0] } else { $null }
            if ($recent -and $recent.LauncherRunRoot -eq $paths.LauncherRunRoot) {
                $recent.ScriptRunFolder = $script:App.Run.CurrentRunFolder
                Refresh-NetworkDiagGuiRecentRuns
            }
        }
        Append-NetworkDiagGuiLiveLog $e.Data
    }
    $errHandler = [System.Diagnostics.DataReceivedEventHandler]{
        param($sender, $e)
        if ($null -eq $e.Data) { return }
        Add-Content -LiteralPath $stderrPath -Value $e.Data -Encoding UTF8
        Write-NetworkDiagGuiLogLine -Path $launcherLogPath -Text ("ERR " + $e.Data)
        $script:App.Health.LastUpdate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Update-NetworkDiagGuiHealthUi
        Append-NetworkDiagGuiLiveLog ("[stderr] " + $e.Data)
    }
    $exitHandler = [System.EventHandler]{
        param($sender, $e)
        $code = $sender.ExitCode
        $script:App.Run.CurrentProcess = $null
        Write-NetworkDiagGuiLogLine -Path $launcherLogPath -Text "Process exited with code $code"
        $recent = if ($script:App.Run.RecentRuns.Count -gt 0) { $script:App.Run.RecentRuns[0] } else { $null }
        if ($recent -and $recent.LauncherRunRoot -eq $paths.LauncherRunRoot) {
            $recent.ExitCode = $code
            Refresh-NetworkDiagGuiRecentRuns
        }
        $analysisRunFolder = ""
        if ($recent -and $recent.ScriptRunFolder) {
            $analysisRunFolder = [string]$recent.ScriptRunFolder
        } elseif ($script:App.Run.CurrentRunFolder) {
            $analysisRunFolder = [string]$script:App.Run.CurrentRunFolder
        }
        Set-NetworkDiagGuiQuickAnalysisText -Text (Build-NetworkDiagGuiQuickAnalysis -RunFolder $analysisRunFolder -ExitCode $code)
        Update-NetworkDiagGuiIncidentInsightsFromRunFolder -RunFolder $analysisRunFolder
        if ($script:App.Run.StopRequested) {
            Set-NetworkDiagGuiRunState -State "Cancelled" -Message "Run stopped by user. Exit code: $code"
        } elseif ($code -eq 0) {
            Set-NetworkDiagGuiRunState -State "Completed" -Message "Run finished. Exit code: 0"
        } else {
            Set-NetworkDiagGuiRunState -State "Failed" -Message "Run finished with exit code: $code"
        }
        $script:App.Run.StopRequested = $false
        Set-NetworkDiagGuiStatus "Run finished. Exit code: $code. Logs: $script:App.Run.CurrentLogsFolder"
        Append-NetworkDiagGuiLiveLog "Run complete. Exit code: $code"
        if ($script:App.Ui.Controls.ContainsKey("MainTabs")) {
            $script:App.Ui.Window.Dispatcher.Invoke([Action]{ $script:App.Ui.Controls.MainTabs.SelectedIndex = 2 })
        }
        Invoke-NetworkDiagGuiHook -Hooks $script:App.Hooks -EventName "RunFinished" -Payload @{ ExitCode = $code; RunFolder = $analysisRunFolder }
    }

    $p.add_OutputDataReceived($outHandler)
    $p.add_ErrorDataReceived($errHandler)
    $p.add_Exited($exitHandler)

    try {
        $null = $p.Start()
        $p.BeginOutputReadLine()
        $p.BeginErrorReadLine()
    } catch {
        Set-NetworkDiagGuiRunState -State "Failed" -Message ("Failed to start diagnostic process: " + $_.Exception.Message)
        Write-NetworkDiagGuiLogLine -Path $launcherLogPath -Text ("START_FAIL " + $_.Exception.Message)
        Set-NetworkDiagGuiStatus "Run failed to start. Check launcher log: $launcherLogPath"
        return
    }
    $script:App.Run.CurrentProcess = $p
    Append-NetworkDiagGuiLiveLog "Runner PID: $($p.Id)"
    Add-NetworkDiagGuiRecentRun -Item @{
        StartedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        LauncherRunRoot = $paths.LauncherRunRoot
        LogsFolder = $paths.LogsFolder
        ScriptRunFolder = ""
        StateConfigPath = $stateJsonPath
        LaunchConfigPath = $paramsJsonPath
        ExitCode = $null
    }
    Set-NetworkDiagGuiRunState -State "Running" -Message "Run started."
    if ($script:App.Ui.Controls.ContainsKey("MainTabs")) {
        $script:App.Ui.Window.Dispatcher.Invoke([Action]{ $script:App.Ui.Controls.MainTabs.SelectedIndex = 1 })
    }
    Invoke-NetworkDiagGuiHook -Hooks $script:App.Hooks -EventName "RunStarted" -Payload @{ LauncherRunRoot = $paths.LauncherRunRoot }
}
