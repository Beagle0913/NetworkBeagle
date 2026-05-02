# lib/isp-bundle.ps1
# ISP evidence bundle. Produced at the tail of the outer finally (after the
# run's main report is composed) so we can package everything an ISP ticket
# actually wants to see: cover letter, CSV, detail log, ipconfig/route/
# proxy snapshots, bounded traceroutes to each external target, public IP
# at start+end, and a SHA256 manifest. Optional zip via -IspEvidenceZip.
#
# All external commands (tracert, ipconfig /all, route print,
# netsh winhttp show proxy, Invoke-WebRequest to api.ipify.org) are
# executed through Start-NetworkDiagBoundedExternalProcess so a hung
# tool can't stall the run finish.

function Get-NetworkDiagPublicIp {
    param([int]$TimeoutSeconds = 5)
    $probe = Start-NetworkDiagBoundedExternalProcess -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-Command",
        "try { (Invoke-WebRequest -UseBasicParsing -TimeoutSec $TimeoutSeconds -Uri 'https://api.ipify.org').Content.Trim() } catch { '' }"
    ) -TimeoutSeconds ($TimeoutSeconds + 2)
    if ($probe.Ok -and $probe.StdOut) { return ($probe.StdOut.Trim()) }
    return ""
}

function Invoke-NetworkDiagTracerouteBounded {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [int]$MaxHops = 20,
        [int]$PerHopMs = 2000,
        [int]$TimeoutSeconds = 45
    )
    $args = @("-d", "-h", [string]$MaxHops, "-w", [string]$PerHopMs, $Target)
    return Start-NetworkDiagBoundedExternalProcess -FilePath "tracert" -ArgumentList $args -TimeoutSeconds $TimeoutSeconds
}

function Compose-NetworkDiagIspCoverLetter {
    param(
        [hashtable]$Stats,
        [hashtable]$Cfg,
        [hashtable]$Findings,
        [string]$PublicIpStart,
        [string]$PublicIpEnd
    )
    $lines = @()
    $lines += "ISP EVIDENCE COVER LETTER"
    $lines += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += "Run window: $($Cfg.RunStartTime) to $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') (requested $($Cfg.DurationMinutes) minutes)"
    $lines += "Tool: network-stability-test.ps1 (ICMP + TCP/443, cycle-based)"
    $lines += ""
    $lines += "Totals (committed cycles):"
    $lines += "  All OK:          $($Stats.AllOK)"
    $lines += "  ISP Faults:      $($Stats.ISP_Fault)"
    $lines += "  Local Faults:    $($Stats.Local_Fault)"
    $lines += "  Anomalies:       $($Stats.Anomaly)"
    $lines += "  Total committed: $($Stats.CyclesCommitted) of $($Stats.CyclesAttempted) attempted"
    $lines += ""
    $lines += "Public IP: start=$(if ($PublicIpStart) { $PublicIpStart } else { 'n/a' })  end=$(if ($PublicIpEnd) { $PublicIpEnd } else { 'n/a' })"
    $lines += ""
    $lines += "Local health snapshot:"
    $lines += "  Max NIC deltas seen: RxErr=$($Stats.MaxRxErrDelta) RxDisc=$($Stats.MaxRxDiscDelta) TxErr=$($Stats.MaxTxErrDelta)"
    $lines += "  Adapter-not-Up cycles: $($Stats.AdapterNotUpCycles)"
    $lines += "  Link-speed change events: $($Stats.LinkSpeedChangeCycles)"
    $lines += "  Cycles with any config-audit finding: $($Stats.ConfigAuditFindingCycles)"
    $lines += "  Cycles with any cable/NIC hint:       $($Stats.CableHintCycles)"
    $lines += "  Multi-NIC cross-check: run=$($Stats.MultiNicCrossCheckCycles)  PRIMARY_LINK_SUSPECT=$($Stats.PrimaryLinkSuspectCycles)"
    $lines += ""
    $lines += "Interpretation hints (to read the attached CSV):"
    $lines += "  Verdict column: OK / ISP_FAULT / LOCAL_FAULT / ANOMALY."
    $lines += "  Evidence column carries mix codes: ICMP_ONLY, ICMP_TCP_ALIGN, TCP_OK_ICMP_FAIL, ICMP_OK_TCP_FAIL, VPN_*, GW_ICMP_POLICY+*, NIC_DELTA, DNS_FAIL, PRIMARY_LINK_SUSPECT."
    $lines += "  ISP_FAULT cycles: gateway ICMP OK while most external ICMP failed within the same cycle."
    $lines += "  LOCAL_FAULT cycles: gateway ICMP also failed; problem is likely PC/cable/NIC/router-LAN-side."
    $lines += ""
    $lines += "Ready-to-send ask:"
    if ($Stats.ISP_Fault -gt 0 -and $Stats.Local_Fault -eq 0) {
        $lines += "  Please investigate upstream/WAN during the ISP_FAULT cycles listed in 03_network_log.csv. Gateway ICMP to our router stayed up throughout those windows while external ICMP to $(($Cfg.ExternalTargets | ForEach-Object { $_.Host }) -join ', ') failed for a majority of attempts. Public IP, traceroutes, and route table at bundle time are included."
    } elseif ($Stats.ISP_Fault -gt 0 -and $Stats.Local_Fault -gt 0) {
        $lines += "  Mixed local + beyond-LAN pattern. Please compare the ISP_FAULT cycles with your WAN logs; the LOCAL_FAULT cycles will be addressed on our side (cable / NIC / router LAN)."
    } elseif ($Stats.Local_Fault -gt 0) {
        $lines += "  Majority of faults look local (LAN-side) this run. We are already investigating cable / NIC / router-LAN; please hold upstream diagnostics unless a fresh run shows ISP_FAULT cycles."
    } else {
        $lines += "  Run completed without clearly ISP-classified faults. Attaching the bundle for your records; please keep on file for the next run if issues recur."
    }
    return ($lines -join "`r`n")
}

function Write-NetworkDiagIspEvidenceBundle {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Stats,
        [Parameter(Mandatory = $true)][hashtable]$Cfg,
        [hashtable]$Findings = @{},
        [Parameter(Mandatory = $true)][string]$OutputFolder,
        [string]$ReportPath = "",
        [string]$CsvPath = "",
        [string]$DetailPath = "",
        [string]$IpconfigStartPath = "",
        [string]$PublicIpStart = "",
        [switch]$Zip
    )
    $ts = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $bundleDir = Join-Path $OutputFolder "ispevidence_$ts"
    try {
        New-Item -ItemType Directory -Path $bundleDir -Force -ErrorAction Stop | Out-Null
    } catch {
        return @{ Path = ""; ZipPath = ""; Error = $_.Exception.Message }
    }
    $enc = New-Object System.Text.UTF8Encoding $false

    $publicEnd = Get-NetworkDiagPublicIp -TimeoutSeconds 5
    $cover = Compose-NetworkDiagIspCoverLetter -Stats $Stats -Cfg $Cfg -Findings $Findings -PublicIpStart $PublicIpStart -PublicIpEnd $publicEnd
    [System.IO.File]::WriteAllText((Join-Path $bundleDir "01_cover_letter.txt"), $cover, $enc)

    if ($ReportPath -and (Test-Path -LiteralPath $ReportPath)) {
        Copy-Item -LiteralPath $ReportPath -Destination (Join-Path $bundleDir "02_report.txt") -ErrorAction SilentlyContinue
    }
    if ($CsvPath -and (Test-Path -LiteralPath $CsvPath)) {
        Copy-Item -LiteralPath $CsvPath -Destination (Join-Path $bundleDir "03_network_log.csv") -ErrorAction SilentlyContinue
    }
    if ($DetailPath -and (Test-Path -LiteralPath $DetailPath)) {
        Copy-Item -LiteralPath $DetailPath -Destination (Join-Path $bundleDir "04_detail.log") -ErrorAction SilentlyContinue
    }
    if ($IpconfigStartPath -and (Test-Path -LiteralPath $IpconfigStartPath)) {
        Copy-Item -LiteralPath $IpconfigStartPath -Destination (Join-Path $bundleDir "05_ipconfig_start.txt") -ErrorAction SilentlyContinue
    } else {
        $start = Start-NetworkDiagBoundedExternalProcess -FilePath "ipconfig" -ArgumentList @("/all") -TimeoutSeconds 10
        if ($start.Ok) {
            [System.IO.File]::WriteAllText((Join-Path $bundleDir "05_ipconfig_start.txt"), $start.StdOut, $enc)
        }
    }
    $ipEnd = Start-NetworkDiagBoundedExternalProcess -FilePath "ipconfig" -ArgumentList @("/all") -TimeoutSeconds 10
    if ($ipEnd.Ok) {
        [System.IO.File]::WriteAllText((Join-Path $bundleDir "06_ipconfig_end.txt"), $ipEnd.StdOut, $enc)
    }
    $route = Start-NetworkDiagBoundedExternalProcess -FilePath "route" -ArgumentList @("print") -TimeoutSeconds 10
    if ($route.Ok) {
        [System.IO.File]::WriteAllText((Join-Path $bundleDir "07_route_table_end.txt"), $route.StdOut, $enc)
    }
    $proxy = Start-NetworkDiagBoundedExternalProcess -FilePath "netsh" -ArgumentList @("winhttp", "show", "proxy") -TimeoutSeconds 8
    if ($proxy.Ok) {
        [System.IO.File]::WriteAllText((Join-Path $bundleDir "08_winhttp_proxy.txt"), $proxy.StdOut, $enc)
    }
    $traceDir = Join-Path $bundleDir "09_traceroutes"
    try { New-Item -ItemType Directory -Path $traceDir -Force | Out-Null } catch { }
    foreach ($t in $Cfg.ExternalTargets) {
        if (-not $t.IcmpTarget) { continue }
        $safeName = (($t.Name -replace '[^A-Za-z0-9_.-]', '_'))
        $tr = Invoke-NetworkDiagTracerouteBounded -Target ([string]$t.IcmpTarget) -TimeoutSeconds 45
        $body = if ($tr.Ok) { $tr.StdOut } else { "Traceroute failed or timed out.`n$($tr.StdErr)" }
        [System.IO.File]::WriteAllText((Join-Path $traceDir "$safeName.txt"), $body, $enc)
    }
    $pubBody = "Start: $(if ($PublicIpStart) { $PublicIpStart } else { 'n/a' })`r`nEnd:   $(if ($publicEnd) { $publicEnd } else { 'n/a' })`r`n"
    [System.IO.File]::WriteAllText((Join-Path $bundleDir "10_public_ip.txt"), $pubBody, $enc)

    try {
        $manifest = New-Object System.Text.StringBuilder
        $files = Get-ChildItem -LiteralPath $bundleDir -Recurse -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            try {
                $h = Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue
                if ($h) {
                    $rel = $f.FullName.Substring($bundleDir.Length).TrimStart('\', '/')
                    [void]$manifest.AppendLine("$($h.Hash)  $rel")
                }
            } catch { }
        }
        [System.IO.File]::WriteAllText((Join-Path $bundleDir "11_sha256.txt"), $manifest.ToString(), $enc)
    } catch { }

    $zipPath = ""
    if ($Zip) {
        try {
            $zipPath = "$bundleDir.zip"
            if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
            Compress-Archive -Path (Join-Path $bundleDir "*") -DestinationPath $zipPath -Force -ErrorAction Stop
        } catch {
            $zipPath = ""
        }
    }
    return @{ Path = $bundleDir; ZipPath = $zipPath; Error = "" }
}
