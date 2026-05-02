#Requires -Version 5.1
<#
.SYNOPSIS
    WPF launcher for network-stability-test.ps1.

.DESCRIPTION
    Modular GUI entrypoint that wires core modules and starts the launcher app.
#>

param(
    [switch]$ElevatedLaunch,
    [string]$ConfigPath = "",
    [switch]$AutoRunElevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Repo root (folder containing this script). GUI modules live under gui\core; default paths must not use that folder.
$script:NetworkDiagGuiRepoRoot = $PSScriptRoot

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$guiRoot = Join-Path $PSScriptRoot "gui\core"
foreach ($moduleFile in @(
    "hooks.ps1",
    "layout.ps1",
    "state.ps1",
    "profiles.ps1",
    "validation.ps1",
    "health-dashboard.ps1",
    "insights.ps1",
    "run-service.ps1",
    "ui-events.ps1",
    "bootstrap.ps1"
)) {
    $modulePath = Join-Path $guiRoot $moduleFile
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Missing GUI module: $modulePath"
    }
    . $modulePath
}

$script:NetworkDiagGuiEntryPath = $PSCommandPath
Start-NetworkDiagGuiApp -ElevatedLaunch:$ElevatedLaunch -ConfigPath $ConfigPath -AutoRunElevated:$AutoRunElevated
