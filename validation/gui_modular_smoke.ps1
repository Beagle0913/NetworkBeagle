#Requires -Version 5.1
<#
.SYNOPSIS
    Basic smoke validation for modular GUI launcher scripts.

.DESCRIPTION
    Parses GUI entrypoint and all gui/core modules, and confirms the XAML file
    can be loaded by the WPF XamlReader.
#>

param(
    [string]$ProjectRoot = $PSScriptRoot + "\.."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-ParseFile {
    param([string]$Path)
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) {
        throw "Parse error in $Path : $($parseErrors[0].Message)"
    }
}

$entryPath = Join-Path $ProjectRoot "network-stability-test-gui.ps1"
Test-ParseFile -Path $entryPath

$coreRoot = Join-Path $ProjectRoot "gui\core"
$moduleFiles = @(
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
)
foreach ($name in $moduleFiles) {
    Test-ParseFile -Path (Join-Path $coreRoot $name)
}

Add-Type -AssemblyName PresentationFramework
$xamlPath = Join-Path $ProjectRoot "gui\ui\layout.xaml"
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

. (Join-Path $coreRoot "layout.ps1")
. (Join-Path $coreRoot "run-service.ps1")

$missingControls = [System.Collections.Generic.List[string]]::new()
foreach ($name in (Get-NetworkDiagGuiControlNames)) {
    if ($null -eq $window.FindName($name)) {
        [void]$missingControls.Add($name)
    }
}
if ($missingControls.Count -gt 0) {
    throw "XAML/control lookup mismatch. Missing controls: $($missingControls -join ', ')"
}

$runnerScript = New-NetworkDiagGuiRunnerScriptContent -ScriptPath "C:\tool\network-stability-test.ps1" -JsonPath "C:\tool\launch-config.json"
if ($runnerScript -notmatch "ConvertFrom-Json" -or $runnerScript -notmatch "@params") {
    throw "Runner script construction check failed."
}

$launch = New-NetworkDiagGuiLaunchCommand -RunnerPath "C:\tool\invoke-networkdiag.ps1"
if ($launch.FileName -ne "powershell.exe") {
    throw "Launch command file name mismatch."
}
if ($launch.Arguments -notmatch "ExecutionPolicy Bypass" -or $launch.Arguments -notmatch "invoke-networkdiag.ps1") {
    throw "Launch command arguments mismatch."
}

Write-Host "GUI modular smoke checks passed."
