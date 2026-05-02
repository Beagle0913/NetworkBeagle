#Requires -Version 5.1
<#
.SYNOPSIS
    Concatenate lib/*.ps1 + the main network-stability-test.ps1 entrypoint into
    a single portable network-stability-test.single.ps1 that has no dot-source
    dependencies. Useful for hand-off to people who cannot ship a folder.

.DESCRIPTION
    Produces a single script with:
      1. The entrypoint's comment-based help + param block (unchanged)
      2. Inlined lib/*.ps1 in the same load order the entrypoint uses
      3. The entrypoint body (dot-source loop replaced by a marker comment)

    Does not strip comments or pretty-print. The output is meant to be
    behaviorally identical to the split version.

.PARAMETER OutputPath
    Destination file. Defaults to network-stability-test.single.ps1 alongside
    this tool's parent (the project root).
#>

param(
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$entryPath = Join-Path $projectRoot "network-stability-test.ps1"
$libDir = Join-Path $projectRoot "lib"

if (-not (Test-Path -LiteralPath $entryPath)) {
    Write-Host "ERROR: Cannot find entrypoint at $entryPath" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $libDir)) {
    Write-Host "ERROR: Cannot find lib folder at $libDir" -ForegroundColor Red
    exit 1
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $projectRoot "network-stability-test.single.ps1"
}

$libOrder = @('common.ps1', 'latency.ps1', 'probes.ps1', 'routing.ps1', 'report.ps1', 'cycle.ps1', 'config-audit.ps1', 'cable-hints.ps1', 'multinic.ps1', 'wifi-signal.ps1', 'isp-bundle.ps1', 'summary-json.ps1', 'udp-probe.ps1', 'tcp-session.ps1', 'auto-capture.ps1')

$entryText = [System.IO.File]::ReadAllText($entryPath)

$dotsourceBlockPattern = '(?s)# >>> NETDIAG_BUNDLE_DOTSOURCE_BEGIN <<<.*?# >>> NETDIAG_BUNDLE_DOTSOURCE_END <<<\r?\n'
$marker = "# ==== Inlined library (bundled) ====`r`n# (Single-file build: lib/*.ps1 were concatenated above; no dot-source needed.)`r`n"

if ($entryText -notmatch $dotsourceBlockPattern) {
    Write-Host "ERROR: Could not locate the dot-source marker block in the entrypoint. Keep the NETDIAG_BUNDLE_DOTSOURCE_BEGIN/END marker comments intact." -ForegroundColor Red
    exit 2
}

$sb = New-Object System.Text.StringBuilder
$pre = [regex]::Split($entryText, $dotsourceBlockPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
if ($pre.Count -ne 2) {
    Write-Host "ERROR: Unexpected number of regex split segments: $($pre.Count)" -ForegroundColor Red
    exit 2
}

[void]$sb.Append($pre[0])

[void]$sb.AppendLine("# ==== Inlined library (bundled build; do not edit between markers) ====")
foreach ($f in $libOrder) {
    $p = Join-Path $libDir $f
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host "ERROR: Missing lib file: $p" -ForegroundColor Red
        exit 3
    }
    $body = [System.IO.File]::ReadAllText($p)
    [void]$sb.AppendLine("# --- BEGIN lib/$f ---")
    [void]$sb.AppendLine($body)
    [void]$sb.AppendLine("# --- END lib/$f ---")
    [void]$sb.AppendLine("")
}
[void]$sb.AppendLine("# ==== End inlined library ====")
[void]$sb.AppendLine("")

[void]$sb.Append($marker)
[void]$sb.Append($pre[1])

$enc = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($OutputPath, $sb.ToString(), $enc)

Write-Host "Wrote $OutputPath" -ForegroundColor Green
Write-Host "Line count: $((Get-Content -LiteralPath $OutputPath).Count)" -ForegroundColor Gray
