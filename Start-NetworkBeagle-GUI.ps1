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

    # Array ArgumentList avoids quoting bugs when repo path contains spaces
    $psArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $guiScriptPath
    )
    Start-Process -FilePath $psExe -ArgumentList $psArgs -WorkingDirectory $PSScriptRoot | Out-Null
    exit 0
} catch {
    Show-LauncherMessage -Text ("Unexpected launcher error:`n" + $_.Exception.Message) -Title "NetworkBeagle Launcher Error" -Icon ([System.Windows.MessageBoxImage]::Error)
    exit 1
}
