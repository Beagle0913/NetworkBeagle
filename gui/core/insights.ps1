function Set-NetworkDiagGuiQuickAnalysisText {
    param([string]$Text)
    $window = $script:App.Ui.Window
    $controls = $script:App.Ui.Controls
    $window.Dispatcher.Invoke([Action]{
        $controls.QuickAnalysis.Text = $Text
    })
}

function Reset-NetworkDiagGuiIncidentInsights {
    $window = $script:App.Ui.Window
    $controls = $script:App.Ui.Controls
    $window.Dispatcher.Invoke([Action]{
        $controls.IncidentReasonText.Text = "Top incident reasons: n/a"
        $controls.IncidentReasonText.Foreground = "DimGray"
        $controls.EpisodeTimelineList.Items.Clear()
        [void]$controls.EpisodeTimelineList.Items.Add("No completed run timeline available yet.")
    })
}

function Set-NetworkDiagGuiIncidentInsights {
    param(
        [string]$ReasonSummary,
        [string[]]$TimelineItems
    )
    $window = $script:App.Ui.Window
    $controls = $script:App.Ui.Controls
    $window.Dispatcher.Invoke([Action]{
        $controls.IncidentReasonText.Text = $ReasonSummary
        $controls.IncidentReasonText.Foreground = if ($ReasonSummary -match "none|n/a") { "DimGray" } else { "DarkSlateBlue" }
        $controls.EpisodeTimelineList.Items.Clear()
        if ($TimelineItems -and $TimelineItems.Count -gt 0) {
            foreach ($item in $TimelineItems) { [void]$controls.EpisodeTimelineList.Items.Add($item) }
        } else {
            [void]$controls.EpisodeTimelineList.Items.Add("No timeline events available in summary.")
        }
    })
}

function Get-NetworkDiagGuiSummaryPath {
    param([string]$RunFolder)
    if (-not $RunFolder -or -not (Test-Path -LiteralPath $RunFolder -PathType Container)) { return "" }
    $match = Get-ChildItem -LiteralPath $RunFolder -Filter "network_summary_*.json" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($match) { return $match.FullName }
    return ""
}

function Update-NetworkDiagGuiIncidentInsightsFromRunFolder {
    param([string]$RunFolder)
    $summaryPath = Get-NetworkDiagGuiSummaryPath -RunFolder $RunFolder
    if (-not $summaryPath) {
        Set-NetworkDiagGuiIncidentInsights -ReasonSummary "Top incident reasons: n/a (summary JSON not found)" -TimelineItems @("Run folder: $RunFolder")
        return
    }
    try {
        $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $reasonCounts = @{}
        foreach ($raw in @($summary.incidents.sample)) {
            if (-not $raw) { continue }
            $line = [string]$raw
            $code = "UNCLASSIFIED"
            if ($line -match "^\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?\s+([A-Z0-9_]+)\b") {
                $code = $Matches[1]
            }
            if (-not $reasonCounts.ContainsKey($code)) { $reasonCounts[$code] = 0 }
            $reasonCounts[$code] = [int]$reasonCounts[$code] + 1
        }

        $orderedReasons = @($reasonCounts.GetEnumerator() | Sort-Object -Property @("Value","Name") -Descending | Select-Object -First 3)
        $reasonSummary = if ($orderedReasons.Count -gt 0) {
            "Top incident reasons: " + (($orderedReasons | ForEach-Object { "$($_.Key) x$($_.Value)" }) -join ", ")
        } else {
            "Top incident reasons: none captured in summary sample."
        }

        $timeline = [System.Collections.Generic.List[string]]::new()
        if ([int]$summary.episodes.completed -gt 0) {
            foreach ($ep in @($summary.episodes.sample)) {
                if ($ep) { $timeline.Add("[Episode] " + [string]$ep) }
            }
            if ($timeline.Count -eq 0) {
                $timeline.Add("[Episode] Completed episodes: $($summary.episodes.completed) (details truncated/not sampled)")
            }
        } else {
            $timeline.Add("[Episode] Completed episodes: 0")
        }
        foreach ($evt in @($summary.incidents.sample)) {
            if ($evt) { $timeline.Add("[Incident] " + [string]$evt) }
        }
        Set-NetworkDiagGuiIncidentInsights -ReasonSummary $reasonSummary -TimelineItems @($timeline)
    } catch {
        Set-NetworkDiagGuiIncidentInsights -ReasonSummary ("Top incident reasons: parse error - " + $_.Exception.Message) -TimelineItems @("Summary path: $summaryPath")
    }
}

function Build-NetworkDiagGuiQuickAnalysis {
    param(
        [string]$RunFolder,
        [int]$ExitCode
    )
    $summaryPath = Get-NetworkDiagGuiSummaryPath -RunFolder $RunFolder
    if (-not $summaryPath) {
        return "Quick analysis unavailable: summary JSON not found. Exit code=$ExitCode.`r`nRun folder: $RunFolder"
    }

    try {
        $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("Summary source: $summaryPath")
        $lines.Add("Result mix: OK=$($summary.cycles.pctAllOk)% ISP=$($summary.cycles.pctIspFault)% Local=$($summary.cycles.pctLocalFault)% Anomaly=$($summary.cycles.pctAnomaly)%")
        $dnsPass = if ([int]$summary.cycles.committed -gt 0) { [math]::Round(100.0 * ([int]$summary.cycles.committed - [int]$summary.pcLink.dnsFailCycles) / [int]$summary.cycles.committed, 0) } else { 0 }
        $gwFail = [int]$summary.cycles.committed - [int]$summary.latency.gateway.count
        $gwPass = if ([int]$summary.cycles.committed -gt 0) { [math]::Round(100.0 * ([int]$summary.latency.gateway.count) / [int]$summary.cycles.committed, 0) } else { 0 }
        $tcpPass = if ([int]$summary.cycles.committed -gt 0) { [math]::Round(100.0 * (([int]$summary.cycles.committed) - [int]$summary.pcLink.icmpUpTcpDownCycles) / [int]$summary.cycles.committed, 0) } else { 0 }
        $lines.Add("Reliability estimate: DNS=$dnsPass% Gateway=$gwPass% TCP-Path~$tcpPass% (committed-window estimate)")

        if ([int]$summary.cycles.pctAllOk -ge 95) {
            $lines.Add("Likely state: stable window; no dominant link-path degradation.")
        } elseif ([int]$summary.cycles.pctIspFault -gt [int]$summary.cycles.pctLocalFault) {
            $lines.Add("Likely state: upstream/ISP-side instability is dominant.")
        } elseif ([int]$summary.cycles.pctLocalFault -gt 0) {
            $lines.Add("Likely state: local LAN/NIC/router segment contributes to failures.")
        } else {
            $lines.Add("Likely state: mixed or transient anomalies; inspect incident episodes.")
        }

        if ([int]$summary.pcLink.dnsFailCycles -gt 0) {
            $lines.Add("Signal: DNS failures observed ($($summary.pcLink.dnsFailCycles) cycles).")
        }
        if ($gwFail -gt 0) {
            $lines.Add("Signal: gateway ICMP not answered on $gwFail committed cycle(s).")
        }
        if ([int]$summary.tls.tcpUpTlsDownCycles -gt 0) {
            $lines.Add("Signal: TCP-up/TLS-down cycles ($($summary.tls.tcpUpTlsDownCycles)) suggest TLS interception/certificate/time issues.")
        }
        if ([int]$summary.pcLink.icmpDownTcpUpCycles -gt 0) {
            $lines.Add("Signal: ICMP-down while TCP-up cycles ($($summary.pcLink.icmpDownTcpUpCycles)) indicate protocol-specific filtering/de-prioritization.")
        }
        if ([int]$summary.pcLink.icmpUpTcpDownCycles -gt 0) {
            $lines.Add("Signal: TCP failures while ICMP survives ($($summary.pcLink.icmpUpTcpDownCycles)) indicate app-layer path/port filtering risk.")
        }
        if ($summary.configAudit.lastCodes -and $summary.configAudit.lastCodes.Count -gt 0) {
            $lines.Add("Config audit latest codes: " + (($summary.configAudit.lastCodes | Where-Object { $_ }) -join ", "))
        }
        if ($summary.cableHints.lastCodes -and $summary.cableHints.lastCodes.Count -gt 0) {
            $lines.Add("Cable/NIC latest hints: " + (($summary.cableHints.lastCodes | Where-Object { $_ }) -join ", "))
        }
        $lines.Add("Committed cycles: $($summary.cycles.committed) | Attempted cycles: $($summary.cycles.attempted)")
        $lines.Add("Exit code: $ExitCode")
        $analysisText = ($lines -join [Environment]::NewLine)
        Invoke-NetworkDiagGuiHook -Hooks $script:App.Hooks -EventName "AnalysisReady" -Payload @{ RunFolder = $RunFolder; Text = $analysisText }
        return $analysisText
    } catch {
        return "Quick analysis failed: $($_.Exception.Message)`r`nSummary path: $summaryPath"
    }
}
