# lib/summary-json.ps1
# Emits a machine-readable run summary as JSON. Designed to be consumed by
# Splunk, Grafana Loki, a CI job, or any dashboarding tool that prefers
# structured input over the text report. One file per run, written next to
# the text report in the same output folder.
#
# The shape is intentionally flat at the top level with small nested
# objects for sub-systems. PS 5.1 compatible (no using:).

function Write-NetworkDiagSummaryJson {
    <#
    Build the summary hashtable, then serialize to JSON and write to disk.
    Returns the full path written, or $null on failure.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Stats,
        [Parameter(Mandatory = $true)][hashtable]$ReportCfg,
        [Parameter(Mandatory = $true)][string]$OutputFolder,
        [string]$Timestamp = "",
        [switch]$PartialRun,
        [string]$OutputPath = ""
    )
    if (-not $Timestamp) { $Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss" }
    $path = if ($OutputPath) { $OutputPath } else { Join-Path $OutputFolder "network_summary_$Timestamp.json" }
    $den = [math]::Max([int]$Stats.CyclesCommitted, 1)

    $pctOk = [math]::Round([double]$Stats.AllOK / $den * 100, 2)
    $pctIsp = [math]::Round([double]$Stats.ISP_Fault / $den * 100, 2)
    $pctLocal = [math]::Round([double]$Stats.Local_Fault / $den * 100, 2)
    $pctAnom = [math]::Round([double]$Stats.Anomaly / $den * 100, 2)

    $extSummary = @()
    if ($ReportCfg.ExternalTargets -and $Stats.LatencyExtAggs) {
        for ($i = 0; $i -lt @($ReportCfg.ExternalTargets).Count; $i++) {
            $t = $ReportCfg.ExternalTargets[$i]
            $agg = $null
            if ($i -lt @($Stats.LatencyExtAggs).Count) { $agg = $Stats.LatencyExtAggs[$i] }
            $extSummary += @{
                index        = $i + 1
                name         = [string]$t.Name
                host         = [string]$t.Host
                icmpTarget   = [string]$t.IcmpTarget
                tcpHost      = [string]$t.TcpHostForProbe
                resolvedIp   = [string]$t.ResolvedProbeIp
                failCycles   = if ($i -lt @($Stats.ExtFailCycles).Count) { [int]$Stats.ExtFailCycles[$i] } else { 0 }
                latency      = (ConvertTo-NetworkDiagJsonLatency $agg)
            }
        }
    }

    $wifiBlock = @{ captured = $false }
    if ($Stats.ContainsKey("WifiCapturedCycles") -and [int]$Stats.WifiCapturedCycles -gt 0) {
        $avg = $null
        if ([int]$Stats.WifiSignalSamples -gt 0) {
            $avg = [math]::Round([double]$Stats.WifiSignalSumPct / [double]$Stats.WifiSignalSamples, 2)
        }
        $uniqueBssids = @()
        if ($Stats.WifiUniqueBssids) { $uniqueBssids = @($Stats.WifiUniqueBssids) }
        $wifiBlock = @{
            captured         = $true
            cyclesCaptured   = [int]$Stats.WifiCapturedCycles
            signalMinPct     = $Stats.WifiSignalMinPct
            signalMaxPct     = $Stats.WifiSignalMaxPct
            signalAvgPct     = $avg
            uniqueBssidCount = $uniqueBssids.Count
            uniqueBssidCap   = if ($Stats.ContainsKey("WifiBssidsCappedAt")) { [int]$Stats.WifiBssidsCappedAt } else { 0 }
            uniqueBssids     = $uniqueBssids
            bssidChangeCycles = [int]$Stats.WifiBssidChangeCycles
            lastSsid         = [string]$Stats.WifiLastSsid
            lastRadio        = [string]$Stats.WifiLastRadio
            lastChannel      = [string]$Stats.WifiLastChannel
            lastSignalPct    = $Stats.WifiLastSignalPct
            lastContext      = [string]$Stats.WifiLastContext
        }
    }

    $summary = [ordered]@{
        schemaVersion    = if ($ReportCfg.SchemaVersion) { [string]$ReportCfg.SchemaVersion } else { "2026-04" }
        generatedAt      = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK")
        outputFolder     = [string]$OutputFolder
        reportPath       = [string]$ReportCfg.ReportPath
        csvPath          = [string]$ReportCfg.CsvPath
        detailPath       = if ($ReportCfg.DetailActive) { [string]$ReportCfg.DetailPath } else { "" }
        ispBundlePath    = [string]$ReportCfg.IspEvidenceBundlePath
        featureFlags     = [ordered]@{
            legacyCsvShape         = [bool]$ReportCfg.LegacyCsvShape
            configAuditEnabled     = -not ([bool]$ReportCfg.SkipConfigAudit)
            cableHintsEnabled      = -not ([bool]$ReportCfg.SkipCableHints)
            multiNicCrossCheckEnabled = -not ([bool]$ReportCfg.SkipMultiNicCrossCheck)
            wifiSignalEnabled      = -not ([bool]$ReportCfg.SkipWifiSignal)
            tlsProbeEnabled        = [bool]$ReportCfg.EnableTlsProbe
            dnsProbeEnabled        = -not ([bool]$ReportCfg.SkipDnsProbe)
            routingRefreshEnabled  = ([int]$ReportCfg.RoutingRefreshIntervalCycles -gt 0)
        }

        run = [ordered]@{
            plannedDurationMinutes      = [int]$ReportCfg.DurationMinutes
            baseIntervalSeconds         = [int]$ReportCfg.IntervalSeconds
            probeAddressFamily          = [string]$ReportCfg.ProbeAddressFamily
            routingContext              = [string]$ReportCfg.RoutingContext
            primaryAdapter              = [string]$ReportCfg.PrimaryAdapter
            gateway                     = [string]$ReportCfg.Gateway
            underlayAvailable           = [bool]$ReportCfg.UnderlayAvailable
            underlayAdapter             = [string]$ReportCfg.UnderlayAdapter
            underlayGateway             = [string]$ReportCfg.UnderlayGw
            isAdmin                     = [bool]$ReportCfg.IsAdmin
            legacyCsvShape              = [bool]$ReportCfg.LegacyCsvShape
            externalTargetCount         = [int]$ReportCfg.ExternalCount
            tcpProbeEnabled             = [bool]$ReportCfg.DoTcp
            tcpHosts                    = @([string]$ReportCfg.TcpHostA, [string]$ReportCfg.TcpHostB)
            dnsProbeName                = [string]$ReportCfg.DnsProbeName
            dnsProbeEnabled             = -not ([bool]$ReportCfg.SkipDnsProbe)
            burstOnFault                = [bool]$ReportCfg.BurstOnFault
            burstIntervalSeconds        = [int]$ReportCfg.BurstIntervalSeconds
            routingRefreshIntervalCycles = [int]$ReportCfg.RoutingRefreshIntervalCycles
            skipConfigAudit             = [bool]$ReportCfg.SkipConfigAudit
            skipCableHints              = [bool]$ReportCfg.SkipCableHints
            skipMultiNicCrossCheck      = [bool]$ReportCfg.SkipMultiNicCrossCheck
            skipWifiSignal              = [bool]$ReportCfg.SkipWifiSignal
            enableTlsProbe              = [bool]$ReportCfg.EnableTlsProbe
            skipIspEvidencePacket       = [bool]$ReportCfg.SkipIspEvidencePacket
            pathMtuProbeTarget          = [string]$ReportCfg.PathMtuProbeTarget
        }
        runtime = [ordered]@{
            partialSnapshot = [bool]$PartialRun
            monitoringMode  = if ($ReportCfg.ContainsKey("MonitoringMode")) { [string]$ReportCfg.MonitoringMode } else { "" }
            startedAt       = if ($ReportCfg.ContainsKey("RunStartTime")) { [string]$ReportCfg.RunStartTime } else { "" }
            endedAt         = if ($ReportCfg.ContainsKey("RunEndTime")) { [string]$ReportCfg.RunEndTime } else { "" }
            writerHealth    = [ordered]@{
                reopenEvents       = [int]$Stats.WriterReopenEvents
                detailReopenEvents = [int]$Stats.DetailLogReopenEvents
                reopenFailures     = [int]$Stats.WriterReopenFailures
            }
            cycleTiming = [ordered]@{
                overshootCount = [int]$Stats.CycleOvershootCount
            }
            diskBudget = [ordered]@{
                projectedCsvBytes    = if ($ReportCfg.ContainsKey("ProjectedCsvBytes")) { [int64]$ReportCfg.ProjectedCsvBytes } else { 0 }
                projectedDetailBytes = if ($ReportCfg.ContainsKey("ProjectedDetailBytes")) { [int64]$ReportCfg.ProjectedDetailBytes } else { 0 }
                projectedTotalBytes  = if ($ReportCfg.ContainsKey("ProjectedTotalBytes")) { [int64]$ReportCfg.ProjectedTotalBytes } else { 0 }
                freeBytesAtStart     = if ($ReportCfg.ContainsKey("DiskFreeBytesAtStart")) { [int64]$ReportCfg.DiskFreeBytesAtStart } else { 0 }
                budgetOk             = if ($ReportCfg.ContainsKey("DiskBudgetOk")) { [bool]$ReportCfg.DiskBudgetOk } else { $true }
            }
        }

        cycles = [ordered]@{
            attempted  = [int]$Stats.CyclesAttempted
            committed  = [int]$Stats.CyclesCommitted
            allOk      = [int]$Stats.AllOK
            ispFault   = [int]$Stats.ISP_Fault
            localFault = [int]$Stats.Local_Fault
            anomaly    = [int]$Stats.Anomaly
            pctAllOk   = $pctOk
            pctIspFault = $pctIsp
            pctLocalFault = $pctLocal
            pctAnomaly = $pctAnom
        }

        pcLink = [ordered]@{
            loopbackFail               = [int]$Stats.LoopbackFail
            adapterNotUpCycles         = [int]$Stats.AdapterNotUpCycles
            linkSpeedChangeCycles      = [int]$Stats.LinkSpeedChangeCycles
            cyclesWithNicDeltas        = [int]$Stats.CyclesWithNicDeltas
            maxRxErrDelta              = [int]$Stats.MaxRxErrDelta
            maxRxDiscDelta             = [int]$Stats.MaxRxDiscDelta
            maxTxErrDelta              = [int]$Stats.MaxTxErrDelta
            icmpDownTcpUpCycles        = [int]$Stats.IcmpDownTcpUpCycles
            icmpUpTcpDownCycles        = [int]$Stats.IcmpUpTcpDownCycles
            vpnAdjustedOkCycles        = [int]$Stats.VpnAdjustedOkCycles
            normalGwIcmpAdjustedOkCycles = [int]$Stats.NormalGwIcmpAdjustedOkCycles
            normalGwIcmpPolicyActivations   = [int]$Stats.NormalGwIcmpPolicyActivations
            normalGwIcmpPolicyDeactivations = [int]$Stats.NormalGwIcmpPolicyDeactivations
            anomalyVpnTunnelOnly       = [int]$Stats.AnomalyVpnTunnelOnly
            dnsFailCycles              = [int]$Stats.DnsFailCycles
        }

        latency = [ordered]@{
            gateway = (ConvertTo-NetworkDiagJsonLatency $Stats.LatencyGwAgg)
            lanGw   = (ConvertTo-NetworkDiagJsonLatency $Stats.LatencyLanGwAgg)
        }

        externalTargets = $extSummary

        configAudit = [ordered]@{
            findingCycles = [int]$Stats.ConfigAuditFindingCycles
            lastCodes     = @($Stats.ConfigAuditLastCodes)
            startupCodes  = @($ReportCfg.ConfigAuditStartupCodes)
        }
        cableHints = [ordered]@{
            hintCycles    = [int]$Stats.CableHintCycles
            lastCodes     = @($Stats.CableHintLastCodes)
            baselineMbps  = $ReportCfg.BaselineEthMbps
        }
        multiNic = [ordered]@{
            rosterCount            = [int]$ReportCfg.MultiNicRosterCount
            crossCheckCycles       = [int]$Stats.MultiNicCrossCheckCycles
            primaryLinkSuspectCycles = [int]$Stats.PrimaryLinkSuspectCycles
            altExtOkCycles         = [int]$Stats.MultiNicAltExtOkCycles
            strictPinningAvailable = [bool]$ReportCfg.IsAdmin
            crossCheck = [ordered]@{
                strictConfirmedCycles = [int]$Stats.MultiNicStrictConfirmedCycles
                looseIndicativeCycles = [int]$Stats.MultiNicLooseIndicativeCycles
                inconclusiveCycles    = [int]$Stats.MultiNicInconclusiveCycles
                primaryLinkSuspectReasons = @(
                    if ($Stats.MultiNicSuspectReasonCounts) {
                        foreach ($k in ($Stats.MultiNicSuspectReasonCounts.Keys | Sort-Object)) {
                            [ordered]@{ reason = [string]$k; count = [int]$Stats.MultiNicSuspectReasonCounts[$k] }
                        }
                    }
                )
            }
        }
        wifi = $wifiBlock
        tls = [ordered]@{
            enabled                  = [bool]$ReportCfg.EnableTlsProbe
            probeCycles              = [int]$Stats.TlsProbeCycles
            handshakeFailCount       = [int]$Stats.TlsHandshakeFailCycles
            tcpUpTlsDownCycles       = [int]$Stats.TcpUpTlsDownCycles
        }
        udpProbe = [ordered]@{
            enabled                = [bool]$ReportCfg.EnableUdpProbe
            target                 = [string]$ReportCfg.UdpProbeTarget
            rateHz                 = [int]$ReportCfg.UdpProbeRateHz
            payloadBytes           = [int]$ReportCfg.UdpProbePayloadBytes
            started                = [bool]$Stats.UdpProbeStarted
            initErrorMsg           = [string]$Stats.UdpInitErrorMsg
            totalPacketsSent       = [long]$Stats.UdpTotalPacketsSent
            totalSendErrors        = [long]$Stats.UdpTotalSendErrors
            totalRepliesRecv       = [long]$Stats.UdpTotalRepliesRecv
            failCycles             = [int]$Stats.UdpFailCycles
            stallCycles            = [int]$Stats.UdpStallCycles
            maxConsecSendErrors    = [int]$Stats.UdpMaxConsecSendErrors
            lastErrorCode          = [string]$Stats.UdpLastErrorCode
        }
        longLivedTcp = [ordered]@{
            enabled                  = [bool]$ReportCfg.EnableLongLivedTcp
            target                   = [string]$ReportCfg.TcpSessionTarget
            started                  = [bool]$Stats.TcpSessionStarted
            totalConnectAttempts     = [int]$Stats.TcpSessionTotalConnectAttempts
            totalConnectFailures     = [int]$Stats.TcpSessionTotalConnectFailures
            totalResets              = [int]$Stats.TcpSessionTotalResets
            resetCycles              = [int]$Stats.TcpSessionResetCycles
            disconnectedCycles       = [int]$Stats.TcpSessionDisconnectedCycles
            lastResetReason          = [string]$Stats.TcpSessionLastResetReason
        }
        autoCapture = [ordered]@{
            enabled            = [bool]$ReportCfg.EnableAutoCapture
            method             = [string]$ReportCfg.AutoCaptureMethod
            seconds            = [int]$ReportCfg.AutoCaptureSeconds
            maxCaptures        = [int]$ReportCfg.AutoCaptureMax
            supported          = [bool]$ReportCfg.AutoCaptureSupported
            triggeredCount     = [int]$Stats.AutoCaptureCount
            lastState          = [string]$Stats.AutoCaptureLastState
            lastFile           = [string]$Stats.AutoCaptureLastFile
            files              = if ($Stats.AutoCaptureFiles) { @($Stats.AutoCaptureFiles) } else { @() }
            skippedNonAdmin    = [bool]$Stats.AutoCaptureSkippedNonAdmin
        }
        perProbeTimestamps = [ordered]@{
            enabled = [bool]$ReportCfg.PerProbeTimestamps
        }

        incidents = [ordered]@{
            total       = [int]$Stats.Incidents.Count
            truncated   = [bool]$Stats.IncidentsTruncated
            sample      = @($Stats.Incidents | Select-Object -First 20)
        }
        episodes = [ordered]@{
            completed = [int]$Stats.EpisodeCount
            recoveryConfirmCycles = if ($ReportCfg.EpisodeRecoveryConfirmCycles) { [int]$ReportCfg.EpisodeRecoveryConfirmCycles } else { 3 }
            sample = @(
                if ($Stats.EpisodeSummaries) {
                    @($Stats.EpisodeSummaries | Select-Object -Last 10)
                }
            )
        }
    }

    try {
        $json = $summary | ConvertTo-Json -Depth 8
        $enc = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($path, $json, $enc)
        return $path
    } catch {
        return $null
    }
}

function ConvertTo-NetworkDiagJsonLatency {
    <#
    Flatten a latency aggregator into a small hashtable suitable for JSON.
    Returns nulls for an empty aggregator. The aggregator shape comes from
    New-NetworkDiagLatencyAgg: Min / Max / Sum / SampleCount / Reservoir.
    #>
    param($Agg)
    if (-not $Agg) {
        return [ordered]@{ count = 0; minMs = $null; avgMs = $null; maxMs = $null; p95Ms = $null }
    }
    $cnt = 0
    try { $cnt = [int]$Agg.SampleCount } catch { $cnt = 0 }
    $min = $null; $max = $null; $avg = $null; $p95 = $null
    if ($cnt -gt 0) {
        if ($null -ne $Agg.Min) { $min = [math]::Round([double]$Agg.Min, 2) }
        if ($null -ne $Agg.Max) { $max = [math]::Round([double]$Agg.Max, 2) }
        $avg = [math]::Round([double]$Agg.Sum / [double]$cnt, 2)
        try {
            if ($Agg.Reservoir -and $Agg.Reservoir.Count -gt 0) {
                $p = Get-NetworkDiagP95FromList -Samples $Agg.Reservoir
                if ($null -ne $p) { $p95 = [math]::Round([double]$p, 2) }
            }
        } catch { }
    }
    return [ordered]@{
        count = $cnt
        minMs = $min
        avgMs = $avg
        maxMs = $max
        p95Ms = $p95
    }
}
