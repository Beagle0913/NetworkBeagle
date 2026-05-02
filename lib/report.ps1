# lib/report.ps1
# CSV row/column builders and the final report composer. The original
# ~280-line monolithic Build-NetworkDiagReportText is replaced by a thin
# shell that concatenates small named section builders, one per heading.

function ConvertTo-NetworkDiagCsvLine {
    param([System.Collections.IDictionary]$Row)
    $oldCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
        $o = [pscustomobject]$Row
        $lines = @($o | ConvertTo-Csv -NoTypeInformation)
        if ($lines.Count -lt 2) { return "" }
        return $lines[1]
    } finally {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $oldCulture
    }
}

function Get-NetworkDiagCsvColumnManifest {
    <#
    Column order, locked:
        Timestamp, ProbeAddressFamily, Loopback_ms, Eth_Status, Eth_Mbps,
        RxErr_d, RxDisc_d, TxErr_d, Gateway_ms,
        <legacy triplet OR Ext1_ms..ExtN_ms>,
        TCP_CF_ms, TCP_GG_ms, Evidence, Dns_ok, Dns_ms, Verdict,
        [when non-legacy: dual-layer + new feature columns. Optional appendices
         when -EnableUdpProbe / -EnableLongLivedTcp / -EnableAutoCapture /
         -PerProbeTimestamps are passed].
    #>
    param(
        [bool]$LegacyCsvShape,
        [int]$ExternalCount,
        [bool]$IncludeUdp,
        [bool]$IncludeTcpSession,
        [bool]$IncludeAutoCapture,
        [bool]$IncludePerProbeTimestamps
    )
    $c = [System.Collections.Generic.List[string]]::new()
    foreach ($x in @("Timestamp", "ProbeAddressFamily", "Loopback_ms", "Eth_Status", "Eth_Mbps", "RxErr_d", "RxDisc_d", "TxErr_d", "Gateway_ms")) {
        $c.Add($x)
    }
    if ($LegacyCsvShape) {
        $c.Add("Cloudflare_ms")
        $c.Add("Google_ms")
        $c.Add("Quad9_ms")
    } else {
        for ($i = 1; $i -le $ExternalCount; $i++) {
            $c.Add("Ext${i}_ms")
        }
    }
    foreach ($x in @("TCP_CF_ms", "TCP_GG_ms", "Evidence", "Dns_ok", "Dns_ms", "Verdict")) {
        $c.Add($x)
    }
    if (-not $LegacyCsvShape) {
        foreach ($x in @("RoutingContext", "PrimaryAdapter", "UnderlayAdapter", "UnderlayAvailable",
                "SchemaVersion",
                "Lan_Status", "Lan_Mbps", "LanGw_ms", "LanRxErr_d", "LanRxDisc_d", "LanTxErr_d",
                "Lan_IsEthernet", "Lan_Name",
                "ConfigAuditCode", "CableHint",
                "MultiNicRoster", "MultiNicGwResults", "MultiNicExtResults", "MultiNicCertainty", "MultiNicSuspectReason",
                "EpisodeId", "EpisodePhase",
                "WifiSsid", "WifiBssid", "WifiSignal", "WifiRadio", "WifiChannel",
                "TLS_CF_ms", "TLS_GG_ms")) {
            $c.Add($x)
        }
        if ($IncludeUdp) {
            foreach ($x in @("Udp_PktsSent_d", "Udp_SendErr_d", "Udp_RepliesRecv_d", "Udp_ConsecErr", "Udp_LastErr")) { $c.Add($x) }
        }
        if ($IncludeTcpSession) {
            foreach ($x in @("TcpSess_State", "TcpSess_UpSec", "TcpSess_Resets_d", "TcpSess_LastReset")) { $c.Add($x) }
        }
        if ($IncludeAutoCapture) {
            foreach ($x in @("AutoCap_State", "AutoCap_Count", "AutoCap_LastFile")) { $c.Add($x) }
        }
        if ($IncludePerProbeTimestamps) {
            foreach ($x in @("Loopback_t_ms", "Dns_t_ms", "LanGw_t_ms", "Gw_t_ms")) { $c.Add($x) }
            for ($i = 1; $i -le $ExternalCount; $i++) { $c.Add("Ext${i}_t_ms") }
            foreach ($x in @("Tcp_CF_t_ms", "Tcp_GG_t_ms", "Tls_CF_t_ms", "Tls_GG_t_ms")) { $c.Add($x) }
        }
    }
    return , $c.ToArray()
}

function ConvertTo-NetworkDiagCsvLineFromManifest {
    param(
        [string[]]$ColumnNames,
        [hashtable]$Values
    )
    $ord = [ordered]@{}
    foreach ($col in $ColumnNames) {
        if ($null -ne $Values -and $Values.ContainsKey($col)) {
            $ord[$col] = $Values[$col]
        } else {
            $ord[$col] = ""
        }
    }
    return ConvertTo-NetworkDiagCsvLine -Row $ord
}

function Format-NetworkDiagDnsResolutionSection {
    param(
        [hashtable]$S,
        [int]$Den,
        [string]$DnsName,
        [int]$DnsCapMs,
        [bool]$SkipDns
    )
    if ($SkipDns) {
        return @"
DNS RESOLUTION
  DNS probe was disabled (-SkipDnsProbe).

"@
    }
    $pct = if ($Den -gt 0) { [math]::Round($S.DnsFailCycles / $Den * 100, 1) } else { 0.0 }
    return @"
DNS RESOLUTION
  Name tested: $DnsName (async wait cap ${DnsCapMs} ms; Dns_ms is full client elapsed time on success and may slightly exceed the cap; failures/timeouts use Dns_ms=-1 like ICMP fail sentinels).
  Cycles with DNS failure: $($S.DnsFailCycles) ($pct% of committed cycles).
  When gateway+externals look OK but DNS fails, Evidence may include +DNS_FAIL; apps can still drop if they depend on names.

"@
}

function Build-NetworkDiagRunConfigSection {
    param([hashtable]$S, [hashtable]$R)
    $burstLine = ""
    if ($R.BurstOnFault) {
        $burstLine = "  Burst on fault:   on ($($R.BurstIntervalSeconds) s interval, $($R.BurstCycles) cycles per fault, max $($R.MaxBurstSeconds) s wall per episode)`n"
    }
    $gwPol = if ($R.RoutingContext -ne 'Normal') {
        'n/a (not Normal routing)'
    } elseif ($R.SkipGwIcmpPolicyAdaptation) {
        'off (-SkipGwIcmpPolicyAdaptation)'
    } elseif (-not $R.DoTcp) {
        'off (TCP probes disabled)'
    } else {
        "on ($($R.GwIcmpPolicyConfirmCycles) consecutive stable cycles to arm GW_ICMP_POLICY)"
    }
    $dns = if ($R.SkipDnsProbe) { 'off' } else { "on ($($R.DnsProbeName), cap $($R.DnsTimeoutMs) ms)" }
    $detail = if ($R.DetailActive) { 'on' } elseif ($R.DetailRequested) { "off ($($R.DetailDisabledReason))" } else { 'off' }
    $tcpLine = if ($R.DoTcp) { "on ($($R.TcpHostA), $($R.TcpHostB))" } else { 'off' }
    $ctxTail = if ($R.TunnelReason -and $R.TunnelReason -ne 'None') {
        " (TunnelReason=$($R.TunnelReason), TunnelDetail=$($R.TunnelDetail))"
    } else { "" }
    $ulAvail = if ($R.UnderlayAvailable) { 'yes' } else { 'no' }
    $ulAvailSuf = if ($R.UnderlayReason) { " ($($R.UnderlayReason))" } else { "" }
    $ulAdapter = if ($R.UnderlayAdapter) { $R.UnderlayAdapter } else { 'n/a' }
    $ulGw = if ($R.UnderlayGw) { $R.UnderlayGw } else { 'n/a' }
    $ulMetric = if ($null -ne $R.UnderlayMetric) { $R.UnderlayMetric } else { 'n/a' }
    $ulVirt = if ($R.UnderlayMayBeVirtual) { 'yes (see LIMITATIONS)' } else { 'no' }
    $routeRefreshBlock = if ($R.RoutingRefreshIntervalCycles -gt 0) {
@"
  Route refresh:      every $($R.RoutingRefreshIntervalCycles) attempted cycle(s), before cycles $($R.RoutingRefreshIntervalCycles + 1), $([int]$R.RoutingRefreshIntervalCycles * 2 + 1), ... (grep ROUTE_REFRESH in incidents / detail log)
  Gateway/ifIndex note: Values above reflect the last routing snapshot in this run (startup plus any ROUTE_REFRESH re-resolution). Run-wide CSV rows may cross different snapshots.
  Aggregates note:      Latency series and verdict counts may combine periods with different gateways, adapters, or routing contexts when route refresh is enabled.
"@
    } else {
@"
  Gateway/ifIndex note: Default gateway, routed ifIndex, RoutingContext (tunnel classification),
  and underlay ifIndex/LAN gateway are resolved once at script start; VPN or interface changes
  during the run are not re-evaluated.
"@
    }
    $monitoringModeLine = if ($R.ContainsKey("MonitoringMode") -and $R.MonitoringMode) {
        "  Monitoring mode:   $($R.MonitoringMode)"
    } else {
        "  Monitoring mode:   n/a"
    }
    $heartbeatLine = if ($R.ContainsKey("HeartbeatMinutes")) {
        if ([int]$R.HeartbeatMinutes -gt 0) { "every $([int]$R.HeartbeatMinutes) min" } else { "off" }
    } else { "n/a" }
    $snapshotLine = if ($R.ContainsKey("SnapshotMinutes")) {
        if ([int]$R.SnapshotMinutes -gt 0) { "every $([int]$R.SnapshotMinutes) min" } else { "off" }
    } else { "n/a" }
    $eventLookbackLine = if ($R.ContainsKey("EventLogLookbackMinutes")) {
        if ([int]$R.EventLogLookbackMinutes -gt 0) { "$([int]$R.EventLogLookbackMinutes) min rolling window" } else { "since run start" }
    } else { "n/a" }
    return @"
RUN CONFIG
  Output folder:      $($R.OutputFolder)
  Output resolution:  $($R.OutputResolutionLabel)
  Schema version:     $(if ($R.SchemaVersion) { $R.SchemaVersion } else { 'unknown' })
${monitoringModeLine}
  Probe stack:        $($R.ProbeAddressFamily) (see CSV ProbeAddressFamily column on each row)
  Gateway (next hop): $($R.Gateway)
  Routed adapter:     $($R.AdapterSummary)
  Baseline link Mbps: $(if ($null -ne $R.BaselineEthMbps) { $R.BaselineEthMbps } else { 'n/a' })
  Duration / interval: $($R.DurationMinutes) min / $($R.IntervalSeconds) sec (sleep max(0, interval - cycle wall time))
$burstLine  ICMP per target:    $($R.IcmpCountPerTarget) attempt(s), $($R.IcmpTimeoutSeconds)s timeout (mean RTT in CSV when any succeed)
  Episode close rule: $(if ($R.EpisodeRecoveryConfirmCycles) { "$($R.EpisodeRecoveryConfirmCycles) consecutive OK cycles" } else { 'default (3 consecutive OK cycles)' })
  Heartbeat cadence:  $heartbeatLine
  Partial snapshots:  $snapshotLine
  Event-log lookback: $eventLookbackLine
  TCP 443 probes:     $tcpLine
  Normal GW ICMP policy adaptation: $gwPol
  DNS probe:          $dns
  Detail log:         $detail
  External ICMP:      $($R.ExternalTargets.Host -join ', ')
  CSV shape:          $(if ($R.LegacyCsvShape) { 'Legacy (no dual-layer columns)' } else { 'Full (dual-layer columns included)' })
  Routing context:    $($R.RoutingContext)$ctxTail
  Primary adapter:    $($R.PrimaryAdapter)
  Underlay available: $ulAvail$ulAvailSuf
  Underlay adapter:   $ulAdapter  LAN GW: $ulGw  ifMetric: $ulMetric
  UnderlayMayBeVirtual: $ulVirt
  Config audit:       $(if ($R.SkipConfigAudit) { 'off (-SkipConfigAudit)' } else { 'on (startup + ROUTE_REFRESH + non-OK cycles, 30s cache)' })
  Cable/NIC hints:    $(if ($R.SkipCableHints) { 'off (-SkipCableHints)' } else { 'on (baseline at startup, invoked on non-OK cycles)' })
  Multi-NIC x-check:  $(if ($R.SkipMultiNicCrossCheck) { 'off (-SkipMultiNicCrossCheck)' } elseif ($R.MultiNicRosterCount -lt 1) { 'off (no eligible alt adapters)' } else { "on (roster=$($R.MultiNicRosterCount); admin=$(if ($R.IsAdmin) { 'yes' } else { 'no; external probes are loose' }))" })
  UDP probe:          $(if ($R.EnableUdpProbe) { "on (target=$($R.UdpProbeTarget), $([int]$R.UdpProbeRateHz) Hz, $([int]$R.UdpProbePayloadBytes) B)" } else { 'off (-EnableUdpProbe to enable)' })
  Long-lived TCP:     $(if ($R.EnableLongLivedTcp) { "on (target=$($R.TcpSessionTarget))" } else { 'off (-EnableLongLivedTcp to enable)' })
  Auto-capture:       $(if ($R.EnableAutoCapture) { "on (method=$($R.AutoCaptureMethod), $([int]$R.AutoCaptureSeconds)s per fault, max=$([int]$R.AutoCaptureMax))" } else { 'off (-AutoCaptureOnFault to enable)' })
  Per-probe TS:       $(if ($R.PerProbeTimestamps) { 'on (CSV adds <Probe>_t_ms columns; ms-offset from cycle Timestamp)' } else { 'off (-PerProbeTimestamps to enable)' })
  ISP evidence pkt:   $(if ($R.SkipIspEvidencePacket) { 'off (-SkipIspEvidencePacket)' } elseif ($R.IspEvidenceBundlePath) { $R.IspEvidenceBundlePath } else { 'on (produced at run end)' })
$routeRefreshBlock
"@
}

function Build-NetworkDiagRuntimeHealthSection {
    param([hashtable]$S)
    return @"
RUNTIME HEALTH
  Writer reopen events: $([int]$S.WriterReopenEvents)
  Detail writer reopen events: $([int]$S.DetailLogReopenEvents)
  Writer reopen failures: $([int]$S.WriterReopenFailures)
  Cycle overshoots (>interval): $([int]$S.CycleOvershootCount)

"@
}

function Build-NetworkDiagLimitationsSection {
    param([hashtable]$R)
    $refreshLimits = if ($R.RoutingRefreshIntervalCycles -gt 0) {
@"
  - Default gateway, routed adapter, RoutingContext (tunnel vs normal), and underlay selection are re-resolved on each ROUTE_REFRESH boundary when -RoutingRefreshIntervalCycles is set (see RUN CONFIG); between refreshes the prior snapshot applies.
  - Underlay selection is recomputed on each refresh when the default route is classified as a VPN tunnel; virtual-switch adapters (Hyper-V, VMware, etc.) are excluded first; if none remain, the script may pick a virtual adapter and sets UnderlayMayBeVirtual.
"@
    } else {
@"
  - Default gateway, routed adapter, RoutingContext (tunnel vs normal), and underlay selection
    are captured at startup only; metrics, VPNs, or NIC changes can make that snapshot stale.
  - Underlay selection runs once at startup; virtual-switch adapters (Hyper-V, VMware, etc.) are excluded first; if none remain, the script may pick a virtual adapter and sets UnderlayMayBeVirtual.
"@
    }
    $nicCounterNote = if ($R.RoutingRefreshIntervalCycles -gt 0) {
        "  - NIC counters use adapter names on the routed adapter from the startup / last refresh snapshot; policy routing, VPN changes, or moving traffic to another interface can make deltas silently unrepresentative. Renaming an adapter during a run can also make counter reads fail silently.`n"
    } else {
        "  - NIC counters use adapter names on the routed adapter picked at startup; policy routing, VPN`n    changes, or moving traffic to another interface can make deltas silently unrepresentative.`n    Renaming an adapter during a run can also make counter reads fail silently.`n"
    }
    $familyNote = if ($R.ProbeAddressFamily -eq "IPv6") {
        "  - This run used -ProbeAddressFamily IPv6: default route (::/0), gateways, ICMP, and TCP used IPv6-oriented paths only. IPv4 was not probed. For IPv4-only or dual-stack behavior, run again with -ProbeAddressFamily IPv4 (default) or correlate with app-specific tests.`n"
    } else {
        "  - This run used -ProbeAddressFamily IPv4: default route (0.0.0.0/0), gateways, ICMP, and TCP used IPv4-oriented paths only. IPv6 was not probed; for IPv6-only or dual-stack behavior, run again with -ProbeAddressFamily IPv6 or correlate with Get-NetRoute -AddressFamily IPv6 and app-specific tests.`n"
    }
    return @"
LIMITATIONS
  - This tool uses ICMP ping plus optional TCP connects; it is not a full picture of web/video/game traffic.
  - A bad Ethernet cable vs a bad NIC vs a driver bug can look identical; use NIC deltas and link flaps as hints, then swap cable/port/PC to prove.
  - Corporate firewalls or 'security' software can block ICMP or TCP and skew Evidence.
  - Your router LAN interface may still ping while its WAN is down (less common); combine with router logs if needed.
$refreshLimits
  - Probes within each cycle run one after another (sequential), not in parallel; total cycle time includes all blocking steps.
  - CSV Timestamp is one stamp per row (taken at cycle start, before probes), not per-probe start times and not the row flush instant. Sequential probes mean later columns can reflect later wall-clock instants than earlier columns (e.g. after slow ICMP or TCP); one row is not a simultaneous network snapshot.
$nicCounterNote$familyNote  - Latency min/avg/max and p95 use a bounded in-memory reservoir per series (exact min/max; p95 exact until sample count exceeds the reservoir cap, then approximate).
  - Very long runs produce large CSV files; incident lines in this report are capped in memory ($($R.MaxIncidents)).
  - Some routers or gateways do not answer ICMP echo on their LAN/default-gateway address. After a stable confirmation pattern in Normal routing (see RUN CONFIG), this script may classify that as a gateway ICMP policy limitation (Evidence GW_ICMP_POLICY+...) rather than instability; raw Gateway_ms and GwFailCycles still show ICMP failure.
  - CABLE_SUSPECT is a correlated hint, never a verdict: software cannot prove cable-vs-NIC-vs-driver without a swap test.
  - Multi-NIC cross-check external probes run in loose mode when non-admin (no scoped host route). Use MultiNicExtResults mode tags (_strict/_loose/_mixed) and MultiNicCertainty to interpret PRIMARY_LINK_SUSPECT.
  - Vendor cable diagnostic advanced properties are driver-dependent; many consumer NICs expose nothing and the hint reports CABLE_DIAG_UNAVAILABLE once for those cases.
"@
}

function Build-NetworkDiagPcLinkSection {
    param([hashtable]$S)
    return @"
PC / LINK SUMMARY (observed this run)
  Loopback ping failures:     $($S.LoopbackFail)
  Adapter-not-Up cycles:    $($S.AdapterNotUpCycles)
  Link speed change events: $($S.LinkSpeedChangeCycles)
  Cycles with NIC counter deltas (any non-zero): $($S.CyclesWithNicDeltas)
  Max delta RxErr / RxDisc / TxErr: $($S.MaxRxErrDelta) / $($S.MaxRxDiscDelta) / $($S.MaxTxErrDelta)
  Cycles external ICMP bad but TCP OK: $($S.IcmpDownTcpUpCycles)
  Cycles external ICMP OK but TCP bad: $($S.IcmpUpTcpDownCycles)
  VPN-adjusted OK cycles (tunnel GW ICMP bad, underlay LAN OK): $($S.VpnAdjustedOkCycles)
  Normal gateway ICMP policy-adjusted OK cycles: $($S.NormalGwIcmpAdjustedOkCycles)
  Normal GW ICMP policy mode activations / deactivations: $($S.NormalGwIcmpPolicyActivations) / $($S.NormalGwIcmpPolicyDeactivations)
  ANOMALY cycles with VPN_TUNNEL_ONLY evidence: $($S.AnomalyVpnTunnelOnly)

"@
}

function Build-NetworkDiagLatencySection {
    param([hashtable]$S, [hashtable]$R)
    $latGwLine = Format-NetworkDiagLatencySeriesLine -Label "Gateway ($($R.Gateway))" -Agg $S.LatencyGwAgg -FailC $S.GwFailCycles -Committed $S.CyclesCommitted -JitterPairs $S.JitterGwPairs -JitterSum $S.JitterGwSum
    $latExtLines = @()
    for ($ri = 0; $ri -lt $R.ExternalTargets.Count; $ri++) {
        $th = $R.ExternalTargets[$ri].Host
        $tn = $R.ExternalTargets[$ri].Name
        $ea = $S.LatencyExtAggs[$ri]
        $fc = $S.ExtFailCycles[$ri]
        $jp = $S.JitterExtPairs[$ri]
        $js = $S.JitterExtSum[$ri]
        $latExtLines += (Format-NetworkDiagLatencySeriesLine -Label "External $th ($tn)" -Agg $ea -FailC $fc -Committed $S.CyclesCommitted -JitterPairs $jp -JitterSum $js)
    }
    $latLanLine = ""
    if ($R.UnderlayAvailable -and $R.UnderlayGw) {
        $latLanLine = (Format-NetworkDiagLatencySeriesLine -Label "Underlay LAN GW ($($R.UnderlayGw))" -Agg $S.LatencyLanGwAgg -FailC $S.LanGwFailCycles -Committed $S.CyclesCommitted -JitterPairs -1 -JitterSum 0.0)
    }
    return @"
LATENCY (committed cycles; ICMP mean RTT samples; cycle-loss = cycles with all ICMP attempts failed for that target)
$latGwLine
$($latExtLines -join "`n")$(if ($latLanLine) { "`n$latLanLine" })
"@
}

function Build-NetworkDiagDiagnosisSection {
    param([hashtable]$S, [hashtable]$R)
    $tcpMismatchNote = ""
    if ($R.DoTcp -and $S.ISP_Fault -gt 0 -and $S.IcmpDownTcpUpCycles -gt 0) {
        if ($S.IcmpDownTcpUpCycles -ge [math]::Max(1, [math]::Ceiling($S.ISP_Fault / 2))) {
            $tcpMismatchNote = @"

  ICMP vs TCP: On $($S.IcmpDownTcpUpCycles) cycle(s), external ICMP looked bad but TCP/443 to $($R.TcpHostA) or $($R.TcpHostB) still succeeded.
  That pattern often means ICMP is filtered or deprioritized, not a full internet outage. Treat ISP-side conclusions cautiously unless TCP also fails.
"@
        }
    }
    $localNicHint = ""
    if ($S.Local_Fault -gt 0 -and ($S.CyclesWithNicDeltas -gt 0 -or $S.AdapterNotUpCycles -gt 0 -or $S.LinkSpeedChangeCycles -gt 0)) {
        $localNicHint = @"

  PC/LINK HINT: Non-zero NIC error deltas, adapter-not-Up cycles, or link-speed changes appeared during the run.
  That supports a physical-layer or NIC/driver issue (cable, port, NIC). Software cannot prove cable vs NIC - swap cable and try another LAN port to falsify.
"@
    }
    if ($S.CyclesCommitted -eq 0) {
        if ($S.CyclesAttempted -gt 0) {
            return @"
  >>> NO COMMITTED SAMPLES IN CSV <<<
  One or more cycles started but no row was successfully flushed to the CSV (check for mid-cycle errors or disk issues).
"@
        }
        return @"
  >>> NO SAMPLES COLLECTED <<<
  Zero ping cycles ran (for example the script exited before the first cycle or the run ended immediately).
  Re-run with -DurationMinutes 1 or higher and an interval that fits your needs.
"@
    }
    if ($S.ISP_Fault -gt 0 -and $S.Local_Fault -eq 0) {
        return @"
  >>> LIKELY BEYOND YOUR LAN (ISP / PATH) <<<
  Gateway ICMP stayed up while more than half of the $($R.ExternalCount) external ICMP targets failed, $($S.ISP_Fault) time(s) (among committed cycles).
  That pattern usually means a problem past your PC-to-router Ethernet hop (often ISP or upstream), when ICMP is trusted.
$tcpMismatchNote
  Share timestamps and CSV with your ISP if this matches the times you notice drops.
"@
    }
    if ($S.Local_Fault -gt 0 -and $S.ISP_Fault -eq 0) {
        return @"
  >>> LOCAL TO ROUTER / PC PATH <<<
  Every LOCAL_FAULT cycle had the gateway ICMP fail together with external ICMP.
  That isolates the problem to your PC, cable, switch, or router LAN port (before WAN).
$localNicHint
"@
    }
    if ($S.Local_Fault -gt 0 -and $S.ISP_Fault -gt 0) {
        return @"
  >>> MIXED: LOCAL AND BEYOND-LAN PATTERNS <<<
  Some cycles lost the gateway (local path), others kept the gateway but lost external ICMP (beyond LAN).
  ISP faults: $($S.ISP_Fault) | Local faults: $($S.Local_Fault)
$localNicHint
"@
    }
    if ($S.AllOK -eq $S.CyclesCommitted -and $S.CyclesCommitted -gt 0) {
        if ($S.VpnAdjustedOkCycles -gt 0 -and $S.NormalGwIcmpAdjustedOkCycles -gt 0) {
            return @"
  >>> NO PROBE FAILURES (INCLUDING ADJUSTED OK CYCLES) <<<
  Every committed cycle was OK. $($S.VpnAdjustedOkCycles) cycle(s) were OK under VPN dual-layer rules (tunnel gateway ICMP failed while underlay LAN checks succeeded).
  $($S.NormalGwIcmpAdjustedOkCycles) cycle(s) were OK under Normal routing gateway ICMP policy rules: default gateway did not answer ICMP echo, but external ICMP, TCP/443, DNS (if probed), loopback, and primary link/NIC checks stayed healthy over the confirmation window (see Evidence GW_ICMP_POLICY+... in CSV).
  If apps still drop, run again during failures or investigate application-specific paths and DNS.
"@
        }
        if ($S.VpnAdjustedOkCycles -gt 0) {
            return @"
  >>> NO PROBE FAILURES (INCLUDING VPN-ADJUSTED OK) <<<
  Every committed cycle was OK. $($S.VpnAdjustedOkCycles) cycle(s) were OK under dual-layer rules: primary Gateway ICMP failed (typical for VPN tunnel next hops) while underlay LAN checks succeeded.
  If apps still drop, run again during failures or investigate application-specific paths and DNS.
"@
        }
        if ($S.NormalGwIcmpAdjustedOkCycles -gt 0) {
            return @"
  >>> NO PROBE FAILURES (INCLUDING NORMAL GW ICMP POLICY-ADJUSTED OK) <<<
  Every committed cycle was OK. $($S.NormalGwIcmpAdjustedOkCycles) cycle(s) were OK after GW_ICMP_POLICY confirmation: default gateway did not answer ICMP echo, but external ICMP, TCP/443, DNS (if probed), loopback, and primary link/NIC checks stayed healthy over the confirmation window (see Evidence GW_ICMP_POLICY+... in CSV).
  If apps still drop, run again during failures or investigate application-specific paths and DNS.
"@
        }
        return @"
  >>> NO PROBE FAILURES IN THIS WINDOW <<<
  Every committed cycle was OK for gateway + external ICMP and (if enabled) aligned TCP checks.
  If apps still drop, run again during failures or investigate application-specific paths and DNS.
"@
    }
    $anomVpnHint = ""
    if ($S.AnomalyVpnTunnelOnly -gt 0 -and $S.Anomaly -gt 0 -and $S.AnomalyVpnTunnelOnly -ge [math]::Max(1, [math]::Floor($S.Anomaly * 0.75))) {
        $anomVpnHint = @"

  VPN NOTE: A large share of ANOMALY cycles used evidence VPN_TUNNEL_ONLY (underlay unavailable). That is often an expected limitation when the VPN blocks local gateway visibility, not intermittent routing flaps.
"@
    }
    $normalPolicyHint = ""
    if ($S.NormalGwIcmpAdjustedOkCycles -gt 0) {
        $normalPolicyHint = @"

  Normal GW ICMP policy: $($S.NormalGwIcmpAdjustedOkCycles) committed cycle(s) were verdict OK under GW_ICMP_POLICY after confirmation (default gateway ICMP echo unavailable; see CSV Evidence). Other cycles in this run were not all OK.
"@
    }
    return @"
  >>> INCONCLUSIVE OR ANOMALY-HEAVY <<<
  Review the incident log and Evidence column in the CSV (ICMP vs TCP, NIC_DELTA, VPN_* codes, CABLE_SUSPECT, PRIMARY_LINK_SUSPECT, CONFIG_* findings).
$anomVpnHint$normalPolicyHint
"@
}

function Build-NetworkDiagConfigAuditSection {
    param([hashtable]$S, [hashtable]$R)
    if ($R.SkipConfigAudit) {
        return "DEVICE CONFIG AUDIT`n  (disabled via -SkipConfigAudit)`n"
    }
    $startup = if ($R.ConfigAuditStartupCodes) { ($R.ConfigAuditStartupCodes -join ", ") } else { "NONE" }
    $last = if ($S.ConfigAuditLastCodes -and @($S.ConfigAuditLastCodes).Count -gt 0) {
        ($S.ConfigAuditLastCodes -join ", ")
    } else { "NONE" }
    $den = [math]::Max($S.CyclesCommitted, 1)
    $pct = [math]::Round($S.ConfigAuditFindingCycles / $den * 100, 1)
    return @"
DEVICE CONFIG AUDIT
  At startup: $startup
  Last re-run codes: $last
  Cycles with any finding: $($S.ConfigAuditFindingCycles) ($pct% of committed cycles)
  Finding code reference (short):
    APIPA                 host IP is 169.254.x.x (no DHCP lease or server unreachable)
    IP_ADDR_STATE_<state> Windows reports the IP as Duplicate/Tentative/Invalid
    GW_SUBNET_MISMATCH    default gateway does not lie in the host's subnet
    NO_DNS / DNS_UNREACH  no DNS servers configured / none answered ICMP
    MULTI_GW              multiple default gateways across non-tunnel NICs (routing ambiguity)
    DHCP_CONFIG           interface says DHCP but IP origin is static (or vice versa)
    WINHTTP_PROXY         WinHTTP proxy set (not 'Direct') - affects Windows Update / some apps
    IP_CONFLICT_EVENT     System event 4198/4199 since run start (IP conflict)
    NDIS_LINK_DOWN_EVENT  Windows logged a link drop on the routed NIC
    POWER_SAVING / EEE_ENABLED  power mgmt / Energy-Efficient Ethernet can cause ms-scale drops
    MTU_LOW_<n>           path MTU to -PathMtuProbeTarget came back under 1400

"@
}

function Build-NetworkDiagCableHintsSection {
    param([hashtable]$S, [hashtable]$R)
    if ($R.SkipCableHints) {
        return "CABLE / NIC HINTS`n  (disabled via -SkipCableHints)`n"
    }
    $last = if ($S.CableHintLastCodes -and @($S.CableHintLastCodes).Count -gt 0) {
        ($S.CableHintLastCodes -join ", ")
    } else { "NONE" }
    $baseline = if ($null -ne $R.BaselineEthMbps) { "$($R.BaselineEthMbps) Mbps" } else { "n/a" }
    $den = [math]::Max($S.CyclesCommitted, 1)
    $pct = [math]::Round($S.CableHintCycles / $den * 100, 1)
    return @"
CABLE / NIC HINTS
  Baseline link: $baseline
  Last hint codes: $last
  Cycles with any hint: $($S.CableHintCycles) ($pct% of committed cycles)
  Hint code reference:
    LINK_DEGRADED    current LinkSpeed stuck at <=50% of baseline for 3+ consecutive cycles
    LINK_FLAP        Windows logged a media-disconnect on the routed NIC since last check
    CABLE_SUSPECT    recent fault cycles also had NIC error deltas + link flaps/degrade
    CABLE_DIAG_*     vendor advanced-property value from the driver (when exposed)
    CABLE_DIAG_UNAVAILABLE  driver does not expose a *Cable*/*Diagnostic* property
  Software cannot prove a bad cable vs a bad NIC vs a driver bug. If CABLE_SUSPECT
  shows up, swap the cable and retry another LAN port to falsify.

"@
}

function Build-NetworkDiagMultiNicSection {
    param([hashtable]$S, [hashtable]$R)
    if ($R.SkipMultiNicCrossCheck) {
        return "MULTI-NIC CROSS-CHECK`n  (disabled via -SkipMultiNicCrossCheck)`n"
    }
    if ($R.MultiNicRosterCount -lt 1) {
        return @"
MULTI-NIC CROSS-CHECK
  Roster at startup: 0 eligible alt adapters (nothing to cross-check with).
  Tip: plug in both Wi-Fi and Ethernet simultaneously to enable this layer on the next run.

"@
    }
    $den = [math]::Max($S.CyclesCommitted, 1)
    $pctCk = [math]::Round($S.MultiNicCrossCheckCycles / $den * 100, 1)
    $pls = $S.PrimaryLinkSuspectCycles
    $altExt = $S.MultiNicAltExtOkCycles
    $pinMode = if ($R.IsAdmin) { "scoped host-route pinning (strict)" } else { "no host-route (loose; routing may still pick primary NIC)" }
    return @"
MULTI-NIC CROSS-CHECK
  Roster at startup: $($R.MultiNicRosterCount) alt adapter(s); external-probe mode: $pinMode
  Cross-check cycles run: $($S.MultiNicCrossCheckCycles) ($pctCk% of committed cycles; only runs when primary verdict != OK)
  PRIMARY_LINK_SUSPECT cycles: $pls  (alt NIC reached its router/gateway while primary failed its gateway)
  Alt-NIC external probes reaching internet: $altExt
  Certainty buckets: strict-confirmed=$([int]$S.MultiNicStrictConfirmedCycles), loose-indicative=$([int]$S.MultiNicLooseIndicativeCycles), inconclusive=$([int]$S.MultiNicInconclusiveCycles)
  Suspect reason counts: $(if ($S.MultiNicSuspectReasonCounts -and $S.MultiNicSuspectReasonCounts.Count -gt 0) { (($S.MultiNicSuspectReasonCounts.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ", ") } else { "none" })
  CSV columns: MultiNicRoster, MultiNicGwResults, MultiNicExtResults, MultiNicCertainty, MultiNicSuspectReason (na when not run).
  Notes:
    * The adapter's own gateway IP is only reachable on its L2 segment, so that probe naturally uses the alt NIC.
    * For external probes, strict pinning requires admin (temporary /32 host route); non-admin falls back to loose mode and MultiNicExtResults encodes mode tags (_strict/_loose/_mixed).

"@
}

function Build-NetworkDiagWifiSignalSection {
    param([hashtable]$S, [hashtable]$R)
    if ($R.SkipWifiSignal) {
        return "WI-FI SIGNAL`n  (disabled via -SkipWifiSignal)`n`n"
    }
    $captured = 0
    if ($S.ContainsKey("WifiCapturedCycles")) { $captured = [int]$S.WifiCapturedCycles }
    if ($captured -le 0) {
        return @"
WI-FI SIGNAL
  No Wi-Fi adapter observed during the run (primary is wired and roster had no Wi-Fi entry).
  Tip: if Wi-Fi is on this PC, have it connected when you start the run to get per-cycle
  SSID / BSSID / Signal% / Radio / Channel captured in the CSV.

"@
    }
    $avg = "n/a"
    if ([int]$S.WifiSignalSamples -gt 0) {
        $avg = "$([math]::Round([double]$S.WifiSignalSumPct / [double]$S.WifiSignalSamples, 1))%"
    }
    $min = if ($null -ne $S.WifiSignalMinPct) { "$([int]$S.WifiSignalMinPct)%" } else { "n/a" }
    $max = if ($null -ne $S.WifiSignalMaxPct) { "$([int]$S.WifiSignalMaxPct)%" } else { "n/a" }
    $bssidCount = 0
    if ($S.WifiUniqueBssids -and $S.WifiUniqueBssids.Count) { $bssidCount = [int]$S.WifiUniqueBssids.Count }
    $bssidCapNote = ""
    if ($S.ContainsKey("WifiBssidsCappedAt") -and [int]$S.WifiBssidsCappedAt -gt 0) {
        $bssidCapNote = " (capped at $([int]$S.WifiBssidsCappedAt))"
    }
    $bssidList = ""
    if ($S.WifiUniqueBssids -and $S.WifiUniqueBssids.Count -gt 0) {
        $bssidList = ($S.WifiUniqueBssids | Select-Object -First 6) -join ", "
    }
    $roamCycles = [int]$S.WifiBssidChangeCycles
    $ctx = if ($S.WifiLastContext) { [string]$S.WifiLastContext } else { "n/a" }
    $lastSsid = if ($S.WifiLastSsid) { [string]$S.WifiLastSsid } else { "n/a" }
    $lastRadio = if ($S.WifiLastRadio) { [string]$S.WifiLastRadio } else { "n/a" }
    $lastChan = if ($S.WifiLastChannel) { [string]$S.WifiLastChannel } else { "n/a" }
    $lastSig = if ($null -ne $S.WifiLastSignalPct) { "$([int]$S.WifiLastSignalPct)%" } else { "n/a" }
    return @"
WI-FI SIGNAL (via netsh wlan show interfaces)
  Cycles with Wi-Fi snapshot: $captured  (context=$ctx)
  Signal min / avg / max: $min / $avg / $max
  Unique BSSIDs seen: $bssidCount$bssidCapNote $(if ($bssidCount -gt 0) { "($bssidList$(if ($bssidCount -gt 6) { ', ...' }))" })
  BSSID-change cycles (roam events): $roamCycles
  Last observation: SSID=$lastSsid Radio=$lastRadio Channel=$lastChan Signal=$lastSig
  CSV columns: WifiSsid, WifiBssid, WifiSignal, WifiRadio, WifiChannel (na when Wi-Fi not seen this cycle).
  Tip: correlate Signal dips and BSSID changes with spikes in Gateway_ms and LanGw_ms - sudden signal loss
       without a verdict flip usually means an AP roam or brief RF interference rather than an ISP/router fault.

"@
}

function Build-NetworkDiagEpisodeSection {
    param([hashtable]$S, [hashtable]$R)
    $eps = @()
    if ($S.EpisodeSummaries) { $eps = @($S.EpisodeSummaries) }
    if ($eps.Count -eq 0) {
        return @"
INCIDENT EPISODES
  Completed episodes: 0
  (No completed episodes; either run was stable or recovery-confirmation window was not reached before stop.)

"@
    }
    $top = @($eps | Select-Object -Last 10)
    $lines = @()
    foreach ($ep in $top) {
        $lines += "  - id=$($ep.EpisodeId) start=$($ep.Start) end=$($ep.End) lastBad=$($ep.LastBad) dominant=$($ep.DominantVerdict) samples=$($ep.DominantCount) evidence=$($ep.LastEvidence)"
    }
    return @"
INCIDENT EPISODES
  Completed episodes: $($eps.Count)
  Recovery rule: episode closes after sustained OK cycles (see runtime config).
$($lines -join "`n")

"@
}

function Build-NetworkDiagUdpProbeSection {
    param([hashtable]$S, [hashtable]$R)
    if (-not $R.EnableUdpProbe) {
        return "UDP CONTINUOUS PROBE`n  (disabled; pass -EnableUdpProbe with -UdpProbeTarget to turn on)`n`n"
    }
    $den = [math]::Max([int]$S.CyclesCommitted, 1)
    $totalSent = [long]$S.UdpTotalPacketsSent
    $totalErr = [long]$S.UdpTotalSendErrors
    $totalRecv = [long]$S.UdpTotalRepliesRecv
    $errPct = if ($totalSent -gt 0) { [math]::Round([double]$totalErr / [double]$totalSent * 100, 3) } else { 0.0 }
    $failPct = [math]::Round([double]$S.UdpFailCycles / $den * 100, 1)
    $stallPct = [math]::Round([double]$S.UdpStallCycles / $den * 100, 1)
    $startedNote = if ([bool]$S.UdpProbeStarted) { "yes" } else { "no" }
    $initErr = if ($S.UdpInitErrorMsg) { [string]$S.UdpInitErrorMsg } else { "(none)" }
    $lastErr = if ($S.UdpLastErrorCode) { [string]$S.UdpLastErrorCode } else { "(none)" }
    return @"
UDP CONTINUOUS PROBE
  Target / rate / payload: $($R.UdpProbeTarget) / $([int]$R.UdpProbeRateHz) Hz / $([int]$R.UdpProbePayloadBytes) bytes
  Probe started:    $startedNote (init error: $initErr)
  Total packets sent / send-errors / replies recv: $totalSent / $totalErr / $totalRecv ($errPct % error rate)
  Cycles with any UDP send-error: $($S.UdpFailCycles) ($failPct% of committed)
  Cycles flagged UDP stall (>=5 consec send errors): $($S.UdpStallCycles) ($stallPct% of committed)
  Max consecutive send errors observed: $([int]$S.UdpMaxConsecSendErrors)
  Last send error code: $lastErr
  CSV columns: Udp_PktsSent_d, Udp_SendErr_d, Udp_RepliesRecv_d, Udp_ConsecErr, Udp_LastErr.
  Tip: UDP send errors usually surface ICMP unreachable replies, route loss, or local
  firewall flips. They catch micro-blackholes that periodic ICMP cycles miss.

"@
}

function Build-NetworkDiagTcpSessionSection {
    param([hashtable]$S, [hashtable]$R)
    if (-not $R.EnableLongLivedTcp) {
        return "LONG-LIVED TCP SESSION`n  (disabled; pass -EnableLongLivedTcp with -LongLivedTcpTarget to turn on)`n`n"
    }
    $den = [math]::Max([int]$S.CyclesCommitted, 1)
    $resetPct = [math]::Round([double]$S.TcpSessionResetCycles / $den * 100, 1)
    $disPct = [math]::Round([double]$S.TcpSessionDisconnectedCycles / $den * 100, 1)
    $started = if ([bool]$S.TcpSessionStarted) { "yes" } else { "no" }
    $lastReset = if ($S.TcpSessionLastResetReason) { [string]$S.TcpSessionLastResetReason } else { "(none)" }
    return @"
LONG-LIVED TCP SESSION
  Target: $($R.TcpSessionTarget)  (started: $started)
  Connect attempts / failures: $([int]$S.TcpSessionTotalConnectAttempts) / $([int]$S.TcpSessionTotalConnectFailures)
  Total resets observed: $([int]$S.TcpSessionTotalResets)
  Cycles with new resets: $([int]$S.TcpSessionResetCycles) ($resetPct% of committed)
  Cycles where session was disconnected at sample time: $([int]$S.TcpSessionDisconnectedCycles) ($disPct% of committed)
  Last reset reason: $lastReset
  CSV columns: TcpSess_State, TcpSess_UpSec, TcpSess_Resets_d, TcpSess_LastReset.
  Tip: A small TCP_SESS_RESET burst with healthy ICMP/TCP probes usually means a
  carrier-grade NAT or stateful firewall is dropping idle flows. Game sessions feel
  this as instant disconnect / lobby-drop even when ICMP and DNS look fine.

"@
}

function Build-NetworkDiagAutoCaptureSection {
    param([hashtable]$S, [hashtable]$R)
    if (-not $R.EnableAutoCapture) {
        return "AUTO-CAPTURE (pktmon / netsh trace)`n  (disabled; pass -AutoCaptureOnFault to turn on)`n`n"
    }
    $files = @()
    if ($S.AutoCaptureFiles) { $files = @($S.AutoCaptureFiles) }
    $supported = if ([bool]$R.AutoCaptureSupported) { "yes" } else { "no (pktmon/netsh missing)" }
    $adminNote = if ([bool]$R.IsAdmin) { "yes" } else { "no (auto-capture requires admin; SKIPPED)" }
    $skippedLine = if ([bool]$S.AutoCaptureSkippedNonAdmin) { "  Skipped at least one fault because the run is non-admin (see incident log).`n" } else { "" }
    $fileBlock = if ($files.Count -eq 0) { "  No capture files produced." } else {
        ($files | ForEach-Object { "  - $_" }) -join "`n"
    }
    return @"
AUTO-CAPTURE (pktmon / netsh trace)
  Method: $($R.AutoCaptureMethod)  Seconds per capture: $([int]$R.AutoCaptureSeconds)  Max captures: $([int]$R.AutoCaptureMax)
  Tool present: $supported   Admin: $adminNote
  Captures triggered this run: $([int]$S.AutoCaptureCount)
  Last capture state: $(if ($S.AutoCaptureLastState) { $S.AutoCaptureLastState } else { 'idle' })
$skippedLine  Capture files (latest first):
$fileBlock
  CSV columns: AutoCap_State, AutoCap_Count, AutoCap_LastFile.
  Open .etl files in Microsoft Network Monitor / Message Analyzer (netsh trace) or
  via 'pktmon etl2pcapng' to convert to pcapng for Wireshark.

"@
}

function Build-NetworkDiagTlsProbeSection {
    param([hashtable]$S, [hashtable]$R)
    if (-not $R.EnableTlsProbe) {
        return "TLS HANDSHAKE PROBE`n  (disabled; pass -EnableTlsProbe to enable)`n`n"
    }
    $den = [math]::Max([int]$S.CyclesCommitted, 1)
    $cycles = [int]$S.TlsProbeCycles
    $hsFail = [int]$S.TlsHandshakeFailCycles
    $tcpUpTlsDown = [int]$S.TcpUpTlsDownCycles
    $pctCycles = [math]::Round($cycles / $den * 100, 1)
    return @"
TLS HANDSHAKE PROBE (SslStream.AuthenticateAsClientAsync)
  Cycles with TLS attempted: $cycles  ($pctCycles% of committed cycles; only runs when the underlying TCP connect succeeded)
  Individual handshake failures: $hsFail  (across both TCP_CF and TCP_GG target hosts)
  Cycles where TCP OK but at least one TLS failed: $tcpUpTlsDown
  CSV columns: TLS_CF_ms, TLS_GG_ms (-1 on failure; na when TCP connect didn't even succeed).
  Validation: TLS success requires the OS trust store to accept the peer certificate chain.
  Tip: A non-zero 'TCP OK but TLS failed' count usually points at TLS inspection (corporate MITM, captive portal
       redirect, SNI filter) or stale client-clock / root-store issues rather than packet loss.

"@
}

function Build-NetworkDiagIspEvidenceRefSection {
    param([hashtable]$S, [hashtable]$R)
    if ($R.SkipIspEvidencePacket) { return "" }
    $p = if ($R.IspEvidenceBundlePath) { $R.IspEvidenceBundlePath } else { "(to be produced at run end)" }
    $zipNote = if ($R.IspEvidenceZip) { "A ZIP alongside it was also requested." } else { "Add -IspEvidenceZip to also compress the folder." }
    return @"
ISP EVIDENCE BUNDLE
  Folder: $p
  Contents include: cover_letter, CSV, detail log, ipconfig snapshots, route table,
  winhttp proxy, per-target traceroutes (plus on-fault admin-only captures when available),
  public IP at start and end, and a SHA256 manifest.
  $zipNote

"@
}

function Build-NetworkDiagReportText {
    param(
        [hashtable]$S,
        [hashtable]$R
    )
    $den = [math]::Max($S.CyclesCommitted, 1)
    $uncommitted = $S.CyclesAttempted - $S.CyclesCommitted
    $incidentNote = if ($S.IncidentsTruncated) { "`n  Note: Incident list was truncated in memory at $($R.MaxIncidents) entries." } else { "" }
    $detailLine = if ($R.DetailActive) {
        "  Detail log        : $($R.DetailPath)`n"
    } elseif ($R.DetailRequested) {
        "  Detail log        : (disabled) $($R.DetailDisabledReason)`n"
    } else {
        ""
    }
    $uncommittedLine = if ($uncommitted -gt 0) {
        "  Cycles started but not committed (no CSV flush): $uncommitted`n"
    } else {
        ""
    }
    $runConfig  = Build-NetworkDiagRunConfigSection -S $S -R $R
    $limits     = Build-NetworkDiagLimitationsSection -R $R
    $pcLink     = Build-NetworkDiagPcLinkSection -S $S
    $runtimeHealth = Build-NetworkDiagRuntimeHealthSection -S $S
    $dnsBlock   = Format-NetworkDiagDnsResolutionSection -S $S -Den $den -DnsName $R.DnsProbeName -DnsCapMs $R.DnsTimeoutMs -SkipDns $R.SkipDnsProbe
    $latBlock   = Build-NetworkDiagLatencySection -S $S -R $R
    $diagText   = Build-NetworkDiagDiagnosisSection -S $S -R $R
    $cfgAudit   = Build-NetworkDiagConfigAuditSection -S $S -R $R
    $cableHints = Build-NetworkDiagCableHintsSection -S $S -R $R
    $multiNic   = Build-NetworkDiagMultiNicSection -S $S -R $R
    $episodes   = Build-NetworkDiagEpisodeSection -S $S -R $R
    $wifiSig    = Build-NetworkDiagWifiSignalSection -S $S -R $R
    $tlsProbe   = Build-NetworkDiagTlsProbeSection -S $S -R $R
    $udpProbe   = Build-NetworkDiagUdpProbeSection -S $S -R $R
    $tcpSession = Build-NetworkDiagTcpSessionSection -S $S -R $R
    $autoCap    = Build-NetworkDiagAutoCaptureSection -S $S -R $R
    $ispRef     = Build-NetworkDiagIspEvidenceRefSection -S $S -R $R
    $partialBanner = if ($R.ContainsKey("PartialRun") -and [bool]$R.PartialRun) {
@"
PARTIAL SNAPSHOT (run in progress)
  This report is an interim checkpoint. Final totals and diagnosis are produced at run end.

"@
    } else { "" }

    return @"
===============================================================
  LAYERED NETWORK DIAGNOSTIC REPORT
  Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
===============================================================

$partialBanner
$runConfig

$limits

$pcLink$runtimeHealth$cfgAudit$cableHints$multiNic$episodes$wifiSig$tlsProbe$udpProbe$tcpSession$autoCap$dnsBlock$latBlock
DURATION
  Planned:  $($R.DurationMinutes) minutes
  Cycles attempted:  $($S.CyclesAttempted)
  Cycles committed: $($S.CyclesCommitted) (CSV rows successfully flushed)
$uncommittedLine
  Base interval: $($R.IntervalSeconds) sec | Effective sleep: max(0, base-or-burst-interval - measured cycle wall time)$(if ($R.BurstOnFault) { " | Burst: $($R.BurstIntervalSeconds)s when active" } else { "" })

RESULTS SUMMARY (percentages use committed cycles as denominator)
  All OK:        $($S.AllOK)  ($([math]::Round($S.AllOK / $den * 100, 1))%)
  ISP Faults:    $($S.ISP_Fault)  ($([math]::Round($S.ISP_Fault / $den * 100, 1))%)
  Local Faults:  $($S.Local_Fault)  ($([math]::Round($S.Local_Fault / $den * 100, 1))%)
  Anomalies:     $($S.Anomaly)  ($([math]::Round($S.Anomaly / $den * 100, 1))%)

DIAGNOSIS
$diagText

INCIDENT LOG ($($S.Incidents.Count) events)$incidentNote
---------------------------------------------------------------
$(if ($S.Incidents.Count -eq 0) {
"  (none - no fault incidents logged)"
} else {
    $S.Incidents | ForEach-Object { "  $_" } | Out-String
})
---------------------------------------------------------------

FILES
  Detailed CSV log : $($R.CsvPath)
$detailLine  This report       : $($R.ReportPath)

$ispRef
HOW TO USE THIS WITH YOUR ISP
  1. If diagnosis points beyond your LAN and TCP agrees with ICMP, gather CSV + timestamps for the ISP.
  2. If Evidence shows TCP_OK_ICMP_FAIL often, ask whether they filter ICMP before accepting outage claims.
  3. Attach CSV (and detail log if you used -DetailLog) if they want raw data.
  4. The ISP evidence bundle above is pre-packaged: hand over the whole folder (or the -IspEvidenceZip archive) and point at the cover_letter first.
===============================================================
"@
}
