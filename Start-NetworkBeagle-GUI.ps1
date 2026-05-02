#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName PresentationFramework

function Show-LauncherMessage {
    param(
        [string]$Text,
        [string]$Title,
        [System.Windows.MessageBoxImage]$Icon = [System.Windows.MessageBoxImage]::Information
    )
    [System.Windows.MessageBox]::Show($Text, $Title, [System.Windows.MessageBoxButton]::OK, $Icon) | Out-Null
}

try {
    $guiScriptPath = Join-Path $PSScriptRoot "network-stability-test-gui.ps1"
    if (-not (Test-Path -LiteralPath $guiScriptPath -PathType Leaf)) {
        Show-LauncherMessage -Text "Could not find GUI script at:`n$guiScriptPath`n`nPlease keep this launcher next to the project scripts." -Title "NetworkBeagle Launcher Error" -Icon ([System.Windows.MessageBoxImage]::Error)
        exit 2
    }

    # Prefer System32 Windows PowerShell 5.1 so the GUI runs even when PATH omits powershell.exe
    $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) {
        $psCmd = Get-Command -Name "powershell.exe" -ErrorAction SilentlyContinue
        if (-not $psCmd) {
            Show-LauncherMessage -Text "Windows PowerShell was not found on this system. Install PowerShell 5.1+ and retry." -Title "NetworkBeagle Launcher Error" -Icon ([System.Windows.MessageBoxImage]::Error)
            exit 3
        }
        $psExe = [string]$psCmd.Source
    }

    $launcherLogRoot = Join-Path $env:TEMP "NetworkBeagle\launcher"
    if (-not (Test-Path -LiteralPath $launcherLogRoot -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $launcherLogRoot -Force)
    }
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $stdoutPath = Join-Path $launcherLogRoot ("gui-launch-stdout_" + $stamp + ".log")
    $stderrPath = Join-Path $launcherLogRoot ("gui-launch-stderr_" + $stamp + ".log")

    # Array ArgumentList avoids quoting bugs when repo path contains spaces.
    # Use -STA because WPF requires a single-threaded apartment.
    $psArgs = @(
        "-STA",
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $guiScriptPath
    )
    $proc = Start-Process -FilePath $psExe -ArgumentList $psArgs -WorkingDirectory $PSScriptRoot -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    Start-Sleep -Milliseconds 1400
    $proc.Refresh()
    if ($proc.HasExited) {
        $stderr = ""
        if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
            $stderr = (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue)
        }
        if (-not $stderr) {
            $stderr = "The GUI process exited before opening a window. Check launcher logs in:`n$launcherLogRoot"
        }
        Show-LauncherMessage -Text ("NetworkBeagle GUI failed to start.`n`n" + $stderr) -Title "NetworkBeagle Launcher Error" -Icon ([System.Windows.MessageBoxImage]::Error)
        exit 4
    }
    exit 0
} catch {
    Show-LauncherMessage -Text ("Unexpected launcher error:`n" + $_.Exception.Message) -Title "NetworkBeagle Launcher Error" -Icon ([System.Windows.MessageBoxImage]::Error)
    exit 1
}
