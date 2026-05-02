#Requires -Version 5.1
<#
.SYNOPSIS
    Layered network diagnostic - PC, Ethernet link, router, then internet
    (ICMP + optional TCP), plus device-config audit, cable/NIC hints,
    optional simultaneous Wi-Fi/Ethernet cross-check on faults, and an
    ISP-ready evidence bundle.

.DESCRIPTION
    Each cycle: loopback ping, bound adapter status/counters, optional DNS
    resolution (timed), underlay LAN gateway ping (when resolved), primary
    gateway ping, N external ICMP targets (multi-ping per target with bounded
    timeout), then optional TCP/443 probes. Logs CSV and a text report; use
    -DetailLog for a human-readable per-cycle narrative.

    On every non-OK cycle (unless individually disabled) the script also runs:
        * a device config audit (APIPA, IP conflicts, subnet/DNS, proxy, NDIS
          link events, power mgmt / EEE, optional path MTU);
        * cable/NIC hints (link speed vs baseline, link flaps, vendor diag
          advanced properties);
        * a simultaneous Wi-Fi/Ethernet cross-check (parallel probes on alt
          adapters with their own gateway; strict host-route pinning when
          admin, loose probe otherwise).

    At run end, an ISP evidence bundle is produced next to the main report:
    cover letter, report/CSV/detail copies, ipconfig/route/proxy snapshots,
    per-target traceroutes, public IP at start+end, and SHA256 manifest.
    Optional -IspEvidenceZip compresses the bundle folder into a .zip.

    The script architecture is a small entrypoint that dot-sources lib/*.ps1:
      lib\common.ps1       - helpers, admin detection, bounded process wrapper
      lib\routing.ps1      - default route, underlay, tunnel classification
      lib\probes.ps1       - ICMP / TCP / DNS / external-targets builder
      lib\latency.ps1      - bounded latency aggregator with p95 reservoir
      lib\cycle.ps1        - per-cycle orchestrator + verdict tree
      lib\report.ps1       - CSV manifest + report section builders
      lib\config-audit.ps1 - Invoke-NetworkDiagConfigAudit
      lib\cable-hints.ps1  - Get-NetworkDiagCableHints
      lib\multinic.ps1     - cross-check roster + Invoke-NetworkDiagMultiNicProbe
      lib\isp-bundle.ps1   - Write-NetworkDiagIspEvidenceBundle
    Use tools\bundle-single-file.ps1 to produce a portable one-file copy.

.PARAMETER DurationMinutes
    How long to run the test (default: 60 minutes). Must be at least 1.

.PARAMETER IntervalSeconds
    Time between each ping cycle (default: 3 seconds). Must be 1-3600.

.PARAMETER MonitoringMode
    Controls monitoring defaults used by long-running safety features:
    Auto (default), ShortRun, or LongRun. Auto resolves to LongRun when
    DurationMinutes is 120 or more; otherwise ShortRun.

.PARAMETER HeartbeatMinutes
    Heartbeat cadence in minutes. Use -1 (default) to use MonitoringMode
    defaults (LongRun=15, ShortRun=0).

.PARAMETER SnapshotMinutes
    Partial report/summary snapshot cadence in minutes. Use -1 (default) to
    use MonitoringMode defaults (LongRun=60, ShortRun=0).

.PARAMETER EventLogLookbackMinutes
    Event log lookback in minutes for config-audit event checks. Use -1
    (default) to use MonitoringMode defaults (LongRun=15, ShortRun=0, where
    0 means since run start).

.PARAMETER OutputFolder
    Root folder where run folders are created. Each execution writes logs into
    OutputFolder\runs\run_<timestamp>. Probed for write access; if not writable,
    falls back in order: script directory ($PSScriptRoot), Desktop\NetworkTest,
    then TEMP\NetworkTest.

.PARAMETER RequireEthernet
    Exit if the default route is not on an Ethernet-class adapter (at startup
    only; route refresh never terminates the run).

.PARAMETER SkipTcpProbe
    When set, disables TCP port 443 probes (ICMP-only).

.PARAMETER DetailLog
    Write network_detail_<timestamp>.log with a plain-language line per cycle.

.PARAMETER LegacyCsvShape
    Emit the original CSV column set only (no dual-layer or new-feature columns).

.PARAMETER ExternalIcmpHosts
    Two to six addresses or hostnames to ping each cycle.

.PARAMETER ExternalIcmpLabels
    Optional display labels matching ExternalIcmpHosts count.

.PARAMETER TcpProbeHosts
    Optional exactly two hosts for TCP/443. When omitted defaults follow the
    first two ICMP probe endpoints.

.PARAMETER DnsProbeName
    Name resolved each cycle before gateway ICMP (default www.google.com).

.PARAMETER SkipDnsProbe
    Omit DNS resolution; CSV Dns_* columns use na.

.PARAMETER IcmpCountPerTarget
    ICMP echo attempts per target per cycle (default 2).

.PARAMETER IcmpTimeoutSeconds
    Per-attempt timeout for ICMP (default 2).

.PARAMETER DnsTimeoutMs
    Async wait cap in milliseconds for DNS resolution (default 3000).

.PARAMETER BurstOnFault
    After a non-OK committed cycle, temporarily shorten the cycle interval.

.PARAMETER BurstIntervalSeconds
    Interval during burst (must be less than -IntervalSeconds).

.PARAMETER BurstCycles
    Count of short-interval cycles after each fault while burst mode is active.

.PARAMETER MaxBurstSeconds
    Maximum wall time per burst episode from first entry into burst.

.PARAMETER GwIcmpPolicyConfirmCycles
    Normal routing only: consecutive cycles required before treating a stable
    gateway-ICMP-fail pattern as a policy limitation.

.PARAMETER SkipGwIcmpPolicyAdaptation
    Normal routing only: disable automatic gateway ICMP policy adaptation.

.PARAMETER RoutingRefreshIntervalCycles
    When greater than zero, re-resolves default gateway, routed adapter, tunnel
    classification, and underlay at the main loop boundary every N attempted
    cycles.

.PARAMETER PinExternalIcmpToResolvedIp
    After startup hostname resolution, ping the resolved IP instead of the
    hostname.

.PARAMETER ProbeAddressFamily
    IPv4 (default) or IPv6.

.PARAMETER SkipConfigAudit
    Disable the device configuration audit (APIPA / IP state / subnet /
    DNS / multi-gateway / DHCP / WinHTTP proxy / Tcpip+NDIS events /
    power+EEE / optional path MTU). Default on.

.PARAMETER SkipCableHints
    Disable the cable / NIC physical-layer hint module (link-degrade,
    link-flap, vendor advanced-property scan, CABLE_SUSPECT). Default on.

.PARAMETER SkipMultiNicCrossCheck
    Disable the simultaneous Wi-Fi/Ethernet cross-check on non-OK cycles.
    Default on when the roster has at least one eligible alt adapter.

.PARAMETER SkipIspEvidencePacket
    Disable the ISP evidence bundle produced at run end. Default on.

.PARAMETER IspEvidenceZip
    Also zip the ISP evidence folder into ispevidence_<timestamp>.zip.

.PARAMETER PathMtuProbeTarget
    If set (hostname or IPv4 literal), runs a DF-bit path-MTU probe during
    the config audit at startup and on route refresh; flags MTU_LOW_<n> when
    under 1400.

.PARAMETER SkipWifiSignal
    Disable per-cycle Wi-Fi signal capture (SSID/BSSID/Signal%/Radio/Channel
    via `netsh wlan show interfaces`). Default on when the primary adapter
    is Wi-Fi or the multi-NIC cross-check roster contains a Wi-Fi entry.

.PARAMETER EnableTlsProbe
    When set, adds a TLS handshake probe on top of each TCP/443 probe
    using SslStream.AuthenticateAsClient with a short timeout. Success
    means the full TLS handshake completed (cert chain is validated by
    the OS trust store). Adds two CSV columns (TLS_CF_ms, TLS_GG_ms)
    and a TLS section in the report.

.PARAMETER SkipJsonSummary
    Disable the run summary JSON (network_summary_<ts>.json) written next
    to the text report at run end. Default on.

.PARAMETER SelfTest
    Runs startup preflight/self-test checks only, writes self-test text/JSON,
    then exits without entering the cycle loop.

.PARAMETER EnableUdpProbe
    Run a continuous UDP send-only probe in a background runspace at a
    configurable rate. Detects micro-blackholes / TX-stalls / firewall
    flips that periodic ICMP cycles miss. Adds Udp_* columns to the CSV
    and a UDP CONTINUOUS PROBE section to the report.

.PARAMETER UdpProbeTarget
    Host:port for -EnableUdpProbe (default 8.8.8.8:443). Send-only - the
    target does not need to echo. Send errors typically surface via ICMP
    unreachable replies.

.PARAMETER UdpProbeRateHz
    Send rate for -EnableUdpProbe (default 30; capped at 1..1000).

.PARAMETER UdpProbePayloadBytes
    Datagram payload size for -EnableUdpProbe (default 64; capped 1..1400).

.PARAMETER EnableLongLivedTcp
    Open one persistent TCP connection (with SO_KEEPALIVE) in a background
    runspace and watch for FIN/RST. Detects carrier-grade NAT timeouts
    and brief session resets that the cycle's short-lived TCP probes
    cannot see. Adds TcpSess_* columns to the CSV and a LONG-LIVED TCP
    SESSION section to the report.

.PARAMETER LongLivedTcpTarget
    Host:port for -EnableLongLivedTcp (default 1.1.1.1:443).

.PARAMETER LongLivedTcpReconnectBackoffSeconds
    Pause before each reconnect attempt after a reset (default 5).

.PARAMETER PerProbeTimestamps
    Append <Probe>_t_ms columns to the CSV (and a ProbeTs=[...] segment
    to each detail line). Each value is the ms-offset from the cycle
    Timestamp at the moment that probe started, so order and slow probes
    are visible per row instead of being collapsed into one cycle stamp.

.PARAMETER AutoCaptureOnFault
    On the first non-OK cycle, automatically start a packet capture
    (default pktmon, fallback netsh trace) for -AutoCaptureSeconds and
    write the .etl into <run>\captures\. Requires admin; non-admin runs
    log a single AUTO_CAPTURE_SKIPPED incident and continue.

.PARAMETER AutoCaptureMethod
    Capture tool for -AutoCaptureOnFault: 'pktmon' (default) or
    'netshtrace'.

.PARAMETER AutoCaptureSeconds
    Capture duration in seconds (default 30; capped 5..600).

.PARAMETER AutoCaptureMax
    Maximum captures to trigger across the whole run (default 1).

.EXAMPLE
    .\network-stability-test.ps1
    60-minute run with all new diagnostic layers enabled.

.EXAMPLE
    .\network-stability-test.ps1 -IspEvidenceZip -PathMtuProbeTarget 1.1.1.1
    Same, plus zip the evidence bundle and include a path-MTU probe.

.EXAMPLE
    .\network-stability-test.ps1 -SkipMultiNicCrossCheck -SkipIspEvidencePacket
    Disable multi-NIC cross-check and the evidence bundle.
#>

param(
    [ValidateRange(1, [int]::MaxValue)]
    [int]$DurationMinutes   = 60,
    [ValidateRange(1, 3600)]
    [int]$IntervalSeconds   = 3,
    [ValidateSet("Auto", "ShortRun", "LongRun")]
    [string]$MonitoringMode = "Auto",
    [ValidateRange(-1, 1440)]
    [int]$HeartbeatMinutes = -1,
    [ValidateRange(-1, 1440)]
    [int]$SnapshotMinutes = -1,
    [ValidateRange(-1, 1440)]
    [int]$EventLogLookbackMinutes = -1,
    [string]$OutputFolder   = "",
    [switch]$RequireEthernet,
    [switch]$SkipTcpProbe,
    [switch]$DetailLog,
    [switch]$LegacyCsvShape,
    [string[]]$ExternalIcmpHosts = @("1.1.1.1", "8.8.8.8", "9.9.9.9"),
    [string[]]$ExternalIcmpLabels = @(),
    [string[]]$TcpProbeHosts = @(),
    [string]$DnsProbeName = "www.google.com",
    [switch]$SkipDnsProbe,
    [ValidateRange(1, 6)]
    [int]$IcmpCountPerTarget = 2,
    [ValidateRange(1, 60)]
    [int]$IcmpTimeoutSeconds = 2,
    [ValidateRange(500, 60000)]
    [int]$DnsTimeoutMs = 3000,
    [switch]$BurstOnFault,
    [ValidateRange(1, 3599)]
    [int]$BurstIntervalSeconds = 1,
    [ValidateRange(1, [int]::MaxValue)]
    [int]$BurstCycles = 5,
    [ValidateRange(1, [int]::MaxValue)]
    [int]$MaxBurstSeconds = 60,
    [ValidateRange(2, 999)]
    [int]$GwIcmpPolicyConfirmCycles = 8,
    [switch]$SkipGwIcmpPolicyAdaptation,
    [ValidateRange(0, 100000)]
    [int]$RoutingRefreshIntervalCycles = 0,
    [switch]$PinExternalIcmpToResolvedIp,
    [ValidateSet("IPv4", "IPv6")]
    [string]$ProbeAddressFamily = "IPv4",
    [switch]$SkipConfigAudit,
    [switch]$SkipCableHints,
    [switch]$SkipMultiNicCrossCheck,
    [switch]$SkipIspEvidencePacket,
    [switch]$IspEvidenceZip,
    [string]$PathMtuProbeTarget = "",
    [switch]$SkipWifiSignal,
    [switch]$EnableTlsProbe,
    [switch]$SkipJsonSummary,
    [switch]$SelfTest,
    [switch]$EnableUdpProbe,
    [string]$UdpProbeTarget = "8.8.8.8:443",
    [ValidateRange(1, 1000)]
    [int]$UdpProbeRateHz = 30,
    [ValidateRange(1, 1400)]
    [int]$UdpProbePayloadBytes = 64,
    [switch]$EnableLongLivedTcp,
    [string]$LongLivedTcpTarget = "1.1.1.1:443",
    [ValidateRange(1, 600)]
    [int]$LongLivedTcpReconnectBackoffSeconds = 5,
    [switch]$PerProbeTimestamps,
    [switch]$AutoCaptureOnFault,
    [ValidateSet("pktmon", "netshtrace")]
    [string]$AutoCaptureMethod = "pktmon",
    [ValidateRange(5, 600)]
    [int]$AutoCaptureSeconds = 30,
    [ValidateRange(1, 100)]
    [int]$AutoCaptureMax = 1
)

$doTcpProbe = -not $SkipTcpProbe

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:NetworkDiagSchemaVersion = "2026-04"
$script:NetworkDiagEpisodeRecoveryConfirmCycles = 3
$script:NetworkDiagWifiSnapshotMinSeconds = 15

# >>> NETDIAG_BUNDLE_DOTSOURCE_BEGIN <<<
$libRoot = Join-Path $PSScriptRoot 'lib'
foreach ($f in @('common.ps1', 'latency.ps1', 'probes.ps1', 'routing.ps1', 'report.ps1', 'cycle.ps1', 'config-audit.ps1', 'cable-hints.ps1', 'multinic.ps1', 'wifi-signal.ps1', 'isp-bundle.ps1', 'summary-json.ps1', 'udp-probe.ps1', 'tcp-session.ps1', 'auto-capture.ps1')) {
    $p = Join-Path $libRoot $f
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host "ERROR: Missing library file: $p (keep lib/ next to the entrypoint or run tools\bundle-single-file.ps1 to produce a portable copy)." -ForegroundColor Red
        exit 5
    }
    . $p
}
# >>> NETDIAG_BUNDLE_DOTSOURCE_END <<<

# ── Validation ────────────────────────────────────────────────────────────
if ($DurationMinutes -gt 10080) {
    Write-Warning "Duration exceeds 7 days (10080 minutes). CSV and logs may grow very large."
}

$ExternalIcmpHosts = @($ExternalIcmpHosts | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($ExternalIcmpHosts.Count -eq 1 -and $ExternalIcmpHosts[0] -match ",") {
    $ExternalIcmpHosts = @($ExternalIcmpHosts[0].Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if ($ExternalIcmpHosts.Count -lt 2 -or $ExternalIcmpHosts.Count -gt 6) {
    Write-Host "ERROR: -ExternalIcmpHosts must list between 2 and 6 addresses or hostnames." -ForegroundColor Red
    exit 3
}
if ($ExternalIcmpLabels.Count -gt 0 -and $ExternalIcmpLabels.Count -ne $ExternalIcmpHosts.Count) {
    Write-Host "ERROR: -ExternalIcmpLabels must be empty or match -ExternalIcmpHosts count." -ForegroundColor Red
    exit 3
}
if ($TcpProbeHosts.Count -gt 0 -and $TcpProbeHosts.Count -ne 2) {
    Write-Host "ERROR: -TcpProbeHosts must be empty or contain exactly two host entries." -ForegroundColor Red
    exit 3
}
if ($BurstOnFault -and $BurstIntervalSeconds -ge $IntervalSeconds) {
    Write-Host "ERROR: With -BurstOnFault, -BurstIntervalSeconds must be less than -IntervalSeconds." -ForegroundColor Red
    exit 3
}

function Split-NetworkDiagHostPort {
    param([Parameter(Mandatory = $true)][string]$Raw, [int]$DefaultPort = 0)
    $s = [string]$Raw.Trim()
    if (-not $s) { throw "empty host:port" }
    if ($s.StartsWith("[")) {
        $end = $s.IndexOf("]")
        if ($end -lt 2) { throw "malformed bracketed IPv6 literal: $Raw" }
        $h = $s.Substring(1, $end - 1)
        if (-not $h) { throw "empty host in '$Raw'" }
        $rest = $s.Substring($end + 1)
        $p = 0
        if ($rest.StartsWith(":")) {
            if (-not [int]::TryParse($rest.Substring(1), [ref]$p)) { throw "invalid port in '$Raw'" }
        } else {
            $p = [int]$DefaultPort
        }
        if ($p -lt 1 -or $p -gt 65535) { throw "port out of range in '$Raw' (must be 1..65535)" }
        return @{ Host = $h; Port = $p }
    }
    $idx = $s.LastIndexOf(":")
    if ($idx -lt 0) {
        $p = [int]$DefaultPort
        if ($p -le 0) { throw "no port in '$Raw' and no default" }
        if ($p -lt 1 -or $p -gt 65535) { throw "default port out of range ($p); must be 1..65535" }
        return @{ Host = $s; Port = $p }
    }
    $h = $s.Substring(0, $idx)
    if (-not $h) { throw "empty host in '$Raw'" }
    $portStr = $s.Substring($idx + 1)
    $p = 0
    if (-not [int]::TryParse($portStr, [ref]$p)) {
        throw "invalid port in '$Raw'"
    }
    if ($p -lt 1 -or $p -gt 65535) { throw "port out of range in '$Raw' (must be 1..65535)" }
    return @{ Host = $h; Port = [int]$p }
}

$udpHostPort = $null
if ($EnableUdpProbe) {
    try { $udpHostPort = Split-NetworkDiagHostPort -Raw $UdpProbeTarget -DefaultPort 443 } catch {
        Write-Host "ERROR: -UdpProbeTarget '$UdpProbeTarget' is not host:port - $($_.Exception.Message)" -ForegroundColor Red
        exit 3
    }
}
$tcpSessHostPort = $null
if ($EnableLongLivedTcp) {
    try { $tcpSessHostPort = Split-NetworkDiagHostPort -Raw $LongLivedTcpTarget -DefaultPort 443 } catch {
        Write-Host "ERROR: -LongLivedTcpTarget '$LongLivedTcpTarget' is not host:port - $($_.Exception.Message)" -ForegroundColor Red
        exit 3
    }
}
$autoCaptureSupported = $false
if ($AutoCaptureOnFault) {
    if (Get-Command -Name "Test-NetworkDiagAutoCaptureSupported" -ErrorAction SilentlyContinue) {
        $autoCaptureSupported = [bool](Test-NetworkDiagAutoCaptureSupported -Method $AutoCaptureMethod)
    }
}

$resolvedMonitoringMode = [string]$MonitoringMode
if ($resolvedMonitoringMode -eq "Auto") {
    $resolvedMonitoringMode = if ($DurationMinutes -ge 120) { "LongRun" } else { "ShortRun" }
}
$modeHeartbeatDefault = if ($resolvedMonitoringMode -eq "LongRun") { 15 } else { 0 }
$modeSnapshotDefault = if ($resolvedMonitoringMode -eq "LongRun") { 60 } else { 0 }
$modeEventLookbackDefault = if ($resolvedMonitoringMode -eq "LongRun") { 15 } else { 0 }
$effectiveHeartbeatMinutes = if ($HeartbeatMinutes -ge 0) { [int]$HeartbeatMinutes } else { [int]$modeHeartbeatDefault }
$effectiveSnapshotMinutes = if ($SnapshotMinutes -ge 0) { [int]$SnapshotMinutes } else { [int]$modeSnapshotDefault }
$effectiveEventLogLookbackMinutes = if ($EventLogLookbackMinutes -ge 0) { [int]$EventLogLookbackMinutes } else { [int]$modeEventLookbackDefault }
$script:NetworkDiagWifiSnapshotMinSeconds = if ($resolvedMonitoringMode -eq "LongRun") { 30 } else { 15 }

$script:NetworkDiagProbeAddressFamily = $ProbeAddressFamily
$script:NetworkDiagLoopbackProbe = if ($ProbeAddressFamily -eq "IPv6") { "::1" } else { "127.0.0.1" }
$script:MaxIncidentsInMemory = 500
$script:IsAdmin = $null
$null = Test-NetworkDiagIsAdmin

# IPv6 mode + still the IPv4 default trio -> substitute built-in IPv6 literals
$NetworkDiagDefaultExternalV4 = @("1.1.1.1", "8.8.8.8", "9.9.9.9")
if ($ProbeAddressFamily -eq "IPv6" -and $ExternalIcmpHosts.Count -eq 3) {
    $allDefaultV4 = $true
    for ($__ci = 0; $__ci -lt 3; $__ci++) {
        if ([string]$ExternalIcmpHosts[$__ci] -cne [string]$NetworkDiagDefaultExternalV4[$__ci]) {
            $allDefaultV4 = $false; break
        }
    }
    if ($allDefaultV4) {
        $ExternalIcmpHosts = @("2606:4700:4700::1111", "2001:4860:4860::8888", "2620:fe::fe")
    }
}

# ── Output folder resolution + abort-roots ────────────────────────────────
$resolvedFolder = Resolve-NetworkDiagOutputFolder -UserSpecifiedFolder $(if ($OutputFolder) { $OutputFolder } else { "" })
if (-not $resolvedFolder) {
    Write-Host "ERROR: No writable output folder (tried script directory, Desktop\NetworkTest, TEMP\NetworkTest)." -ForegroundColor Red
    $null = Write-NetworkDiagAbortFile -Reason "NoWritableOutputFolder" -Details "All folder candidates failed write probe." -OutputRoots @($env:TEMP)
    exit 2
}
$outputRoot = $resolvedFolder.Path
$outputResolutionLabel = $resolvedFolder.Label
$timestamp    = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$runsRoot     = Join-Path $outputRoot "runs"
$OutputFolder = Join-Path $runsRoot "run_$timestamp"
try {
    if (-not (Test-Path -LiteralPath $runsRoot -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $runsRoot -Force)
    }
    if (-not (Test-Path -LiteralPath $OutputFolder -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $OutputFolder -Force)
    }
} catch {
    $msg = $_.Exception.Message
    Write-Host "ERROR: Could not create run output folder at $OutputFolder : $msg" -ForegroundColor Red
    $null = Write-NetworkDiagAbortFile -Reason "RunFolderCreateFailed" -Details "root=$outputRoot runFolder=$OutputFolder error=$msg" -OutputRoots @($outputRoot, $env:TEMP)
    exit 2
}
Write-Host "Output root: $outputRoot ($outputResolutionLabel)" -ForegroundColor Gray
Write-Host "Run folder : $OutputFolder" -ForegroundColor Gray

$csvPath      = Join-Path $OutputFolder "network_log_$timestamp.csv"
$reportPath   = Join-Path $OutputFolder "network_report_$timestamp.txt"
$detailPath   = Join-Path $OutputFolder "network_detail_$timestamp.log"
$ipconfigStartPath = Join-Path $OutputFolder "ipconfig_start_$timestamp.txt"
$abortRoots   = @(
    $OutputFolder,
    (Join-Path $env:TEMP "NetworkTest"),
    $env:TEMP
)

# ── Startup routing resolution ────────────────────────────────────────────
Write-Host "`n=== Layered Network Diagnostic ===" -ForegroundColor Cyan
Write-Host "Detecting default gateway and routed adapter..." -ForegroundColor Yellow
$startupRouting = Invoke-NetworkDiagRoutingResolution -Mode Startup -RequireEthernetSwitch:$RequireEthernet -AbortRoots $abortRoots
$gateway = $startupRouting.Gateway
$routeIfIndex = $startupRouting.RouteIfIndex
$defaultRoute = $startupRouting.DefaultRoute
$defaultRouteSelectionReason = $startupRouting.DefaultRouteSelectionReason
$boundAdapter = $startupRouting.BoundAdapter
$tunnelClass = $startupRouting.TunnelClass
$routingContext = $startupRouting.RoutingContext
$underlayState = $startupRouting.UnderlayState
$underlayIfIndex = $startupRouting.UnderlayIfIndex
$underlayGateway = $startupRouting.UnderlayGateway
$underlayAdapterName = $startupRouting.UnderlayAdapterName
$underlayAvailable = $startupRouting.UnderlayAvailable
$underlayIsEthernet = $startupRouting.UnderlayIsEthernet
$underlayReasonCode = $startupRouting.UnderlayReasonCode
$underlayMayBeVirtual = $startupRouting.UnderlayMayBeVirtual
$underlayMetric = $startupRouting.UnderlayMetric
$primaryAdapterDisp = $startupRouting.PrimaryAdapterDisp
$isEthernetBound = $startupRouting.IsEthernetBound
$requireEthernetSatisfied = $startupRouting.RequireEthernetSatisfied

# ── External targets + TCP probe pair ────────────────────────────────────
$nExternal = $ExternalIcmpHosts.Count
$externalTargets = Build-NetworkDiagExternalTargets -ExternalIcmpHosts $ExternalIcmpHosts -ExternalIcmpLabels $ExternalIcmpLabels -ProbeAddressFamily $ProbeAddressFamily -DnsTimeoutMs $DnsTimeoutMs -PinExternalIcmpToResolvedIp:$PinExternalIcmpToResolvedIp

if ($nExternal -gt 0) {
    Write-Host "  External ICMP targets ($ProbeAddressFamily; ICMP string -> TCP string):" -ForegroundColor Gray
    foreach ($et in $externalTargets) {
        $rv = if ($et.ResolvedProbeIp) { $et.ResolvedProbeIp } else { "n/a" }
        Write-Host "    $($et.Name): $($et.Host) -> ICMP=$($et.IcmpTarget)  TCP=$($et.TcpHostForProbe)  resolved=$rv" -ForegroundColor Gray
    }
}
if ($TcpProbeHosts.Count -eq 2) {
    $tcpHostA = $TcpProbeHosts[0].Trim()
    $tcpHostB = $TcpProbeHosts[1].Trim()
} else {
    $tcpHostA = [string]$externalTargets[0].TcpHostForProbe
    $tcpHostB = if ($externalTargets.Count -ge 2) { [string]$externalTargets[1].TcpHostForProbe } else { [string]$externalTargets[0].TcpHostForProbe }
}

$defaultExternalTriplet = @("1.1.1.1", "8.8.8.8", "9.9.9.9")
if ($LegacyCsvShape -and $nExternal -eq 3) {
    $tripletMismatch = $false
    for ($ti = 0; $ti -lt 3; $ti++) {
        if ([string]$ExternalIcmpHosts[$ti] -ne [string]$defaultExternalTriplet[$ti]) { $tripletMismatch = $true; break }
    }
    if ($tripletMismatch) {
        Write-Host "WARNING: -LegacyCsvShape uses CSV column names Cloudflare_ms, Google_ms, Quad9_ms as positional aliases for the first three -ExternalIcmpHosts entries (not necessarily those providers)." -ForegroundColor Yellow
    }
}

$csvColumnManifest = Get-NetworkDiagCsvColumnManifest -LegacyCsvShape:$LegacyCsvShape -ExternalCount $nExternal -IncludeUdp:$EnableUdpProbe -IncludeTcpSession:$EnableLongLivedTcp -IncludeAutoCapture:$AutoCaptureOnFault -IncludePerProbeTimestamps:$PerProbeTimestamps

$baselineEthMbps = $null
if ($boundAdapter) { $baselineEthMbps = ConvertTo-LinkMbps $boundAdapter.LinkSpeed }
$cableBaseline = $null
if (-not $SkipCableHints -and $boundAdapter) {
    $cableBaseline = Get-NetworkDiagCableBaseline -Adapter $boundAdapter
}
$multiNicRoster = @()
if (-not $SkipMultiNicCrossCheck) {
    $multiNicRoster = @(Get-NetworkDiagCrossCheckRoster -ProbeAddressFamily $ProbeAddressFamily -PrimaryRouteIfIndex $routeIfIndex)
}

# ── Stats + state ─────────────────────────────────────────────────────────
$stats = New-NetworkDiagStats -ExternalCount $nExternal

$runStartTime = Get-Date
$runDurationSeconds = [double]$DurationMinutes * 60.0
$runClock = [System.Diagnostics.Stopwatch]::StartNew()
$endTime = $runStartTime.AddSeconds($runDurationSeconds)

$plannedCycles = [math]::Max(1, [int][math]::Ceiling($runDurationSeconds / [double]$IntervalSeconds))
$burstFactor = if ($BurstOnFault) { 1.5 } else { 1.0 }
$projectedRows = [math]::Max(1, [int][math]::Ceiling([double]$plannedCycles * $burstFactor))
$projectedCsvBytes = [int64](2048 + ($projectedRows * 300))
$projectedDetailBytes = if ($DetailLog) { [int64]($projectedRows * 800) } else { [int64]0 }
$projectedTotalBytes = [int64]($projectedCsvBytes + $projectedDetailBytes)
$diskFreeBytes = [int64]0
try {
    $outRoot = [System.IO.Path]::GetPathRoot($OutputFolder)
    if ($outRoot) {
        $di = New-Object System.IO.DriveInfo($outRoot)
        $diskFreeBytes = [int64]$di.AvailableFreeSpace
    }
} catch {
    Write-Host "WARNING: Disk free-space probe failed for '$OutputFolder': $($_.Exception.Message)" -ForegroundColor Yellow
}
$diskBudgetOk = $true
if ($projectedTotalBytes -gt 0 -and $diskFreeBytes -gt 0) {
    $diskBudgetOk = ($diskFreeBytes -ge ([int64]($projectedTotalBytes * 3)))
}

# Startup config audit (one shot; cached into $cycleState.ConfigAuditCache for re-use by cycle hook).
$configAuditStartupCodes = @()
if (-not $SkipConfigAudit) {
    $tmpCfg = @{
        ProbeAddressFamily = $ProbeAddressFamily
        PathMtuProbeTarget = $PathMtuProbeTarget
    }
    $tmpSnap = @{
        RouteIfIndex    = $routeIfIndex
        Gateway         = $gateway
        BoundAdapter    = $boundAdapter
    }
    $startupAudit = Invoke-NetworkDiagConfigAudit -Cfg $tmpCfg -Snap $tmpSnap -RunStart $runStartTime -Cached $null -LookbackMinutes $effectiveEventLogLookbackMinutes
    if ($startupAudit) {
        $configAuditStartupCodes = @($startupAudit.FindingCodes)
        $stats.ConfigAuditLastCodes = $configAuditStartupCodes
    }
    if ($configAuditStartupCodes.Count -gt 0) {
        $startTs = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        Add-NetworkDiagIncident -Stats $stats -Line "$startTs  CONFIG_AUDIT_START codes=$($configAuditStartupCodes -join ',')"
    }
}

# ── Display plan ─────────────────────────────────────────────────────────
Write-Host "`nPlan:" -ForegroundColor Yellow
Write-Host "  Duration       : $DurationMinutes minutes (until $($endTime.ToString('HH:mm:ss')))"
$burstPlanNote = if ($BurstOnFault) {
    "; burst on fault: ${BurstIntervalSeconds}s for up to $BurstCycles cycles, max ${MaxBurstSeconds}s wall per episode"
} else { "" }
Write-Host "  Cycle interval : base every $IntervalSeconds s (sleep max(0, interval - cycle wall time))$burstPlanNote"
Write-Host "  Probe stack    : $ProbeAddressFamily (CSV column ProbeAddressFamily)" -ForegroundColor Gray
Write-Host "  Monitoring mode: $resolvedMonitoringMode (heartbeat=$effectiveHeartbeatMinutes min; snapshot=$effectiveSnapshotMinutes min; eventLookback=$(if ($effectiveEventLogLookbackMinutes -gt 0) { "$effectiveEventLogLookbackMinutes min" } else { 'since run start' }))" -ForegroundColor Gray
Write-Host "  Schema version : $script:NetworkDiagSchemaVersion (report/JSON + non-legacy CSV)" -ForegroundColor Gray
Write-Host "  Episode close  : $script:NetworkDiagEpisodeRecoveryConfirmCycles consecutive OK cycles" -ForegroundColor Gray
if ($RoutingRefreshIntervalCycles -gt 0) {
    Write-Host "  Route refresh  : every $RoutingRefreshIntervalCycles attempted cycle(s) (see ROUTE_REFRESH incidents)" -ForegroundColor Gray
}
Write-Host "  Layers         : Loopback -> NIC -> DNS -> LanGW -> Gateway -> ICMP externals$(if ($doTcpProbe) { ' -> TCP/443' })$(if (-not $LegacyCsvShape) { ' (+ underlay Lan_* when resolved)' })"
Write-Host "  Routing context: $routingContext$(if ($LegacyCsvShape) { ' (CSV: legacy shape)' } else { ' (CSV: full dual-layer + new columns)' })"
Write-Host "  Targets        : Gateway ($gateway), $($externalTargets.Name -join ', ')  [ICMP x$IcmpCountPerTarget, timeout ${IcmpTimeoutSeconds}s]"
Write-Host "  Admin context  : $(if ($script:IsAdmin) { 'elevated (strict multi-NIC pinning, full event log access)' } else { 'non-admin (multi-NIC ext probes are loose)' })" -ForegroundColor Gray
$dnsPlanStr = if ($SkipDnsProbe) { "off" } else { "$DnsProbeName (${DnsTimeoutMs}ms cap)" }
Write-Host "  DNS probe      : $dnsPlanStr"
$tcpPlanStr = if ($doTcpProbe) { "$($tcpHostA):443, $($tcpHostB):443" } else { "off" }
Write-Host "  TCP probes     : $tcpPlanStr"
Write-Host "  Config audit   : $(if ($SkipConfigAudit) { 'off' } else { "on (startup codes: $(if ($configAuditStartupCodes.Count) { $configAuditStartupCodes -join ',' } else { 'NONE' }))" })" -ForegroundColor Gray
Write-Host "  Cable/NIC hints: $(if ($SkipCableHints) { 'off' } else { "on (baseline $($baselineEthMbps) Mbps)" })" -ForegroundColor Gray
Write-Host "  Multi-NIC x-check: $(if ($SkipMultiNicCrossCheck) { 'off' } elseif ($multiNicRoster.Count -lt 1) { 'off (no eligible alt adapters)' } else { "on (roster=$($multiNicRoster.Count))" })" -ForegroundColor Gray
Write-Host "  Wi-Fi signal   : $(if ($SkipWifiSignal) { 'off' } else { 'on (per-cycle netsh snapshot when Wi-Fi adapter is present)' })" -ForegroundColor Gray
if (-not $SkipWifiSignal) { Write-Host "  Wi-Fi cache    : refresh every >=$script:NetworkDiagWifiSnapshotMinSeconds s (state cache between cycles)" -ForegroundColor Gray }
Write-Host "  Disk budget    : projected CSV ~$([math]::Round($projectedCsvBytes / 1MB, 2)) MB, detail ~$([math]::Round($projectedDetailBytes / 1MB, 2)) MB, free ~$([math]::Round($diskFreeBytes / 1GB, 2)) GB" -ForegroundColor Gray
Write-Host "  TLS probe      : $(if ($EnableTlsProbe) { 'on (SslStream handshake after each TCP/443 connect)' } else { 'off (add -EnableTlsProbe to enable)' })" -ForegroundColor Gray
Write-Host "  UDP probe      : $(if ($EnableUdpProbe) { "on (target=$($udpHostPort.Host):$($udpHostPort.Port), $UdpProbeRateHz Hz, $UdpProbePayloadBytes B)" } else { 'off (add -EnableUdpProbe to enable)' })" -ForegroundColor Gray
Write-Host "  Long-lived TCP : $(if ($EnableLongLivedTcp) { "on (target=$($tcpSessHostPort.Host):$($tcpSessHostPort.Port), backoff=${LongLivedTcpReconnectBackoffSeconds}s)" } else { 'off (add -EnableLongLivedTcp to enable)' })" -ForegroundColor Gray
Write-Host "  Per-probe TS   : $(if ($PerProbeTimestamps) { 'on (CSV adds <Probe>_t_ms columns)' } else { 'off' })" -ForegroundColor Gray
Write-Host "  Auto-capture   : $(if ($AutoCaptureOnFault) { "on (method=$AutoCaptureMethod, ${AutoCaptureSeconds}s, max=$AutoCaptureMax, supported=$autoCaptureSupported, admin=$($script:IsAdmin))" } else { 'off' })" -ForegroundColor Gray
Write-Host "  JSON summary   : $(if ($SkipJsonSummary) { 'off' } else { 'on (network_summary_<ts>.json at run end)' })" -ForegroundColor Gray
Write-Host "  ISP evidence   : $(if ($SkipIspEvidencePacket) { 'off' } else { "on (folder written at run end$(if ($IspEvidenceZip) { ', zipped' }))" })" -ForegroundColor Gray
Write-Host "  Self-test mode : $(if ($SelfTest) { 'on (preflight only, no cycle loop)' } else { 'off' })" -ForegroundColor Gray
Write-Host "  CSV log        : $csvPath"
Write-Host "  Report         : $reportPath"
if ($DetailLog) { Write-Host "  Detail log     : $detailPath" -ForegroundColor Gray }
Write-Host "`nPress Ctrl+C to stop early. A report will still be generated.`n" -ForegroundColor DarkGray

$runWindowIncident = "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff")  RUN_WINDOW_MONOTONIC durationSec=$([math]::Round($runDurationSeconds, 2)) wallEndApprox=$($endTime.ToString('yyyy-MM-dd HH:mm:ss')) mode=$resolvedMonitoringMode"
Add-NetworkDiagIncident -Stats $stats -Line $runWindowIncident
if (-not $diskBudgetOk) {
    $diskWarnTs = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    Add-NetworkDiagIncident -Stats $stats -Line "$diskWarnTs  DISK_BUDGET_TIGHT projectedBytes=$projectedTotalBytes freeBytes=$diskFreeBytes"
}

if ($SelfTest) {
    $selfChecks = [System.Collections.Generic.List[hashtable]]::new()
    $addCheck = {
        param([string]$name, [bool]$ok, [string]$details)
        [void]$selfChecks.Add(@{ Name = $name; Ok = $ok; Details = $details })
    }
    & $addCheck "OutputFolderWritable" $true "resolved=$OutputFolder source=$outputResolutionLabel"
    & $addCheck "AdminDetection" $true ("isAdmin=" + [string][bool]$script:IsAdmin)
    & $addCheck "DefaultRouteResolved" ([bool]$startupRouting.Ok) ("gateway=" + [string]$gateway + ";ifIndex=" + [string]$routeIfIndex)
    $resolvableTargets = @($externalTargets | Where-Object { $_.ResolvedProbeIp })
    & $addCheck "ExternalTargetsResolvable" ($resolvableTargets.Count -ge 1) ("resolved=" + [string]$resolvableTargets.Count + "/" + [string]$externalTargets.Count)
    $pingOk = $false; $tcpOk = $false; $sslOk = $false
    try { $p = New-Object System.Net.NetworkInformation.Ping; if ($p) { $pingOk = $true; $p.Dispose() } } catch { }
    try { $t = New-Object System.Net.Sockets.TcpClient; if ($t) { $tcpOk = $true; $t.Dispose() } } catch { }
    try { $sslType = [type]'System.Net.Security.SslStream'; if ($sslType) { $sslOk = $true } } catch { }
    & $addCheck "ProbePrimitives" ($pingOk -and $tcpOk -and $sslOk) ("Ping=$pingOk;TcpClient=$tcpOk;SslStreamType=$sslOk")
    $netshCmd = Get-Command -Name "netsh" -ErrorAction SilentlyContinue
    $netshDetail = if ($netshCmd) { [string]$netshCmd.Source } else { "not found" }
    & $addCheck "NetshAvailable" ($null -ne $netshCmd) $netshDetail
    $eventLogReadable = $false
    try {
        $tmpSys = Get-WinEvent -ListLog "System" -ErrorAction SilentlyContinue
        if ($tmpSys) { $eventLogReadable = $true }
    } catch {
        Write-Host "Self-test warning: Could not probe System event log metadata: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    $evDetail = if ($eventLogReadable) { "ok" } else { "access denied or unavailable" }
    & $addCheck "SystemEventLogReadable" $eventLogReadable $evDetail
    $recentQueryOk = $false
    try {
        $lookbackForSelfTest = [math]::Max(1, $(if ($effectiveEventLogLookbackMinutes -gt 0) { $effectiveEventLogLookbackMinutes } else { 15 }))
        [void](Get-WinEvent -FilterHashtable @{ LogName = "System"; StartTime = (Get-Date).AddMinutes(-1 * $lookbackForSelfTest) } -MaxEvents 1 -ErrorAction SilentlyContinue)
        $recentQueryOk = $true
    } catch {
        Write-Host "Self-test warning: Recent event query failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    & $addCheck "EventLogRecentQueryOk" $recentQueryOk ("lookbackMinutes=" + [string]$(if ($effectiveEventLogLookbackMinutes -gt 0) { $effectiveEventLogLookbackMinutes } else { 15 }))
    $diskProjectionMb = [math]::Round($projectedTotalBytes / 1MB, 2)
    $diskFreeGb = [math]::Round($diskFreeBytes / 1GB, 2)
    & $addCheck "DiskBudgetOk" $diskBudgetOk ("projectedMb=$diskProjectionMb;freeGb=$diskFreeGb")

    $allOk = (@($selfChecks | Where-Object { -not $_.Ok }).Count -eq 0)
    $selfTestTxtPath = Join-Path $OutputFolder "network_selftest_$timestamp.txt"
    $selfTestJsonPath = Join-Path $OutputFolder "network_selftest_$timestamp.json"
    $txtLines = [System.Collections.Generic.List[string]]::new()
    [void]$txtLines.Add("NETWORK DIAGNOSTIC SELF-TEST")
    [void]$txtLines.Add("Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$txtLines.Add("SchemaVersion: $script:NetworkDiagSchemaVersion")
    [void]$txtLines.Add("Overall: $(if ($allOk) { 'PASS' } else { 'FAIL' })")
    [void]$txtLines.Add("")
    foreach ($chk in $selfChecks) {
        [void]$txtLines.Add("[$(if ($chk.Ok) { 'PASS' } else { 'FAIL' })] $($chk.Name): $($chk.Details)")
    }
    $encSelf = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($selfTestTxtPath, ($txtLines -join [Environment]::NewLine), $encSelf)
    $selfObj = [ordered]@{
        schemaVersion = [string]$script:NetworkDiagSchemaVersion
        time = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK")
        overall = if ($allOk) { "PASS" } else { "FAIL" }
        checks = @($selfChecks)
    }
    [System.IO.File]::WriteAllText($selfTestJsonPath, ($selfObj | ConvertTo-Json -Depth 6), $encSelf)
    Write-Host "Self-test: $(if ($allOk) { 'PASS' } else { 'FAIL' })" -ForegroundColor $(if ($allOk) { 'Green' } else { 'Yellow' })
    Write-Host "Self-test report: $selfTestTxtPath" -ForegroundColor Gray
    Write-Host "Self-test JSON  : $selfTestJsonPath" -ForegroundColor Gray
    exit $(if ($allOk) { 20 } else { 21 })
}

# ── Startup ipconfig + public IP (best-effort, bounded) ──────────────────
$publicIpStart = ""
try {
    $ipStart = Start-NetworkDiagBoundedExternalProcess -FilePath "ipconfig" -ArgumentList @("/all") -TimeoutSeconds 10
    if ($ipStart.Ok) {
        $enc0 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($ipconfigStartPath, $ipStart.StdOut, $enc0)
    }
} catch {
    Write-Host "WARNING: ipconfig startup snapshot failed: $($_.Exception.Message)" -ForegroundColor Yellow
}
if (-not $SkipIspEvidencePacket) {
    $publicIpStart = Get-NetworkDiagPublicIp -TimeoutSeconds 5
}

# ── Writers ──────────────────────────────────────────────────────────────
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
$csvWriter = $null
$detailWriter = $null
$detailLogRequested = [bool]$DetailLog
$detailLogActive = $false
$detailLogDisabledReason = ""

$header = $csvColumnManifest -join ","
try {
    $csvWriter = New-Object System.IO.StreamWriter($csvPath, $false, $utf8NoBom)
    $csvWriter.AutoFlush = $true
    $csvWriter.WriteLine($header)
    $csvWriter.Flush()
} catch {
    $msg = $_.Exception.Message
    Write-Host "ERROR: Could not open CSV log for writing: $msg" -ForegroundColor Red
    $null = Write-NetworkDiagAbortFile -Reason "CsvWriterOpenFailed" -Details "Path: $csvPath`n$msg" -OutputRoots $abortRoots
    exit 4
}

if ($detailLogRequested) {
    try {
        $detailWriter = New-Object System.IO.StreamWriter($detailPath, $false, $utf8NoBom)
        $detailWriter.AutoFlush = $true
        $detailWriter.WriteLine("Layered diagnostic detail log started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        $detailWriter.Flush()
        $detailLogActive = $true
    } catch {
        $detailLogDisabledReason = $_.Exception.Message
        Write-Host "WARNING: Detail log disabled (could not open detail writer): $detailLogDisabledReason" -ForegroundColor Yellow
        if ($null -ne $detailWriter) {
            try { $detailWriter.Dispose() } catch { }
            $detailWriter = $null
        }
    }
}

# ── Background continuous probes (UDP / long-lived TCP) ──────────────────
$udpProbeHandle = $null
$tcpSessionHandle = $null
if ($EnableUdpProbe -and (Get-Command -Name "Start-NetworkDiagUdpProbe" -ErrorAction SilentlyContinue)) {
    try {
        $udpProbeHandle = Start-NetworkDiagUdpProbe -TargetHost $udpHostPort.Host -TargetPort $udpHostPort.Port -RateHz $UdpProbeRateHz -PayloadBytes $UdpProbePayloadBytes
        $stats.UdpProbeEnabled = $true
        $stats.UdpProbeTarget = "$($udpHostPort.Host):$($udpHostPort.Port)"
        $stats.UdpProbeRateHz = [int]$UdpProbeRateHz
        Write-Host "  UDP probe started: $($udpHostPort.Host):$($udpHostPort.Port) at $UdpProbeRateHz Hz, $UdpProbePayloadBytes B" -ForegroundColor Gray
    } catch {
        Write-Host "WARNING: -EnableUdpProbe failed to start: $($_.Exception.Message)" -ForegroundColor Yellow
        $udpProbeHandle = $null
    }
}
if ($EnableLongLivedTcp -and (Get-Command -Name "Start-NetworkDiagTcpSessionProbe" -ErrorAction SilentlyContinue)) {
    try {
        $tcpSessionHandle = Start-NetworkDiagTcpSessionProbe -TargetHost $tcpSessHostPort.Host -TargetPort $tcpSessHostPort.Port -ReconnectBackoffSeconds $LongLivedTcpReconnectBackoffSeconds
        $stats.TcpSessionEnabled = $true
        $stats.TcpSessionTarget = "$($tcpSessHostPort.Host):$($tcpSessHostPort.Port)"
        Write-Host "  Long-lived TCP started: $($tcpSessHostPort.Host):$($tcpSessHostPort.Port)" -ForegroundColor Gray
    } catch {
        Write-Host "WARNING: -EnableLongLivedTcp failed to start: $($_.Exception.Message)" -ForegroundColor Yellow
        $tcpSessionHandle = $null
    }
}
if ($AutoCaptureOnFault) {
    $stats.AutoCaptureEnabled = $true
    $stats.AutoCaptureMethod = [string]$AutoCaptureMethod
    $stats.AutoCaptureSeconds = [int]$AutoCaptureSeconds
    $stats.AutoCaptureMax = [int]$AutoCaptureMax
    $stats.AutoCaptureSupported = [bool]$autoCaptureSupported
    if (-not $autoCaptureSupported) {
        Write-Host "WARNING: -AutoCaptureOnFault enabled but '$AutoCaptureMethod' is not available; captures will not start." -ForegroundColor Yellow
    } elseif (-not $script:IsAdmin) {
        Write-Host "NOTE: -AutoCaptureOnFault enabled but the run is non-admin; captures require elevation and will be skipped (one incident per run)." -ForegroundColor Yellow
    } else {
        Write-Host "  Auto-capture armed: $AutoCaptureMethod x ${AutoCaptureSeconds}s, max=$AutoCaptureMax, output=$OutputFolder\captures\" -ForegroundColor Gray
    }
}

function Open-NetworkDiagAppendWriter {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][System.Text.UTF8Encoding]$Encoding
    )
    $w = New-Object System.IO.StreamWriter($Path, $true, $Encoding)
    $w.AutoFlush = $true
    return $w
}

function Invoke-NetworkDiagWriteLineResilient {
    param(
        [Parameter(Mandatory = $true)][ref]$WriterRef,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Line,
        [Parameter(Mandatory = $true)][System.Text.UTF8Encoding]$Encoding,
        [Parameter(Mandatory = $true)][hashtable]$Stats,
        [bool]$IsDetail = $false
    )

    $attemptReopen = $false
    if ($null -eq $WriterRef.Value) {
        $attemptReopen = $true
    } else {
        try {
            $WriterRef.Value.WriteLine($Line)
            return $true
        } catch {
            try { $WriterRef.Value.Dispose() } catch { }
            $WriterRef.Value = $null
            $attemptReopen = $true
        }
    }

    if (-not $attemptReopen) { return $false }
    $Stats.WriterReopenEvents = [int]$Stats.WriterReopenEvents + 1
    if ($IsDetail) {
        $Stats.DetailLogReopenEvents = [int]$Stats.DetailLogReopenEvents + 1
    }
    Start-Sleep -Milliseconds 250
    try {
        $WriterRef.Value = Open-NetworkDiagAppendWriter -Path $Path -Encoding $Encoding
        $WriterRef.Value.WriteLine($Line)
        return $true
    } catch {
        $Stats.WriterReopenFailures = [int]$Stats.WriterReopenFailures + 1
        try { if ($null -ne $WriterRef.Value) { $WriterRef.Value.Dispose() } } catch { }
        $WriterRef.Value = $null
        return $false
    }
}

function New-NetworkDiagReportCfgCore {
    param(
        [string]$ReportPathValue,
        [string]$IspBundlePathValue,
        [bool]$PartialRunValue
    )
    $adapterSummaryForReport = if ($boundAdapter) {
        "$($boundAdapter.Name) ifIndex=$routeIfIndex MediaType=$($boundAdapter.MediaType) RoutedEthernetClass=$(if ($isEthernetBound) { 'yes' } else { 'no' })"
    } else {
        "(adapter not resolved; NIC counters may be blank)"
    }
    return @{
        Gateway               = $gateway
        AdapterSummary        = $adapterSummaryForReport
        BaselineEthMbps       = $baselineEthMbps
        DurationMinutes       = $DurationMinutes
        IntervalSeconds       = $IntervalSeconds
        DoTcp                 = $doTcpProbe
        DetailRequested       = $detailLogRequested
        DetailActive          = $detailLogActive
        DetailDisabledReason  = $detailLogDisabledReason
        CsvPath               = $csvPath
        ReportPath            = $ReportPathValue
        DetailPath            = $detailPath
        OutputFolder          = $OutputFolder
        OutputResolutionLabel = $outputResolutionLabel
        ExternalTargets       = $externalTargets
        MaxIncidents          = $script:MaxIncidentsInMemory
        RoutingContext        = $routingContext
        TunnelReason          = [string]$tunnelClass.TunnelReason
        TunnelDetail          = [string]$tunnelClass.TunnelDetail
        UnderlayAvailable     = $underlayAvailable
        UnderlayAdapter       = $(if ($underlayAdapterName) { $underlayAdapterName } else { "" })
        UnderlayGw            = $(if ($underlayGateway) { $underlayGateway } else { "" })
        UnderlayReason        = $underlayReasonCode
        UnderlayMayBeVirtual  = $underlayMayBeVirtual
        UnderlayMetric        = $underlayMetric
        PrimaryAdapter        = $primaryAdapterDisp
        LegacyCsvShape        = [bool]$LegacyCsvShape
        ExternalCount         = $nExternal
        TcpHostA              = $tcpHostA
        TcpHostB              = $tcpHostB
        DnsProbeName          = $DnsProbeName
        DnsTimeoutMs          = $DnsTimeoutMs
        SkipDnsProbe          = [bool]$SkipDnsProbe
        BurstOnFault          = [bool]$BurstOnFault
        BurstIntervalSeconds  = $BurstIntervalSeconds
        BurstCycles           = $BurstCycles
        MaxBurstSeconds       = $MaxBurstSeconds
        IcmpCountPerTarget    = $IcmpCountPerTarget
        IcmpTimeoutSeconds    = $IcmpTimeoutSeconds
        GwIcmpPolicyConfirmCycles  = $GwIcmpPolicyConfirmCycles
        SkipGwIcmpPolicyAdaptation = [bool]$SkipGwIcmpPolicyAdaptation
        RoutingRefreshIntervalCycles = $RoutingRefreshIntervalCycles
        ProbeAddressFamily    = $ProbeAddressFamily
        IsAdmin               = [bool]$script:IsAdmin
        SkipConfigAudit       = [bool]$SkipConfigAudit
        SkipCableHints        = [bool]$SkipCableHints
        SkipMultiNicCrossCheck = [bool]$SkipMultiNicCrossCheck
        SkipIspEvidencePacket = [bool]$SkipIspEvidencePacket
        IspEvidenceZip        = [bool]$IspEvidenceZip
        PathMtuProbeTarget    = $PathMtuProbeTarget
        ConfigAuditStartupCodes = $configAuditStartupCodes
        MultiNicRosterCount   = $multiNicRoster.Count
        IspEvidenceBundlePath = $IspBundlePathValue
        SkipWifiSignal        = [bool]$SkipWifiSignal
        EnableTlsProbe        = [bool]$EnableTlsProbe
        SkipJsonSummary       = [bool]$SkipJsonSummary
        SchemaVersion         = [string]$script:NetworkDiagSchemaVersion
        EpisodeRecoveryConfirmCycles = [int]$script:NetworkDiagEpisodeRecoveryConfirmCycles
        MonitoringMode        = [string]$resolvedMonitoringMode
        HeartbeatMinutes      = [int]$effectiveHeartbeatMinutes
        SnapshotMinutes       = [int]$effectiveSnapshotMinutes
        EventLogLookbackMinutes = [int]$effectiveEventLogLookbackMinutes
        RunStartTime          = $runStartTime.ToString("yyyy-MM-ddTHH:mm:ssK")
        RunEndTime            = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
        ProjectedCsvBytes     = [int64]$projectedCsvBytes
        ProjectedDetailBytes  = [int64]$projectedDetailBytes
        ProjectedTotalBytes   = [int64]$projectedTotalBytes
        DiskFreeBytesAtStart  = [int64]$diskFreeBytes
        DiskBudgetOk          = [bool]$diskBudgetOk
        PartialRun            = [bool]$PartialRunValue
        EnableUdpProbe        = [bool]$EnableUdpProbe
        UdpProbeTarget        = if ($udpHostPort) { "$($udpHostPort.Host):$($udpHostPort.Port)" } else { "" }
        UdpProbeRateHz        = [int]$UdpProbeRateHz
        UdpProbePayloadBytes  = [int]$UdpProbePayloadBytes
        EnableLongLivedTcp    = [bool]$EnableLongLivedTcp
        TcpSessionTarget      = if ($tcpSessHostPort) { "$($tcpSessHostPort.Host):$($tcpSessHostPort.Port)" } else { "" }
        EnableAutoCapture     = [bool]$AutoCaptureOnFault
        AutoCaptureMethod     = [string]$AutoCaptureMethod
        AutoCaptureSeconds    = [int]$AutoCaptureSeconds
        AutoCaptureMax        = [int]$AutoCaptureMax
        AutoCaptureSupported  = [bool]$autoCaptureSupported
        PerProbeTimestamps    = [bool]$PerProbeTimestamps
    }
}

$partialSummaryPath = Join-Path $OutputFolder "network_summary_$timestamp.partial.json"
$partialReportPath = Join-Path $OutputFolder "network_report_$timestamp.partial.txt"
$nextHeartbeatAtSec = if ($effectiveHeartbeatMinutes -gt 0) { [double]$effectiveHeartbeatMinutes * 60.0 } else { -1.0 }
$nextSnapshotAtSec = if ($effectiveSnapshotMinutes -gt 0) { [double]$effectiveSnapshotMinutes * 60.0 } else { -1.0 }

# ── Main loop + teardown + report ────────────────────────────────────────
$script:NetworkDiagEarlyStop = $false
$onConsoleCancel = $null
$networkDiagCancelHandlerRegistered = $false
$reportWritten = $false

if ($routingContext -eq "VpnTunnelDefault" -and -not $underlayAvailable -and $underlayReasonCode) {
    $t0 = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    Add-NetworkDiagIncident -Stats $stats -Line "$t0  VPN_CONTEXT - Underlay not available ($underlayReasonCode). Cycles classified as ANOMALY with VPN_TUNNEL_ONLY will not repeat per-row in this incident log."
}

try {
    try {
        $onConsoleCancel = [ConsoleCancelEventHandler]{
            param([object]$sender, [System.ConsoleCancelEventArgs]$e)
            $e.Cancel = $true
            $script:NetworkDiagEarlyStop = $true
        }
        [Console]::add_CancelKeyPress($onConsoleCancel) | Out-Null
        $networkDiagCancelHandlerRegistered = $true
    } catch { }

    try {
        $cycleState = New-NetworkDiagCycleState -ExternalCount $nExternal

        $burstActive = $false
        $burstTicksLeft = 0
        $burstSessionStartTicks = $null

        while ($runClock.Elapsed.TotalSeconds -lt $runDurationSeconds -and -not $script:NetworkDiagEarlyStop) {
            $stats.CyclesAttempted++
            $Nrefresh = $RoutingRefreshIntervalCycles
            $kAttempt = $stats.CyclesAttempted
            if ($Nrefresh -gt 0 -and $kAttempt -gt $Nrefresh -and (($kAttempt - 1) % $Nrefresh) -eq 0) {
                $oldIdent = Get-NetworkDiagRoutingIdentityHashtable -Gateway $gateway -RouteIfIndex $routeIfIndex -RoutingContext $routingContext -UnderlayIfIndex $underlayIfIndex -RoutedAdapterName $(if ($boundAdapter) { [string]$boundAdapter.Name } else { "" }) -ProbeAddressFamily $ProbeAddressFamily
                $refRes = Invoke-NetworkDiagRoutingResolution -Mode Refresh -RequireEthernetSwitch:$RequireEthernet -AbortRoots $abortRoots
                $rrTs = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
                if (-not $refRes.Ok) {
                    Add-NetworkDiagIncident -Stats $stats -Line "$rrTs  ROUTE_REFRESH_FAILED reason=no_gateway_after_refresh keeping_prior_snapshot"
                    if ($detailLogActive) {
                        [void](Invoke-NetworkDiagWriteLineResilient -WriterRef ([ref]$detailWriter) -Path $detailPath -Line "$rrTs  ROUTE_REFRESH_FAILED reason=no_gateway_after_refresh keeping_prior_snapshot" -Encoding $utf8NoBom -Stats $stats -IsDetail:$true)
                    }
                } else {
                    $newIdent = Get-NetworkDiagRoutingIdentityHashtable -Gateway $refRes.Gateway -RouteIfIndex $refRes.RouteIfIndex -RoutingContext $refRes.RoutingContext -UnderlayIfIndex $refRes.UnderlayIfIndex -RoutedAdapterName $(if ($refRes.BoundAdapter) { [string]$refRes.BoundAdapter.Name } else { "" }) -ProbeAddressFamily $ProbeAddressFamily
                    $idChanged = Test-NetworkDiagRoutingIdentityChanged -A $oldIdent -B $newIdent
                    $baselinesReset = $false
                    if ($idChanged) {
                        $cycleState.PrevGwGood = $null
                        $cycleState.NormalGwPolicyState = "Inactive"
                        $cycleState.NormalGwPolicyStreak = 0
                        $cycleState.NormalGwPolicyArmedAt = $null
                        $cycleState.ConfigAuditCache = $null
                        $baselinesReset = ($oldIdent.routeIfIndex -ne $newIdent.routeIfIndex) -or ($oldIdent.underlayIfIndex -ne $newIdent.underlayIfIndex)
                        if ($baselinesReset) {
                            $cycleState.NicCounterSeeded = $false
                            $cycleState.UlNicSeeded = $false
                            $cycleState.CableConsecutiveDegradeCycles = 0
                            $cycleState.LastLinkFlapCheckUtc = $null
                            if (-not $SkipCableHints -and $refRes.BoundAdapter) {
                                $cableBaseline = Get-NetworkDiagCableBaseline -Adapter $refRes.BoundAdapter
                            }
                            if (-not $SkipMultiNicCrossCheck) {
                                $multiNicRoster = @(Get-NetworkDiagCrossCheckRoster -ProbeAddressFamily $ProbeAddressFamily -PrimaryRouteIfIndex $refRes.RouteIfIndex)
                            }
                        }
                    }
                    $gateway = $refRes.Gateway
                    $routeIfIndex = $refRes.RouteIfIndex
                    $defaultRoute = $refRes.DefaultRoute
                    $defaultRouteSelectionReason = $refRes.DefaultRouteSelectionReason
                    $boundAdapter = $refRes.BoundAdapter
                    $tunnelClass = $refRes.TunnelClass
                    $routingContext = $refRes.RoutingContext
                    $underlayState = $refRes.UnderlayState
                    $underlayIfIndex = $refRes.UnderlayIfIndex
                    $underlayGateway = $refRes.UnderlayGateway
                    $underlayAdapterName = $refRes.UnderlayAdapterName
                    $underlayAvailable = $refRes.UnderlayAvailable
                    $underlayIsEthernet = $refRes.UnderlayIsEthernet
                    $underlayReasonCode = $refRes.UnderlayReasonCode
                    $underlayMayBeVirtual = $refRes.UnderlayMayBeVirtual
                    $underlayMetric = $refRes.UnderlayMetric
                    $primaryAdapterDisp = $refRes.PrimaryAdapterDisp
                    $isEthernetBound = $refRes.IsEthernetBound
                    $requireEthernetSatisfied = $refRes.RequireEthernetSatisfied
                    $ethViolMsg = ""
                    if ($refRes.RefreshRequireEthernetViolation) {
                        $ethViolMsg = "RequireEthernet_not_met_after_refresh"
                        Write-Host "  WARNING: After ROUTE_REFRESH, -RequireEthernet is not satisfied; continuing (refresh mode does not exit)." -ForegroundColor Yellow
                    }
                    $newIdentForLine = @{
                        gateway = [string]$newIdent.gateway; routeIfIndex = [string]$newIdent.routeIfIndex
                        routedAdapter = [string]$newIdent.routedAdapter; routingContext = [string]$newIdent.routingContext
                        underlayIfIndex = [string]$newIdent.underlayIfIndex
                    }
                    $oldIdentForLine = @{
                        gateway = [string]$oldIdent.gateway; routeIfIndex = [string]$oldIdent.routeIfIndex
                        routedAdapter = [string]$oldIdent.routedAdapter; routingContext = [string]$oldIdent.routingContext
                        underlayIfIndex = [string]$oldIdent.underlayIfIndex
                    }
                    $rrLine = Format-NetworkDiagRouteRefreshIncidentLine -Timestamp $rrTs -OldSnap $oldIdentForLine -NewSnap $newIdentForLine -BaselinesReset $baselinesReset -RequireEthernetViolation $ethViolMsg
                    Add-NetworkDiagIncident -Stats $stats -Line $rrLine
                    if ($detailLogActive) { [void](Invoke-NetworkDiagWriteLineResilient -WriterRef ([ref]$detailWriter) -Path $detailPath -Line $rrLine -Encoding $utf8NoBom -Stats $stats -IsDetail:$true) }
                    if (-not $SkipConfigAudit) {
                        $tmpCfgR = @{ ProbeAddressFamily = $ProbeAddressFamily; PathMtuProbeTarget = $PathMtuProbeTarget }
                        $tmpSnapR = @{ RouteIfIndex = $routeIfIndex; Gateway = $gateway; BoundAdapter = $boundAdapter }
                        $refreshAudit = Invoke-NetworkDiagConfigAudit -Cfg $tmpCfgR -Snap $tmpSnapR -RunStart $runStartTime -Cached $null -LookbackMinutes $effectiveEventLogLookbackMinutes
                        if ($refreshAudit -and @($refreshAudit.FindingCodes).Count -gt 0) {
                            Add-NetworkDiagIncident -Stats $stats -Line "$rrTs  CONFIG_AUDIT_REFRESH codes=$(($refreshAudit.FindingCodes) -join ',')"
                            $cycleState.ConfigAuditCache = $refreshAudit
                        }
                    }
                }
            }

            $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
            $cycleSw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $cycleSnap = @{
                    Gateway            = $gateway
                    RouteIfIndex       = $routeIfIndex
                    UnderlayAvailable  = $underlayAvailable
                    UnderlayIfIndex    = $underlayIfIndex
                    UnderlayGateway    = $underlayGateway
                    UnderlayAdapterName = $underlayAdapterName
                    RoutingContext     = $routingContext
                    PrimaryAdapterDisp = $primaryAdapterDisp
                    BoundAdapter       = $boundAdapter
                }
                $cycleCfg = @{
                    NExternal                 = $nExternal
                    ExternalTargets           = $externalTargets
                    IcmpCountPerTarget        = $IcmpCountPerTarget
                    IcmpTimeoutSeconds        = $IcmpTimeoutSeconds
                    DoTcpProbe                = $doTcpProbe
                    TcpHostA                  = $tcpHostA
                    TcpHostB                  = $tcpHostB
                    SkipDnsProbe              = [bool]$SkipDnsProbe
                    DnsProbeName              = $DnsProbeName
                    DnsTimeoutMs              = $DnsTimeoutMs
                    LegacyCsvShape            = [bool]$LegacyCsvShape
                    SkipGwIcmpPolicy          = [bool]$SkipGwIcmpPolicyAdaptation
                    GwIcmpPolicyConfirmCycles = $GwIcmpPolicyConfirmCycles
                    ProbeAddressFamily        = $ProbeAddressFamily
                    LoopbackProbe             = $script:NetworkDiagLoopbackProbe
                    SkipConfigAudit           = [bool]$SkipConfigAudit
                    SkipCableHints            = [bool]$SkipCableHints
                    SkipMultiNicCrossCheck    = [bool]$SkipMultiNicCrossCheck
                    PathMtuProbeTarget        = $PathMtuProbeTarget
                    RunStartTime              = $runStartTime
                    CableBaseline             = $cableBaseline
                    MultiNicRoster            = $multiNicRoster
                    IsAdmin                   = [bool]$script:IsAdmin
                    SkipWifiSignal            = [bool]$SkipWifiSignal
                    EnableTlsProbe            = [bool]$EnableTlsProbe
                    SchemaVersion             = [string]$script:NetworkDiagSchemaVersion
                    EpisodeRecoveryConfirmCycles = [int]$script:NetworkDiagEpisodeRecoveryConfirmCycles
                    WifiSnapshotMinSeconds    = [int]$script:NetworkDiagWifiSnapshotMinSeconds
                    EventLogLookbackMinutes   = [int]$effectiveEventLogLookbackMinutes
                    EnableUdpProbe            = [bool]$EnableUdpProbe
                    UdpProbeHandle            = $udpProbeHandle
                    EnableLongLivedTcp        = [bool]$EnableLongLivedTcp
                    TcpSessionHandle          = $tcpSessionHandle
                    PerProbeTimestamps        = [bool]$PerProbeTimestamps
                    EnableAutoCapture         = [bool]$AutoCaptureOnFault
                    AutoCaptureMethod         = [string]$AutoCaptureMethod
                    AutoCaptureSeconds        = [int]$AutoCaptureSeconds
                    AutoCaptureMax            = [int]$AutoCaptureMax
                    AutoCaptureSupported      = [bool]$autoCaptureSupported
                    OutputFolder              = $OutputFolder
                }
                $rec = Invoke-NetworkDiagOneCycle -Cfg $cycleCfg -Snap $cycleSnap -Stats $stats -State $cycleState -Now $now

                $verdictMarker = " -> $($rec.Verdict)"
                $markerIdx = if ($rec.ConsoleLine1) { ([string]$rec.ConsoleLine1).LastIndexOf($verdictMarker) } else { -1 }
                if ($markerIdx -ge 0) {
                    Write-Host $rec.ConsoleLine1.Substring(0, $markerIdx + 4) -NoNewline
                    Write-Host $rec.Verdict -ForegroundColor $rec.Color
                } else {
                    Write-Host $rec.ConsoleLine1 -ForegroundColor $rec.Color
                }
                Write-Host $rec.ConsoleLine2 -ForegroundColor DarkGray

                $csvLine = ConvertTo-NetworkDiagCsvLineFromManifest -ColumnNames $csvColumnManifest -Values $rec.CsvRowValues
                [void](Invoke-NetworkDiagWriteLineResilient -WriterRef ([ref]$csvWriter) -Path $csvPath -Line $csvLine -Encoding $utf8NoBom -Stats $stats -IsDetail:$false)
                if ($detailLogActive) {
                    [void](Invoke-NetworkDiagWriteLineResilient -WriterRef ([ref]$detailWriter) -Path $detailPath -Line $rec.DetailLine -Encoding $utf8NoBom -Stats $stats -IsDetail:$true)
                }

                $elapsedSecNow = $runClock.Elapsed.TotalSeconds
                if ($nextHeartbeatAtSec -gt 0 -and $elapsedSecNow -ge $nextHeartbeatAtSec) {
                    $tsSpan = [TimeSpan]::FromSeconds($elapsedSecNow)
                    $memMb = [math]::Round(([System.Diagnostics.Process]::GetCurrentProcess().PrivateMemorySize64 / 1MB), 1)
                    $hbLine = "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff")  HEARTBEAT cycles=$($stats.CyclesAttempted) committed=$($stats.CyclesCommitted) incidents=$($stats.Incidents.Count) episodes=$($stats.EpisodeCount) memMb=$memMb sinceStart=$($tsSpan.ToString('dd\.hh\:mm\:ss'))"
                    Write-Host $hbLine -ForegroundColor Gray
                    Add-NetworkDiagIncident -Stats $stats -Line $hbLine
                    if ($detailLogActive) {
                        [void](Invoke-NetworkDiagWriteLineResilient -WriterRef ([ref]$detailWriter) -Path $detailPath -Line $hbLine -Encoding $utf8NoBom -Stats $stats -IsDetail:$true)
                    }
                    while ($nextHeartbeatAtSec -gt 0 -and $elapsedSecNow -ge $nextHeartbeatAtSec) {
                        $nextHeartbeatAtSec += ([double]$effectiveHeartbeatMinutes * 60.0)
                    }
                }
                if ($nextSnapshotAtSec -gt 0 -and $elapsedSecNow -ge $nextSnapshotAtSec) {
                    try {
                        $partialCfg = New-NetworkDiagReportCfgCore -ReportPathValue $partialReportPath -IspBundlePathValue "" -PartialRunValue $true
                        $partialText = Build-NetworkDiagReportText -S $stats -R $partialCfg
                        [System.IO.File]::WriteAllText($partialReportPath, $partialText, $utf8NoBom)
                        if (-not $SkipJsonSummary -and (Get-Command -Name "Write-NetworkDiagSummaryJson" -ErrorAction SilentlyContinue)) {
                            [void](Write-NetworkDiagSummaryJson -Stats $stats -ReportCfg $partialCfg -OutputFolder $OutputFolder -Timestamp $timestamp -PartialRun -OutputPath $partialSummaryPath)
                        }
                    } catch {
                        Add-NetworkDiagIncident -Stats $stats -Line "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff")  PARTIAL_SNAPSHOT_FAIL - $($_.Exception.Message)"
                    }
                    while ($nextSnapshotAtSec -gt 0 -and $elapsedSecNow -ge $nextSnapshotAtSec) {
                        $nextSnapshotAtSec += ([double]$effectiveSnapshotMinutes * 60.0)
                    }
                }

                if ($BurstOnFault) {
                    $faultThisCycle = ($rec.Verdict -ne "OK")
                    if ($faultThisCycle) {
                        $burstTicksLeft = $BurstCycles
                        if (-not $burstActive) {
                            $burstActive = $true
                            $burstSessionStartTicks = $runClock.Elapsed.TotalSeconds
                            $burstLogNow = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
                            $burstMsg = "$burstLogNow  BURST_START - interval=${BurstIntervalSeconds}s for up to $BurstCycles cycles (max ${MaxBurstSeconds}s wall per episode)"
                            Add-NetworkDiagIncident -Stats $stats -Line $burstMsg
                            if ($detailLogActive) { [void](Invoke-NetworkDiagWriteLineResilient -WriterRef ([ref]$detailWriter) -Path $detailPath -Line $burstMsg -Encoding $utf8NoBom -Stats $stats -IsDetail:$true) }
                        }
                    } elseif ($burstActive) {
                        if ($burstTicksLeft -gt 0) { $burstTicksLeft-- }
                    }
                    if ($burstActive) {
                        $burstAge = [double]$runClock.Elapsed.TotalSeconds - [double]$burstSessionStartTicks
                        if ($burstTicksLeft -le 0 -or $burstAge -ge $MaxBurstSeconds) {
                            $burstLogEnd = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
                            $burstEndWhy = if ($burstTicksLeft -le 0) { "ticks_exhausted" } else { "max_wall" }
                            $burstEndMsg = "$burstLogEnd  BURST_END - reason=$burstEndWhy ageSec=$([math]::Round($burstAge, 2)) ticksLeft=$burstTicksLeft"
                            Add-NetworkDiagIncident -Stats $stats -Line $burstEndMsg
                            if ($detailLogActive) { [void](Invoke-NetworkDiagWriteLineResilient -WriterRef ([ref]$detailWriter) -Path $detailPath -Line $burstEndMsg -Encoding $utf8NoBom -Stats $stats -IsDetail:$true) }
                            $burstActive = $false
                            $burstSessionStartTicks = $null
                            $burstTicksLeft = 0
                        }
                    }
                }

            } catch {
                Add-NetworkDiagIncident -Stats $stats -Line "$now  CYCLE_LOG_FAIL - $($_.Exception.Message)"
                try { Write-Host "`nCycle logging error: $($_.Exception.Message)" -ForegroundColor Yellow } catch { }
            } finally {
                $cycleElapsedSec = $cycleSw.Elapsed.TotalSeconds
                $effectiveIntervalSec = [double]$IntervalSeconds
                if ($BurstOnFault -and $burstActive) { $effectiveIntervalSec = [double]$BurstIntervalSeconds }
                if ($cycleElapsedSec -gt $effectiveIntervalSec) {
                    $stats.CycleOvershootCount = [int]$stats.CycleOvershootCount + 1
                    if ($cycleElapsedSec -ge ($effectiveIntervalSec * 2.0)) {
                        Add-NetworkDiagIncident -Stats $stats -Line "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff")  CYCLE_OVERSHOOT cycleSec=$([math]::Round($cycleElapsedSec, 3)) intervalSec=$([math]::Round($effectiveIntervalSec, 3))"
                    }
                }
                $sleepRemain = $effectiveIntervalSec - $cycleElapsedSec
                if ($sleepRemain -gt 0) {
                    $sleepDeadlineSec = [double]$runClock.Elapsed.TotalSeconds + [double]$sleepRemain
                    while (-not $script:NetworkDiagEarlyStop) {
                        if ($runClock.Elapsed.TotalSeconds -ge $runDurationSeconds) { break }
                        $remainingSec = [double]$sleepDeadlineSec - [double]$runClock.Elapsed.TotalSeconds
                        if ($remainingSec -le 0) { break }
                        $sleepSliceMs = [int][math]::Min(500, [math]::Max(1, [math]::Ceiling($remainingSec * 1000.0)))
                        Start-Sleep -Milliseconds $sleepSliceMs
                    }
                }
            }
        }
    } catch {
        if (-not $script:NetworkDiagEarlyStop) {
            Write-Host "`n`nTest ended with error: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    } finally {
        if ($null -ne $udpProbeHandle -and (Get-Command -Name "Stop-NetworkDiagUdpProbe" -ErrorAction SilentlyContinue)) {
            try { Stop-NetworkDiagUdpProbe -Handle $udpProbeHandle } catch { }
            $udpProbeHandle = $null
        }
        if ($null -ne $tcpSessionHandle -and (Get-Command -Name "Stop-NetworkDiagTcpSessionProbe" -ErrorAction SilentlyContinue)) {
            try { Stop-NetworkDiagTcpSessionProbe -Handle $tcpSessionHandle } catch { }
            $tcpSessionHandle = $null
        }
        if ($null -ne $cycleState -and $cycleState.AutoCaptureHandle -and (Get-Command -Name "Stop-NetworkDiagAutoCapture" -ErrorAction SilentlyContinue)) {
            try {
                $finalCap = Stop-NetworkDiagAutoCapture -Handle $cycleState.AutoCaptureHandle -WaitMs 12000
                if ($finalCap -and $finalCap.FilePath) {
                    $stats.AutoCaptureLastFile = [string]$finalCap.FilePath
                    if ([string]$finalCap.State -eq "done") { try { [void]$stats.AutoCaptureFiles.Add([string]$finalCap.FilePath) } catch { } }
                    $stats.AutoCaptureLastState = [string]$finalCap.State
                }
            } catch { }
            $cycleState.AutoCaptureHandle = $null
        }
        if ($null -ne $detailWriter) {
            try { $detailWriter.Flush(); $detailWriter.Dispose() } catch { }
            $detailWriter = $null
        }
        if ($null -ne $csvWriter) {
            try { $csvWriter.Flush(); $csvWriter.Dispose() } catch { }
            $csvWriter = $null
        }
        if ($networkDiagCancelHandlerRegistered -and $null -ne $onConsoleCancel) {
            try { [Console]::remove_CancelKeyPress($onConsoleCancel) | Out-Null } catch { }
        }
    }
} finally {
    if (-not $reportWritten) {
        try {
            $reportCfg = New-NetworkDiagReportCfgCore -ReportPathValue $reportPath -IspBundlePathValue "" -PartialRunValue $false

            $enc = New-Object System.Text.UTF8Encoding $false
            $reportText = Build-NetworkDiagReportText -S $stats -R $reportCfg
            [System.IO.File]::WriteAllText($reportPath, $reportText, $enc)

            if (-not $SkipIspEvidencePacket) {
                try {
                    $bundleRes = Write-NetworkDiagIspEvidenceBundle -Stats $stats -Cfg (@{
                        DurationMinutes = $DurationMinutes
                        RunStartTime    = $runStartTime
                        ExternalTargets = $externalTargets
                    }) -Findings @{} -OutputFolder $OutputFolder -ReportPath $reportPath -CsvPath $csvPath -DetailPath $(if ($detailLogActive) { $detailPath } else { "" }) -IpconfigStartPath $ipconfigStartPath -PublicIpStart $publicIpStart -Zip:$IspEvidenceZip
                    if ($bundleRes) {
                        $reportCfg.IspEvidenceBundlePath = [string]$bundleRes.Path
                        $stats.IspEvidenceBundlePath = [string]$bundleRes.Path
                        $reportText = Build-NetworkDiagReportText -S $stats -R $reportCfg
                        [System.IO.File]::WriteAllText($reportPath, $reportText, $enc)
                        if ($bundleRes.Path -and (Test-Path -LiteralPath $bundleRes.Path)) {
                            try { Copy-Item -LiteralPath $reportPath -Destination (Join-Path $bundleRes.Path "02_report.txt") -Force -ErrorAction SilentlyContinue } catch { }
                        }
                    }
                } catch {
                    Write-Host "WARNING: ISP evidence bundle failed: $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
            $reportWritten = $true

            if (-not $SkipJsonSummary -and (Get-Command -Name "Write-NetworkDiagSummaryJson" -ErrorAction SilentlyContinue)) {
                try {
                    $summaryPath = Write-NetworkDiagSummaryJson -Stats $stats -ReportCfg $reportCfg -OutputFolder $OutputFolder -Timestamp $timestamp
                    if ($summaryPath) {
                        Write-Host "JSON summary: $summaryPath" -ForegroundColor Gray
                        if ($stats.IspEvidenceBundlePath -and (Test-Path -LiteralPath $stats.IspEvidenceBundlePath)) {
                            try { Copy-Item -LiteralPath $summaryPath -Destination (Join-Path $stats.IspEvidenceBundlePath "12_summary.json") -Force -ErrorAction SilentlyContinue } catch { }
                        }
                    }
                } catch {
                    Write-Host "WARNING: JSON summary write failed: $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }

            Write-Host "`n$reportText" -ForegroundColor Cyan
            Write-Host "Files saved to: $OutputFolder" -ForegroundColor Green
        } catch {
            $em = $_.Exception.Message
            try { Write-Host "`nReport write failed: $em" -ForegroundColor Yellow } catch { }
            $emBody = @"
EMERGENCY REPORT (normal report build/write failed)
Time: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Exception: $em
CyclesAttempted: $($stats.CyclesAttempted)
CyclesCommitted: $($stats.CyclesCommitted)
Gateway: $gateway
ReportPath attempted: $reportPath
"@
            $emPath = Write-NetworkDiagEmergencyReport -Body $emBody -OutputRoots $abortRoots
            if (-not $emPath) {
                $null = Write-NetworkDiagAbortFile -Reason "ReportAndEmergencyFailed" -Details $emBody -OutputRoots @($env:TEMP)
            } else {
                Write-Host "Emergency report written to: $emPath" -ForegroundColor Yellow
            }
        }
    }
}

if ($script:NetworkDiagEarlyStop) {
    Write-Host "`n`nStopped early." -ForegroundColor Yellow
}
