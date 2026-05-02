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

function Get-NetworkDiagGuiRunTransitionMap {
    return @{
        Idle = @("Idle", "Validating", "Starting")
        Validating = @("Idle", "Starting", "Failed")
        Starting = @("Idle", "Running", "Failed")
        Running = @("Stopping", "Completed", "Failed")
        Stopping = @("Completed", "Failed")
        Completed = @("Idle", "Validating", "Starting")
        Failed = @("Idle", "Validating", "Starting")
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
`$params = ConvertFrom-Json -InputObject `$json -AsHashtable
& `$scriptPath @params
"@
}

function New-NetworkDiagGuiLaunchCommand {
    param([string]$RunnerPath)

    return @{
        FileName = "powershell.exe"
        Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$RunnerPath`""
        WorkingDirectory = $PSScriptRoot
    }
}

function Get-NetworkDiagGuiScriptPath {
    $p = Join-Path $PSScriptRoot "network-stability-test.ps1"
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        throw "Could not find network-stability-test.ps1 next to GUI launcher: $p"
    }
    return $p
}

function Append-NetworkDiagGuiLiveLog {
    param([string]$Line)
    $window = $script:App.Ui.Window
    $controls = $script:App.Ui.Controls
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
    $isRunning = ($script:App.Run.CurrentProcess -and -not $script:App.Run.CurrentProcess.HasExited)
    $controls.RunNormal.IsEnabled = (-not $isRunning) -and (-not $script:App.Run.ValidationHasErrors)
    $controls.RunAdmin.IsEnabled = (-not $isRunning) -and (-not $script:App.Run.ValidationHasErrors)
    $controls.StopRun.IsEnabled = $isRunning
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
    $status = if ($Message) { "${State}: $Message" } else { $State }
    if ($requestedState -ne $State) {
        $status = "${requestedState}: $Message"
    }
    Set-NetworkDiagGuiStatus -Text $status
    Update-NetworkDiagGuiActionButtons
}

function Refresh-NetworkDiagGuiRecentRuns {
    $controls = $script:App.Ui.Controls
    $controls.RecentRunsList.Items.Clear()
    foreach ($item in $script:App.Run.RecentRuns) {
        $exitCodeLabel = if ($null -eq $item.ExitCode) { "running" } else { "exit=$($item.ExitCode)" }
        $display = "{0}  ({1})  {2}" -f $item.StartedAt, $exitCodeLabel, $item.LauncherRunRoot
        [void]$controls.RecentRunsList.Items.Add($display)
    }
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

function Stop-NetworkDiagGuiRun {
    if (-not $script:App.Run.CurrentProcess -or $script:App.Run.CurrentProcess.HasExited) {
        Set-NetworkDiagGuiRunState -State "Idle" -Message "No active run."
        return
    }
    $script:App.Run.StopRequested = $true
    Set-NetworkDiagGuiRunState -State "Stopping" -Message "Stopping active process..."
    try {
        $script:App.Run.CurrentProcess.Kill()
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
    } else {
        Set-NetworkDiagGuiStatus "Validation passed."
    }

    Invoke-NetworkDiagGuiHook -Hooks $script:App.Hooks -EventName "RunStarting" -Payload @{ PreferAdmin = [bool]$PreferAdmin; State = $state }

    if ($PreferAdmin -and -not $script:App.Context.IsAdminGui) {
        try {
            $cfg = Save-NetworkDiagGuiConfig -State $state
            $args = @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", "`"$script:App.Context.CommandPath`"",
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

    Set-NetworkDiagGuiRunState -State "Starting" -Message "Preparing run folders and launch command..."

    $paths = $null
    try {
        $paths = New-NetworkDiagGuiLauncherPaths -BaseRoot $state.OutputRoot
    } catch {
        [System.Windows.MessageBox]::Show("Could not create launcher run folders: $($_.Exception.Message)", "Output folder error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        Set-NetworkDiagGuiRunState -State "Failed" -Message ("Failed to prepare run folders: " + $_.Exception.Message)
        return
    }
    $state.OutputFolder = $paths.ScriptOutputRoot
    $script:App.Run.CurrentRunFolder = $paths.LauncherRunRoot
    $script:App.Run.CurrentLogsFolder = $paths.LogsFolder

    $launcherLogPath = Join-Path $paths.LogsFolder "launcher.log"
    $stdoutPath = Join-Path $paths.LogsFolder "stdout.log"
    $stderrPath = Join-Path $paths.LogsFolder "stderr.log"
    $paramsJsonPath = Join-Path $paths.LogsFolder "launch-config.json"
    $stateJsonPath = Join-Path $paths.LogsFolder "gui-state.json"
    $runnerPath = Join-Path $paths.LogsFolder "invoke-networkdiag.ps1"

    $paramMap = ConvertTo-NetworkDiagGuiParamMap -State $state
    [System.IO.File]::WriteAllText($paramsJsonPath, ($paramMap | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllText($stateJsonPath, ($state | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding $false))
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
            Set-NetworkDiagGuiRunState -State "Completed" -Message "Run stopped by user. Exit code: $code"
        } elseif ($code -eq 0) {
            Set-NetworkDiagGuiRunState -State "Completed" -Message "Run finished. Exit code: 0"
        } else {
            Set-NetworkDiagGuiRunState -State "Failed" -Message "Run finished with exit code: $code"
        }
        $script:App.Run.StopRequested = $false
        Set-NetworkDiagGuiStatus "Run finished. Exit code: $code. Logs: $script:App.Run.CurrentLogsFolder"
        Append-NetworkDiagGuiLiveLog "Run complete. Exit code: $code"
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
    Add-NetworkDiagGuiRecentRun -Item @{
        StartedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        LauncherRunRoot = $paths.LauncherRunRoot
        LogsFolder = $paths.LogsFolder
        ScriptRunFolder = ""
        StateConfigPath = $stateJsonPath
        ExitCode = $null
    }
    Set-NetworkDiagGuiRunState -State "Running" -Message "Run started."
    Invoke-NetworkDiagGuiHook -Hooks $script:App.Hooks -EventName "RunStarted" -Payload @{ LauncherRunRoot = $paths.LauncherRunRoot }
}
