# lib/cycle.ps1
# Single-cycle orchestrator. The outer loop owns: the route-refresh boundary,
# burst-interval bookkeeping, the CSV/detail writers, and sleep. Everything
# inside one probing attempt lives here.
#
# Invoke-NetworkDiagOneCycle updates the shared $Stats hashtable and $State
# (per-cycle mutable counters like NIC deltas, gateway-ICMP policy FSM,
# previous-good-sample bookkeeping). It returns a "cycle record" the outer
# loop uses to write CSV/detail log and decide about burst/sleep.

function Get-NetworkDiagCycleVerdict {
    <#
    Pure-ish verdict tree extracted from the original cycle. Inputs:
      $Probes : @{ GwOk; ExtOk; ExtOkCount; ExtUnreachable; TcpExtOk; DoTcp; LbMs }
      $Ctx    : @{ RoutingContext; UnderlayAvailable; LanGwMs; LanStatus;
                   LanDeltaSum; GwResult; EthStatus; DeltaSum; DnsOk; SkipDnsProbe;
                   LinkSpeedChanged; SkipGwIcmpPolicy; Now; GwIcmpPolicyConfirmCycles;
                   NaRefreshPresent }
      $State  : @{ NormalGwPolicyState (ref); NormalGwPolicyStreak (ref); NormalGwPolicyArmedAt (ref) }

    Returns the base verdict hashtable:
      @{ Verdict; Color; IncidentLine; VpnPolicyEvidence; NormalPolicyEvidence;
         VpnAdjusted; NormalAdjusted; PolicyActivated; PolicyDeactivated }
    Handles the full three-stage tree: primary tree, VPN adjustment, Normal GW
    ICMP policy state machine.
    #>
    param(
        [hashtable]$Probes,
        [hashtable]$Ctx,
        [hashtable]$State
    )
    $v = [ordered]@{
        Verdict              = $null
        Color                = "Yellow"
        IncidentLine         = $null
        VpnPolicyEvidence    = $null
        NormalPolicyEvidence = $null
        VpnAdjusted          = $false
        NormalAdjusted       = $false
        PolicyActivated      = $false
        PolicyDeactivated    = $false
    }
    $now = [string]$Ctx.Now
    if ($Probes.GwOk -and $Probes.ExtOk) {
        $v.Verdict = "OK"; $v.Color = "Green"; $v.IncidentLine = $null
    } elseif ($Probes.GwOk -and -not $Probes.ExtOk) {
        $v.Verdict = "ISP_FAULT"; $v.Color = "Red"
        $tcpHint = if ($Probes.DoTcp -and $Probes.TcpExtOk) { " (TCP/443 OK - ICMP may be filtered or path selective)" } else { "" }
        $v.IncidentLine = "$now  ISP FAULT - Gateway OK ($($Ctx.GwResult)ms) but $($Probes.ExtUnreachable)/$($Probes.ExtCount) external ICMP fail$tcpHint"
    } elseif (-not $Probes.GwOk -and -not $Probes.ExtOk) {
        $v.Verdict = "LOCAL_FAULT"; $v.Color = "Magenta"
        $linkHint = if ($Ctx.EthStatus -and $Ctx.EthStatus -ne "Up") {
            " Eth=$($Ctx.EthStatus)"
        } elseif ($Ctx.DeltaSum -gt 0) {
            " NIC_deltas RxErr=$($Ctx.DRxErr) RxDisc=$($Ctx.DRxDisc) TxErr=$($Ctx.DTxErr)"
        } else { "" }
        $v.IncidentLine = "$now  LOCAL FAULT - Gateway and external ICMP fail$linkHint"
    } else {
        $v.Verdict = "ANOMALY"; $v.Color = "Yellow"
        $v.IncidentLine = "$now  ANOMALY - Gateway ICMP fail but enough external ICMP OK (policy/routing)"
    }

    if ($Ctx.RoutingContext -eq "VpnTunnelDefault" -and -not $Probes.GwOk -and $Probes.ExtOk) {
        if (-not $Ctx.UnderlayAvailable) {
            $v.Verdict = "ANOMALY"; $v.Color = "Yellow"
            $v.VpnPolicyEvidence = "VPN_TUNNEL_ONLY"
            $v.IncidentLine = $null
        } elseif ($null -ne $Ctx.LanGwMs -and [int]$Ctx.LanGwMs -ge 0) {
            $v.Verdict = "OK"; $v.Color = "Green"
            $v.VpnPolicyEvidence = "VPN_TUNNEL_GW_FAIL_LAN_OK"
            $v.VpnAdjusted = $true
            $v.IncidentLine = $null
        } else {
            if ($Ctx.LanStatus -eq "Up" -and $Ctx.LanDeltaSum -eq 0) {
                $v.Verdict = "ANOMALY"; $v.Color = "Yellow"
                $v.VpnPolicyEvidence = "VPN_SPLIT_OR_ICMP_POLICY"
                $v.IncidentLine = "$now  ANOMALY (VPN) - Underlay LAN gateway ICMP fail; underlay adapter Up with zero underlay NIC deltas (split path or ICMP policy)"
            } else {
                $v.Verdict = "LOCAL_FAULT"; $v.Color = "Magenta"
                $v.VpnPolicyEvidence = "LAN_BAD+NIC_HINT"
                $ulHint = if ($Ctx.LanStatus -ne "Up") { " Lan=$($Ctx.LanStatus)" } else { " Underlay_NIC_deltas RxErr=$($Ctx.LanDRe) RxDisc=$($Ctx.LanDRd) TxErr=$($Ctx.LanDTe)" }
                $v.IncidentLine = "$now  LOCAL FAULT (VPN underlay) - LAN gateway ICMP fail$ulHint"
            }
        }
    }

    if ($Ctx.RoutingContext -eq "Normal" -and -not $Ctx.SkipGwIcmpPolicy) {
        $dnsOkForNormalPolicy = $Ctx.SkipDnsProbe -or $Ctx.DnsOk
        $candidate =
            (-not $Probes.GwOk) -and $Probes.ExtOk -and $Probes.DoTcp -and $Probes.TcpExtOk -and
            $dnsOkForNormalPolicy -and ($Probes.LbMs -ge 0) -and $Ctx.NaRefreshPresent -and
            ($Ctx.EthStatus -eq "Up") -and ($Ctx.DeltaSum -eq 0) -and (-not $Ctx.LinkSpeedChanged)
        switch ($State.NormalGwPolicyState) {
            "Inactive" {
                if ($candidate) {
                    $State.NormalGwPolicyState = "Confirming"
                    $State.NormalGwPolicyStreak = 1
                } else {
                    $State.NormalGwPolicyStreak = 0
                }
            }
            "Confirming" {
                if ($candidate) {
                    $State.NormalGwPolicyStreak = [int]$State.NormalGwPolicyStreak + 1
                    if ($State.NormalGwPolicyStreak -ge $Ctx.GwIcmpPolicyConfirmCycles) {
                        $State.NormalGwPolicyState = "Active"
                        $State.NormalGwPolicyArmedAt = $now
                        $v.PolicyActivated = $true
                        $v.Verdict = "OK"; $v.Color = "Green"; $v.IncidentLine = $null
                        $v.NormalAdjusted = $true
                        $v.NormalPolicyEvidence = "GW_ICMP_POLICY"
                    }
                } else {
                    $State.NormalGwPolicyState = "Inactive"
                    $State.NormalGwPolicyStreak = 0
                }
            }
            "Active" {
                if ($candidate) {
                    $v.Verdict = "OK"; $v.Color = "Green"; $v.IncidentLine = $null
                    $v.NormalAdjusted = $true
                    $v.NormalPolicyEvidence = "GW_ICMP_POLICY"
                } else {
                    $State.NormalGwPolicyState = "Inactive"
                    $State.NormalGwPolicyStreak = 0
                    $v.PolicyDeactivated = $true
                }
            }
        }
    }

    return $v
}

function Invoke-NetworkDiagOneCycle {
    <#
    Performs probes and accounting for a single attempted cycle. Updates the
    shared $Stats hashtable and the $State hashtable (cycle-local bookkeeping
    that must persist across cycles: NIC delta seeds, policy FSM, prev-good).
    Returns a cycle record suitable for CSV/detail writes and for driving
    burst-interval logic in the outer loop.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Cfg,
        [Parameter(Mandatory = $true)][hashtable]$Snap,
        [Parameter(Mandatory = $true)][hashtable]$Stats,
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$Now
    )
    $result = [ordered]@{
        Now                      = $Now
        Verdict                  = $null
        Color                    = $null
        IncidentLine             = $null
        Evidence                 = ""
        CsvRowValues             = @{}
        DetailLine               = ""
        ConsoleLine1             = ""
        ConsoleLine2             = ""
        LinkSpeedChanged         = $false
        VpnAdjusted              = $false
        NormalAdjusted           = $false
        ConfigAuditCodes         = @()
        CableHintCodes           = @()
        MultiNicRoster           = ""
        MultiNicGwResults        = "na"
        MultiNicExtResults       = "na"
        MultiNicExtOutcomeByIf   = @{}
        MultiNicExternalTargets  = ""
        MultiNicCertainty        = "na"
        MultiNicSuspectReason    = "NONE"
        PrimaryLinkSuspect       = $false
        MultiNicAltExtOk         = $false
        EpisodeId                = 0
        EpisodePhase             = "none"
    }

    $gateway = [string]$Snap.Gateway
    $routeIfIndex = $Snap.RouteIfIndex
    $underlayAvailable = [bool]$Snap.UnderlayAvailable
    $underlayIfIndex = $Snap.UnderlayIfIndex
    $underlayGateway = [string]$Snap.UnderlayGateway
    $underlayAdapterName = [string]$Snap.UnderlayAdapterName
    $routingContext = [string]$Snap.RoutingContext
    $primaryAdapterDisp = [string]$Snap.PrimaryAdapterDisp
    $adapterNameForStats = if ($Snap.BoundAdapter) { [string]$Snap.BoundAdapter.Name } else { "" }

    $nExternal = [int]$Cfg.NExternal
    $externalTargets = $Cfg.ExternalTargets
    $icmpCount = [int]$Cfg.IcmpCountPerTarget
    $icmpTimeout = [int]$Cfg.IcmpTimeoutSeconds
    $doTcpProbe = [bool]$Cfg.DoTcpProbe
    $tcpHostA = [string]$Cfg.TcpHostA
    $tcpHostB = [string]$Cfg.TcpHostB
    $skipDns = [bool]$Cfg.SkipDnsProbe
    $dnsName = [string]$Cfg.DnsProbeName
    $dnsTimeoutMs = [int]$Cfg.DnsTimeoutMs
    $legacyCsv = [bool]$Cfg.LegacyCsvShape
    $skipGwIcmpPolicy = [bool]$Cfg.SkipGwIcmpPolicy
    $gwConfirm = [int]$Cfg.GwIcmpPolicyConfirmCycles
    $probeFamily = [string]$Cfg.ProbeAddressFamily
    $schemaVersion = if ($Cfg.SchemaVersion) { [string]$Cfg.SchemaVersion } else { "unknown" }
    $episodeRecoveryConfirmCycles = if ($Cfg.EpisodeRecoveryConfirmCycles) { [int]$Cfg.EpisodeRecoveryConfirmCycles } else { 3 }
    $wifiSnapshotMinSeconds = if ($Cfg.WifiSnapshotMinSeconds) { [int]$Cfg.WifiSnapshotMinSeconds } else { 15 }

    $loopbackProbe = [string]$Cfg.LoopbackProbe

    $linkSpeedChangedThisCycle = $false

    $perProbeTs = [bool]$Cfg.PerProbeTimestamps
    $probeOffsets = @{}
    $probeClock = [System.Diagnostics.Stopwatch]::StartNew()
    function Get-NetworkDiagProbeOffset { [int]$probeClock.Elapsed.TotalMilliseconds }

    $probeOffsets["Loopback"] = Get-NetworkDiagProbeOffset
    $lbProbe = Invoke-IcmpProbe -Address $loopbackProbe -Count $icmpCount -TimeoutSeconds $icmpTimeout
    $lbResult = [int]$lbProbe.MeanMs
    if ($lbResult -lt 0) {
        $Stats.LoopbackFail++
        Add-NetworkDiagIncident -Stats $Stats -Line "$Now  LOOPBACK_FAIL - PC loopback ping failed (TCP/IP stack or heavy load)"
    }

    $ethStatus = ""
    $ethMbpsStr = ""
    $ethMbpsNum = $null
    $naRefresh = $null
    if ($null -ne $routeIfIndex) {
        $naRefresh = Get-NetAdapter -InterfaceIndex $routeIfIndex -ErrorAction SilentlyContinue
        if ($naRefresh) {
            $ethStatus = [string]$naRefresh.Status
            $ethMbpsNum = ConvertTo-LinkMbps $naRefresh.LinkSpeed
            if ($null -ne $ethMbpsNum) { $ethMbpsStr = [string]$ethMbpsNum }
            if ($ethStatus -ne "Up") { $Stats.AdapterNotUpCycles++ }
            if ($null -ne $Stats.LastEthMbps -and $null -ne $ethMbpsNum -and $ethMbpsNum -ne $Stats.LastEthMbps) {
                $Stats.LinkSpeedChangeCycles++
                $linkSpeedChangedThisCycle = $true
            }
            $Stats.LastEthMbps = $ethMbpsNum
        }
    }
    $result.LinkSpeedChanged = $linkSpeedChangedThisCycle

    $routeIdx = if ($null -ne $routeIfIndex) { [int]$routeIfIndex } else { -1 }
    $ct = Get-NicCounterTotals -AdapterName $adapterNameForStats -InterfaceIndex $routeIdx -CachedAdapter $naRefresh
    if (-not $State.NicCounterSeeded) {
        $State.PrevRxErr = $ct.RxErr
        $State.PrevRxDisc = $ct.RxDisc
        $State.PrevTxErr = $ct.TxErr
        $State.NicCounterSeeded = $true
        $dRxErr = 0; $dRxDisc = 0; $dTxErr = 0
    } else {
        $dRxErr = [int64][math]::Max(0, [int64]$ct.RxErr - [int64]$State.PrevRxErr)
        $dRxDisc = [int64][math]::Max(0, [int64]$ct.RxDisc - [int64]$State.PrevRxDisc)
        $dTxErr = [int64][math]::Max(0, [int64]$ct.TxErr - [int64]$State.PrevTxErr)
    }
    $State.PrevRxErr = $ct.RxErr
    $State.PrevRxDisc = $ct.RxDisc
    $State.PrevTxErr = $ct.TxErr
    if ($dRxErr -ne 0 -or $dRxDisc -ne 0 -or $dTxErr -ne 0) { $Stats.CyclesWithNicDeltas++ }
    if ($dRxErr -gt $Stats.MaxRxErrDelta) { $Stats.MaxRxErrDelta = [int]$dRxErr }
    if ($dRxDisc -gt $Stats.MaxRxDiscDelta) { $Stats.MaxRxDiscDelta = [int]$dRxDisc }
    if ($dTxErr -gt $Stats.MaxTxErrDelta) { $Stats.MaxTxErrDelta = [int]$dTxErr }

    $dnsDiag = @{ Ok = $true; Ms = -1 }
    if (-not $skipDns) {
        $probeOffsets["Dns"] = Get-NetworkDiagProbeOffset
        $dnsDiag = Test-DnsResolutionDiag -Name $dnsName -TimeoutMs $dnsTimeoutMs
    }

    $lanStatus = "na"
    $lanMbpsStr = "na"
    $lanMbpsNum = $null
    $lanGwMs = $null
    $lanDRe = 0; $lanDRd = 0; $lanDTe = 0
    $lanIsEthStr = "na"
    $lanNameStr = "na"
    $underlayAdapterCsv = "na"
    $underlayAvailStr = if ($underlayAvailable) { "1" } else { "0" }

    $lanNa = $null
    if ($underlayAvailable -and $null -ne $underlayIfIndex) {
        $lanNa = Get-NetAdapter -InterfaceIndex $underlayIfIndex -ErrorAction SilentlyContinue
        if ($lanNa) {
            $lanNameStr = [string]$lanNa.Name
            $underlayAdapterCsv = $lanNameStr
            $lanStatus = [string]$lanNa.Status
            $lanMbpsNum = ConvertTo-LinkMbps $lanNa.LinkSpeed
            if ($null -ne $lanMbpsNum) { $lanMbpsStr = [string]$lanMbpsNum }
            $lanIsEthStr = if (Test-IsEthernetAdapter $lanNa) { "1" } else { "0" }
        }
        $ulIdx = if ($null -ne $underlayIfIndex) { [int]$underlayIfIndex } else { -1 }
        $ulct = Get-NicCounterTotals -AdapterName $underlayAdapterName -InterfaceIndex $ulIdx -CachedAdapter $lanNa
        if (-not $State.UlNicSeeded) {
            $State.UlPrevRxErr = $ulct.RxErr
            $State.UlPrevRxDisc = $ulct.RxDisc
            $State.UlPrevTxErr = $ulct.TxErr
            $State.UlNicSeeded = $true
        } else {
            $lanDRe = [int][math]::Max(0, [int64]$ulct.RxErr - [int64]$State.UlPrevRxErr)
            $lanDRd = [int][math]::Max(0, [int64]$ulct.RxDisc - [int64]$State.UlPrevRxDisc)
            $lanDTe = [int][math]::Max(0, [int64]$ulct.TxErr - [int64]$State.UlPrevTxErr)
        }
        $State.UlPrevRxErr = $ulct.RxErr
        $State.UlPrevRxDisc = $ulct.RxDisc
        $State.UlPrevTxErr = $ulct.TxErr
        $probeOffsets["LanGw"] = Get-NetworkDiagProbeOffset
        $lanGwProbe = Invoke-IcmpProbe -Address $underlayGateway -Count $icmpCount -TimeoutSeconds $icmpTimeout
        $lanGwMs = [int]$lanGwProbe.MeanMs
    }

    $probeOffsets["Gw"] = Get-NetworkDiagProbeOffset
    $gwProbe = Invoke-IcmpProbe -Address $gateway -Count $icmpCount -TimeoutSeconds $icmpTimeout
    $gwResult = [int]$gwProbe.MeanMs
    $extResults = [int[]]::new($nExternal)
    for ($ei = 0; $ei -lt $nExternal; $ei++) {
        $probeOffsets["Ext$($ei + 1)"] = Get-NetworkDiagProbeOffset
        $p = Invoke-IcmpProbe -Address $externalTargets[$ei].IcmpTarget -Count $icmpCount -TimeoutSeconds $icmpTimeout
        $extResults[$ei] = [int]$p.MeanMs
    }
    $gwOK = $gwResult -ge 0
    $extOKCount = @($extResults | Where-Object { $_ -ge 0 }).Count
    $extOkQuorum = [math]::Max(1, [int][math]::Ceiling([double]$nExternal / 2.0))
    $extOK = $extOKCount -ge $extOkQuorum
    $extUnreachable = $nExternal - $extOKCount

    $tcpCf = @{ Ok = $false; Ms = -1 }
    $tcpGg = @{ Ok = $false; Ms = -1 }
    if ($doTcpProbe) {
        $probeOffsets["TcpCf"] = Get-NetworkDiagProbeOffset
        $tcpCf = Invoke-Tcp443Probe -ComputerName $tcpHostA
        $probeOffsets["TcpGg"] = Get-NetworkDiagProbeOffset
        $tcpGg = Invoke-Tcp443Probe -ComputerName $tcpHostB
    }
    $extTcpOK = ($tcpCf.Ok -or $tcpGg.Ok)
    if ($doTcpProbe) {
        if (-not $extOK -and $extTcpOK) { $Stats.IcmpDownTcpUpCycles++ }
        if ($extOK -and -not $extTcpOK) { $Stats.IcmpUpTcpDownCycles++ }
    }

    $tlsCfMs = "na"; $tlsGgMs = "na"
    $tlsCfOk = $null; $tlsGgOk = $null
    if ($doTcpProbe -and $Cfg.EnableTlsProbe -and (Get-Command -Name "Invoke-Tls443Probe" -ErrorAction SilentlyContinue)) {
        $tlsCf = @{ Ok = $false; Ms = -1 }
        $tlsGg = @{ Ok = $false; Ms = -1 }
        if ($tcpCf.Ok) {
            $probeOffsets["TlsCf"] = Get-NetworkDiagProbeOffset
            try { $tlsCf = Invoke-Tls443Probe -ComputerName $tcpHostA -TimeoutMs ($icmpTimeout * 2 * 1000) } catch { }
        }
        if ($tcpGg.Ok) {
            $probeOffsets["TlsGg"] = Get-NetworkDiagProbeOffset
            try { $tlsGg = Invoke-Tls443Probe -ComputerName $tcpHostB -TimeoutMs ($icmpTimeout * 2 * 1000) } catch { }
        }
        $tlsCfMs = if ($tlsCf.Ok) { [string]$tlsCf.Ms } else { "-1" }
        $tlsGgMs = if ($tlsGg.Ok) { [string]$tlsGg.Ms } else { "-1" }
        $tlsCfOk = $tlsCf.Ok; $tlsGgOk = $tlsGg.Ok
        $Stats.TlsProbeCycles = [int]$Stats.TlsProbeCycles + 1
        if ($tcpCf.Ok -and (-not $tlsCf.Ok)) { $Stats.TlsHandshakeFailCycles = [int]$Stats.TlsHandshakeFailCycles + 1 }
        if ($tcpGg.Ok -and (-not $tlsGg.Ok)) { $Stats.TlsHandshakeFailCycles = [int]$Stats.TlsHandshakeFailCycles + 1 }
        if (($tcpCf.Ok -and (-not $tlsCf.Ok)) -or ($tcpGg.Ok -and (-not $tlsGg.Ok))) {
            $Stats.TcpUpTlsDownCycles = [int]$Stats.TcpUpTlsDownCycles + 1
        }
    }
    $result.TlsCfMs = $tlsCfMs
    $result.TlsGgMs = $tlsGgMs

    $verdictInput = @{
        GwOk       = $gwOK
        ExtOk      = $extOK
        ExtOkCount = $extOKCount
        ExtCount   = $nExternal
        ExtUnreachable = $extUnreachable
        TcpExtOk   = $extTcpOK
        DoTcp      = $doTcpProbe
        LbMs       = $lbResult
    }
    $verdictCtx = @{
        RoutingContext            = $routingContext
        UnderlayAvailable         = $underlayAvailable
        LanGwMs                   = $lanGwMs
        LanStatus                 = $lanStatus
        LanDeltaSum               = ([int]$lanDRe + [int]$lanDRd + [int]$lanDTe)
        LanDRe                    = $lanDRe; LanDRd = $lanDRd; LanDTe = $lanDTe
        GwResult                  = $gwResult
        EthStatus                 = $ethStatus
        DRxErr                    = $dRxErr; DRxDisc = $dRxDisc; DTxErr = $dTxErr
        DeltaSum                  = ([int]$dRxErr + [int]$dRxDisc + [int]$dTxErr)
        DnsOk                     = [bool]$dnsDiag.Ok
        SkipDnsProbe              = $skipDns
        LinkSpeedChanged          = $linkSpeedChangedThisCycle
        SkipGwIcmpPolicy          = $skipGwIcmpPolicy
        Now                       = $Now
        GwIcmpPolicyConfirmCycles = $gwConfirm
        NaRefreshPresent          = ($null -ne $naRefresh)
    }
    $v = Get-NetworkDiagCycleVerdict -Probes $verdictInput -Ctx $verdictCtx -State $State
    $verdict = [string]$v.Verdict
    $color = [string]$v.Color
    $incidentLine = $v.IncidentLine

    if ($v.PolicyActivated) {
        $Stats.NormalGwIcmpPolicyActivations = [int]$Stats.NormalGwIcmpPolicyActivations + 1
        Add-NetworkDiagIncident -Stats $Stats -Line "$Now  GW_ICMP_POLICY_ARMED - stable gw-fail/ext-ok/tcp-ok pattern confirmed over $gwConfirm cycles; interpreting as policy limitation while pattern remains stable"
    }
    if ($v.PolicyDeactivated) {
        $Stats.NormalGwIcmpPolicyDeactivations = [int]$Stats.NormalGwIcmpPolicyDeactivations + 1
        Add-NetworkDiagIncident -Stats $Stats -Line "$Now  GW_ICMP_POLICY_OFF - stable gateway no-echo pattern no longer matched; reverted to normal verdict logic"
    }
    $vpnAdjustedThisCycle = [bool]$v.VpnAdjusted
    $normalGwIcmpAdjustedThisCycle = [bool]$v.NormalAdjusted
    $result.VpnAdjusted = $vpnAdjustedThisCycle
    $result.NormalAdjusted = $normalGwIcmpAdjustedThisCycle

    if (-not $doTcpProbe) {
        $baseEvidence = "ICMP_ONLY"
    } elseif (-not $extOK -and $extTcpOK) {
        $baseEvidence = "TCP_OK_ICMP_FAIL"
    } elseif ($extOK -and -not $extTcpOK) {
        $baseEvidence = "ICMP_OK_TCP_FAIL"
    } else {
        $baseEvidence = "ICMP_TCP_ALIGN"
    }
    if ($null -ne $v.VpnPolicyEvidence -and $v.VpnPolicyEvidence.Length -gt 0) {
        $evidence = "$($v.VpnPolicyEvidence)+$baseEvidence"
    } elseif ($null -ne $v.NormalPolicyEvidence -and $v.NormalPolicyEvidence.Length -gt 0) {
        $evidence = "$($v.NormalPolicyEvidence)+$baseEvidence"
    } else {
        $evidence = $baseEvidence
    }
    $appendPrimaryNicDelta = ($verdictCtx.DeltaSum -gt 0) -and (
        $verdict -eq "LOCAL_FAULT" -or ($verdict -ne "OK" -and -not $gwOK -and -not $vpnAdjustedThisCycle -and -not $normalGwIcmpAdjustedThisCycle)
    )
    if ($appendPrimaryNicDelta) { $evidence = "$evidence+NIC_DELTA" }
    if (-not $skipDns -and -not $dnsDiag.Ok -and $verdict -eq "OK") {
        $evidence = "$evidence+DNS_FAIL"
    }
    if ($verdict -eq "LOCAL_FAULT" -and $v.VpnPolicyEvidence -eq "LAN_BAD+NIC_HINT") {
        if (([int]$lanDRe + [int]$lanDRd + [int]$lanDTe) -gt 0) {
            $evidence = "$evidence+UL_NIC_DELTA"
        }
    }

    # ── UDP probe per-cycle delta ──────────────────────────────────────────
    $udpDelta = $null
    $udpEnabled = [bool]$Cfg.EnableUdpProbe
    if ($udpEnabled -and $Cfg.UdpProbeHandle -and (Get-Command -Name "Read-NetworkDiagUdpProbeDelta" -ErrorAction SilentlyContinue)) {
        if (-not $State.ContainsKey("UdpProbePrev")) {
            $State.UdpProbePrev = New-NetworkDiagUdpPrevState
        }
        try {
            $udpDelta = Read-NetworkDiagUdpProbeDelta -Handle $Cfg.UdpProbeHandle -Prev $State.UdpProbePrev
        } catch { $udpDelta = $null }
        if ($udpDelta -and $udpDelta.Available) {
            $Stats.UdpProbeStarted = [bool]$udpDelta.Started
            $Stats.UdpTotalPacketsSent = [long]$udpDelta.TotalPacketsSent
            $Stats.UdpTotalSendErrors = [long]$udpDelta.TotalSendErrors
            $Stats.UdpTotalRepliesRecv = [long]$udpDelta.TotalRepliesRecv
            if ([int]$udpDelta.MaxConsecSendErrors -gt [int]$Stats.UdpMaxConsecSendErrors) {
                $Stats.UdpMaxConsecSendErrors = [int]$udpDelta.MaxConsecSendErrors
            }
            if ($udpDelta.LastErrorCode) { $Stats.UdpLastErrorCode = [string]$udpDelta.LastErrorCode }
            if ($udpDelta.InitErrorMsg -and -not $Stats.UdpInitErrorMsg) {
                $Stats.UdpInitErrorMsg = [string]$udpDelta.InitErrorMsg
            }
            if ([int]$udpDelta.DeltaSendErrors -gt 0) { $Stats.UdpFailCycles = [int]$Stats.UdpFailCycles + 1 }
            if ([int]$udpDelta.ConsecSendErrors -ge 5) { $Stats.UdpStallCycles = [int]$Stats.UdpStallCycles + 1 }
            if ([int]$udpDelta.DeltaSendErrors -gt 0) { $evidence = "$evidence+UDP_SEND_FAIL" }
        }
    }

    # ── Long-lived TCP session per-cycle delta ─────────────────────────────
    $tcpSessDelta = $null
    $tcpSessEnabled = [bool]$Cfg.EnableLongLivedTcp
    if ($tcpSessEnabled -and $Cfg.TcpSessionHandle -and (Get-Command -Name "Read-NetworkDiagTcpSessionDelta" -ErrorAction SilentlyContinue)) {
        if (-not $State.ContainsKey("TcpSessionPrev")) {
            $State.TcpSessionPrev = New-NetworkDiagTcpSessionPrevState
        }
        try {
            $tcpSessDelta = Read-NetworkDiagTcpSessionDelta -Handle $Cfg.TcpSessionHandle -Prev $State.TcpSessionPrev
        } catch { $tcpSessDelta = $null }
        if ($tcpSessDelta -and $tcpSessDelta.Available) {
            $Stats.TcpSessionStarted = [bool]$tcpSessDelta.Started
            $Stats.TcpSessionTotalResets = [int]$tcpSessDelta.TotalResets
            $Stats.TcpSessionTotalConnectAttempts = [int]$tcpSessDelta.TotalConnectAttempts
            $Stats.TcpSessionTotalConnectFailures = [int]$tcpSessDelta.TotalConnectFailures
            if ($tcpSessDelta.LastResetReason) { $Stats.TcpSessionLastResetReason = [string]$tcpSessDelta.LastResetReason }
            if ([int]$tcpSessDelta.DeltaResets -gt 0) { $Stats.TcpSessionResetCycles = [int]$Stats.TcpSessionResetCycles + 1 }
            if (-not $tcpSessDelta.IsConnected) { $Stats.TcpSessionDisconnectedCycles = [int]$Stats.TcpSessionDisconnectedCycles + 1 }
            if ([int]$tcpSessDelta.DeltaResets -gt 0) {
                $evidence = "$evidence+TCP_SESS_RESET"
                Add-NetworkDiagIncident -Stats $Stats -Line "$Now  TCP_SESSION_RESET resets+=$($tcpSessDelta.DeltaResets) reason='$($tcpSessDelta.LastResetReason)'"
            }
        }
    }

    # ── Auto-capture trigger on first non-OK cycle (subject to per-run cap) ──
    if (-not $State.ContainsKey("AutoCaptureHandle")) { $State.AutoCaptureHandle = $null }
    if ([bool]$Cfg.EnableAutoCapture -and (Get-Command -Name "Start-NetworkDiagAutoCapture" -ErrorAction SilentlyContinue)) {
        $maxCap = [int]$Cfg.AutoCaptureMax
        if ($maxCap -le 0) { $maxCap = 1 }
        $hasActive = ($null -ne $State.AutoCaptureHandle)
        if ($hasActive) {
            $shared = $State.AutoCaptureHandle.Shared
            $finalStates = @("done", "stop_failed", "start_failed", "exception")
            if ([string]$shared.State -in $finalStates) {
                try {
                    $finalSnap = Stop-NetworkDiagAutoCapture -Handle $State.AutoCaptureHandle -WaitMs 1500
                } catch { $finalSnap = $shared }
                $Stats.AutoCaptureLastState = [string]$shared.State
                if ($shared.FilePath) {
                    $Stats.AutoCaptureLastFile = [string]$shared.FilePath
                    if ([string]$shared.State -eq "done") {
                        try { [void]$Stats.AutoCaptureFiles.Add([string]$shared.FilePath) } catch { }
                    }
                }
                Add-NetworkDiagIncident -Stats $Stats -Line "$Now  AUTO_CAPTURE_$([string]$shared.State.ToUpperInvariant()) file='$([string]$shared.FilePath)' method=$([string]$shared.Method) seconds=$([int]$shared.Seconds)"
                $State.AutoCaptureHandle = $null
                $hasActive = $false
            }
        }
        if (-not $hasActive -and $verdict -ne "OK" -and [int]$Stats.AutoCaptureCount -lt $maxCap -and [bool]$Cfg.IsAdmin -and [bool]$Cfg.AutoCaptureSupported) {
            $reasonShort = if ($verdict) { [string]$verdict } else { "fault" }
            try {
                $h = Start-NetworkDiagAutoCapture -OutputFolder ([string]$Cfg.OutputFolder) -Method ([string]$Cfg.AutoCaptureMethod) -Seconds ([int]$Cfg.AutoCaptureSeconds) -Reason $reasonShort
                if ($h) {
                    $State.AutoCaptureHandle = $h
                    $Stats.AutoCaptureCount = [int]$Stats.AutoCaptureCount + 1
                    Add-NetworkDiagIncident -Stats $Stats -Line "$Now  AUTO_CAPTURE_START method=$([string]$Cfg.AutoCaptureMethod) seconds=$([int]$Cfg.AutoCaptureSeconds) reason=$reasonShort file='$([string]$h.Shared.FilePath)' (admin=yes)"
                }
            } catch {
                Add-NetworkDiagIncident -Stats $Stats -Line "$Now  AUTO_CAPTURE_FAIL_TO_SPAWN $($_.Exception.Message)"
            }
        } elseif (-not $hasActive -and $verdict -ne "OK" -and -not [bool]$Cfg.IsAdmin -and -not [bool]$Stats.AutoCaptureSkippedNonAdmin) {
            $Stats.AutoCaptureSkippedNonAdmin = $true
            Add-NetworkDiagIncident -Stats $Stats -Line "$Now  AUTO_CAPTURE_SKIPPED reason=non_admin (capture would require elevation)"
        }
    }

    $configAuditCodes = @()
    if (-not $Cfg.SkipConfigAudit -and $verdict -ne "OK" -and (Get-Command -Name "Invoke-NetworkDiagConfigAudit" -ErrorAction SilentlyContinue)) {
        try {
            $auditRes = Invoke-NetworkDiagConfigAudit -Cfg $Cfg -Snap $Snap -RunStart $Cfg.RunStartTime -Cached $State.ConfigAuditCache -LookbackMinutes $(if ($Cfg.ContainsKey("EventLogLookbackMinutes")) { [int]$Cfg.EventLogLookbackMinutes } else { 0 })
            if ($auditRes) {
                $State.ConfigAuditCache = $auditRes
                $configAuditCodes = @($auditRes.FindingCodes)
            }
        } catch { }
    }
    if ($configAuditCodes.Count -gt 0) {
        $Stats.ConfigAuditFindingCycles = [int]$Stats.ConfigAuditFindingCycles + 1
        $Stats.ConfigAuditLastCodes = $configAuditCodes
    }
    $result.ConfigAuditCodes = $configAuditCodes

    $cableHintCodes = @()
    if (-not $Cfg.SkipCableHints -and $verdict -ne "OK" -and (Get-Command -Name "Get-NetworkDiagCableHints" -ErrorAction SilentlyContinue)) {
        try {
            $ch = Get-NetworkDiagCableHints -Adapter $naRefresh -Baseline $Cfg.CableBaseline -RunStart $Cfg.RunStartTime -State $State -Now $Now -DRxErr $dRxErr -DRxDisc $dRxDisc -DTxErr $dTxErr
            if ($ch) { $cableHintCodes = @($ch.HintCodes) }
        } catch { }
    }
    if ($cableHintCodes.Count -gt 0) {
        $Stats.CableHintCycles = [int]$Stats.CableHintCycles + 1
        $Stats.CableHintLastCodes = $cableHintCodes
    }
    $result.CableHintCodes = $cableHintCodes

    $mnRoster = ""; $mnGw = "na"; $mnExt = "na"; $primaryLinkSuspect = $false; $altExtOk = $false
    $mnExtOutcomeByIf = @{}
    $mnExternalTargets = @()
    $mnCertainty = "na"
    $primaryLinkSuspectReason = "NONE"
    if (-not $Cfg.SkipMultiNicCrossCheck -and $verdict -ne "OK" -and
        $Cfg.MultiNicRoster -and (@($Cfg.MultiNicRoster).Count -ge 1) -and
        (Get-Command -Name "Invoke-NetworkDiagMultiNicProbe" -ErrorAction SilentlyContinue)) {
        try {
            $mnPrimaryGwOk = $gwOK
            $mnPrimaryExtOk = $extOK
            foreach ($et in @($externalTargets)) {
                if ($mnExternalTargets.Count -ge 3) { break }
                if ($et -and $et.IcmpTarget) { $mnExternalTargets += [string]$et.IcmpTarget }
            }
            $mnExternalIp = if ($mnExternalTargets.Count -gt 0) { [string]$mnExternalTargets[0] } else { "" }
            $mn = Invoke-NetworkDiagMultiNicProbe -Roster $Cfg.MultiNicRoster -ExternalPinIp $mnExternalIp -ExternalPinIps $mnExternalTargets -TimeoutMs ($icmpTimeout * 1000) -IsAdmin $Cfg.IsAdmin
            if ($mn) {
                $mnRoster = [string]$mn.Roster
                $mnGw = [string]$mn.GwResults
                $mnExt = [string]$mn.ExtResults
                if ($mn.ExtOutcomeByIf) { $mnExtOutcomeByIf = $mn.ExtOutcomeByIf }
                $altExtOk = [bool]$mn.AltExtOk
                $strictConfirmed = $false
                $looseIndicative = $false
                foreach ($rr in @($Cfg.MultiNicRoster)) {
                    if (-not $rr) { continue }
                    $ifx = [int]$rr.IfIndex
                    $gwToken = "$([string]$rr.Kind)=ok"
                    $gwOkOnAlt = ($mnGw -like "*$gwToken*")
                    if (-not $gwOkOnAlt) { continue }
                    if (-not $mnExtOutcomeByIf.ContainsKey($ifx)) { continue }
                    $eo = $mnExtOutcomeByIf[$ifx]
                    $strictOkCount = 0
                    $looseOkCount = 0
                    $attemptCount = 0
                    if ($eo) {
                        $strictOkCount = [int]$eo.StrictOkCount
                        $looseOkCount = [int]$eo.LooseOkCount
                        $attemptCount = [int]$eo.AttemptCount
                    }
                    if ($strictOkCount -ge 1) {
                        $strictConfirmed = $true
                    } elseif ($looseOkCount -ge 2 -and $attemptCount -ge 2) {
                        $looseIndicative = $true
                    }
                }
                if ($strictConfirmed) {
                    $mnCertainty = "strict-confirmed"
                } elseif ($looseIndicative) {
                    $mnCertainty = "loose-indicative"
                } else {
                    $mnCertainty = "inconclusive"
                }
                $primaryFaultEligible = (($verdict -eq "LOCAL_FAULT") -and (-not $mnPrimaryGwOk))
                $ispLikeContext = ($mnPrimaryGwOk -and (-not $mnPrimaryExtOk)) -or ($verdict -eq "ISP_FAULT")
                if ($primaryFaultEligible -and (-not $ispLikeContext)) {
                    if ($mnCertainty -eq "strict-confirmed") {
                        $primaryLinkSuspect = $true
                        $primaryLinkSuspectReason = "ALT_GW_OK_EXT_STRICT_OK"
                    } elseif ($mnCertainty -eq "loose-indicative") {
                        $primaryLinkSuspect = $true
                        $primaryLinkSuspectReason = "ALT_GW_OK_EXT_LOOSE_MULTI_OK"
                    }
                }
                $Stats.MultiNicCrossCheckCycles = [int]$Stats.MultiNicCrossCheckCycles + 1
                if ($mnCertainty -eq "strict-confirmed") {
                    $Stats.MultiNicStrictConfirmedCycles = [int]$Stats.MultiNicStrictConfirmedCycles + 1
                } elseif ($mnCertainty -eq "loose-indicative") {
                    $Stats.MultiNicLooseIndicativeCycles = [int]$Stats.MultiNicLooseIndicativeCycles + 1
                } elseif ($mnCertainty -eq "inconclusive") {
                    $Stats.MultiNicInconclusiveCycles = [int]$Stats.MultiNicInconclusiveCycles + 1
                }
                if ($altExtOk) { $Stats.MultiNicAltExtOkCycles = [int]$Stats.MultiNicAltExtOkCycles + 1 }
                if ($primaryLinkSuspect) {
                    $Stats.PrimaryLinkSuspectCycles = [int]$Stats.PrimaryLinkSuspectCycles + 1
                    if (-not $Stats.MultiNicSuspectReasonCounts.ContainsKey($primaryLinkSuspectReason)) {
                        $Stats.MultiNicSuspectReasonCounts[$primaryLinkSuspectReason] = 0
                    }
                    $Stats.MultiNicSuspectReasonCounts[$primaryLinkSuspectReason] = [int]$Stats.MultiNicSuspectReasonCounts[$primaryLinkSuspectReason] + 1
                }
                $incLine = "$Now  MULTI_NIC_CROSSCHECK primary=$primaryAdapterDisp(gwOk=$(if ($gwOK) { 'yes' } else { 'no' }),extOk=$(if ($extOK) { 'yes' } else { 'no' })) alt=$($mn.AltSummary) certainty=$mnCertainty"
                if ($primaryLinkSuspect) {
                    $incLine += " => PRIMARY_LINK_SUSPECT reason=$primaryLinkSuspectReason"
                } elseif ($mnCertainty -eq "inconclusive") {
                    $incLine += " => INCONCLUSIVE"
                }
                Add-NetworkDiagIncident -Stats $Stats -Line $incLine
            }
        } catch { }
    }
    if ($primaryLinkSuspect) { $evidence = "$evidence+PRIMARY_LINK_SUSPECT" }
    $result.MultiNicRoster = $mnRoster
    $result.MultiNicGwResults = $mnGw
    $result.MultiNicExtResults = $mnExt
    $result.MultiNicExtOutcomeByIf = $mnExtOutcomeByIf
    $result.MultiNicExternalTargets = ($mnExternalTargets -join ";")
    $result.MultiNicCertainty = $mnCertainty
    $result.MultiNicSuspectReason = $primaryLinkSuspectReason
    $result.PrimaryLinkSuspect = $primaryLinkSuspect
    $result.MultiNicAltExtOk = $altExtOk

    # Episode tracking: group consecutive non-OK cycles and close after N stable OK cycles.
    if (-not $State.ContainsKey("EpisodeActive")) {
        $State.EpisodeActive = $false
        $State.EpisodeNextId = 1
        $State.EpisodeCurrentId = 0
        $State.EpisodeStart = ""
        $State.EpisodeLastBad = ""
        $State.EpisodeRecoveryStreak = 0
        $State.EpisodeRecoveryStart = ""
        $State.EpisodeVerdictCounts = @{}
        $State.EpisodeLastEvidence = ""
    }
    $episodeIdForRow = 0
    if ($verdict -ne "OK") {
        if (-not $State.EpisodeActive) {
            $State.EpisodeActive = $true
            $State.EpisodeCurrentId = [int]$State.EpisodeNextId
            $State.EpisodeNextId = [int]$State.EpisodeNextId + 1
            $State.EpisodeStart = [string]$Now
            $State.EpisodeVerdictCounts = @{}
            $State.EpisodeRecoveryStreak = 0
            $State.EpisodeRecoveryStart = ""
            Add-NetworkDiagIncident -Stats $Stats -Line "$Now  EPISODE_START id=$($State.EpisodeCurrentId) verdict=$verdict evidence=$evidence"
            $result.EpisodePhase = "start"
        } else {
            $result.EpisodePhase = "sustain"
        }
        $episodeIdForRow = [int]$State.EpisodeCurrentId
        $State.EpisodeLastBad = [string]$Now
        if (-not $State.EpisodeVerdictCounts.ContainsKey($verdict)) { $State.EpisodeVerdictCounts[$verdict] = 0 }
        $State.EpisodeVerdictCounts[$verdict] = [int]$State.EpisodeVerdictCounts[$verdict] + 1
        $State.EpisodeLastEvidence = [string]$evidence
        $State.EpisodeRecoveryStreak = 0
        $State.EpisodeRecoveryStart = ""
    } elseif ($State.EpisodeActive) {
        if ([int]$State.EpisodeRecoveryStreak -eq 0) {
            $State.EpisodeRecoveryStart = [string]$Now
            $result.EpisodePhase = "recovering"
        } else {
            $result.EpisodePhase = "recovering"
        }
        $episodeIdForRow = [int]$State.EpisodeCurrentId
        $State.EpisodeRecoveryStreak = [int]$State.EpisodeRecoveryStreak + 1
        if ([int]$State.EpisodeRecoveryStreak -ge [math]::Max(1, $episodeRecoveryConfirmCycles)) {
            $dominantVerdict = "UNKNOWN"
            $dominantCount = -1
            foreach ($vk in $State.EpisodeVerdictCounts.Keys) {
                $vc = [int]$State.EpisodeVerdictCounts[$vk]
                if ($vc -gt $dominantCount) {
                    $dominantCount = $vc
                    $dominantVerdict = [string]$vk
                }
            }
            Add-NetworkDiagIncident -Stats $Stats -Line "$Now  EPISODE_END id=$($State.EpisodeCurrentId) start=$($State.EpisodeStart) lastBad=$($State.EpisodeLastBad) recoveryStart=$($State.EpisodeRecoveryStart) dominant=$dominantVerdict evidence=$($State.EpisodeLastEvidence)"
            $epSummary = @{
                EpisodeId = [int]$State.EpisodeCurrentId
                Start = [string]$State.EpisodeStart
                End = [string]$Now
                LastBad = [string]$State.EpisodeLastBad
                RecoveryStart = [string]$State.EpisodeRecoveryStart
                DominantVerdict = $dominantVerdict
                DominantCount = [int][math]::Max(0, $dominantCount)
                LastEvidence = [string]$State.EpisodeLastEvidence
            }
            [void]$Stats.EpisodeSummaries.Add($epSummary)
            if ($Stats.EpisodeSummaries.Count -gt 2000) {
                $Stats.EpisodeSummaries.RemoveAt(0)
            }
            $Stats.EpisodeCount = [int]$Stats.EpisodeCount + 1
            $State.EpisodeActive = $false
            $State.EpisodeCurrentId = 0
            $State.EpisodeStart = ""
            $State.EpisodeLastBad = ""
            $State.EpisodeRecoveryStreak = 0
            $State.EpisodeRecoveryStart = ""
            $State.EpisodeVerdictCounts = @{}
            $State.EpisodeLastEvidence = ""
            $result.EpisodePhase = "end"
        }
    }
    $result.EpisodeId = $episodeIdForRow

    $wifiCsv = @{
        WifiSsid    = "na"; WifiBssid = "na"; WifiSignal = "na"
        WifiRadio   = "na"; WifiChannel = "na"
    }
    $wifiSnap = $null
    $wifiContextTag = ""
    if (-not $Cfg.SkipWifiSignal -and (Get-Command -Name "Get-NetworkDiagWifiSignalRaw" -ErrorAction SilentlyContinue)) {
        $primaryIsWifi = ($naRefresh -and (Test-IsWirelessAdapter $naRefresh))
        $wifiRosterEntry = $null
        if ((-not $primaryIsWifi) -and $Cfg.MultiNicRoster) {
            foreach ($rr in @($Cfg.MultiNicRoster)) {
                if ([string]$rr.Kind -eq "WiFi") { $wifiRosterEntry = $rr; break }
            }
        }
        if ($primaryIsWifi -or $wifiRosterEntry) {
            try {
                $parsed = $null
                $refreshWifiSnapshot = $true
                if ($State.ContainsKey("WifiLastCaptureUtc") -and $State.WifiLastCaptureUtc) {
                    $ageSec = ((Get-Date) - [datetime]$State.WifiLastCaptureUtc).TotalSeconds
                    if ($ageSec -lt [math]::Max(1, $wifiSnapshotMinSeconds) -and $State.ContainsKey("WifiParsedBlocks") -and $State.WifiParsedBlocks) {
                        $refreshWifiSnapshot = $false
                        $parsed = $State.WifiParsedBlocks
                    }
                }
                if ($refreshWifiSnapshot) {
                    $raw = Get-NetworkDiagWifiSignalRaw -TimeoutSeconds 5
                    if ($raw) {
                        $parsed = ConvertFrom-NetworkDiagNetshWlanInterfaces -Raw $raw
                        $State.WifiParsedBlocks = $parsed
                        $State.WifiLastCaptureUtc = [datetime]::UtcNow
                    } else {
                        $State.WifiParsedBlocks = $null
                    }
                }
                if ($parsed) {
                    $targetName = if ($primaryIsWifi) { [string]$naRefresh.Name } else { [string]$wifiRosterEntry.Name }
                    $wifiContextTag = if ($primaryIsWifi) { "primary" } else { "alt_roster" }
                    $wifiSnap = Get-NetworkDiagWifiSignalForAdapter -AdapterName $targetName -ParsedBlocks $parsed
                    $wifiCsv = Format-NetworkDiagWifiCsvFields -Snap $wifiSnap
                    if ($wifiSnap -and $wifiSnap.Available) {
                        Update-NetworkDiagWifiStats -Stats $Stats -Snap $wifiSnap -ContextTag $wifiContextTag
                        $Stats.WifiLastTimestamp = $Now
                    }
                }
            } catch { }
        }
    }
    $result.WifiCsv = $wifiCsv
    $result.WifiSnap = $wifiSnap
    $result.WifiContext = $wifiContextTag

    $lbDisp = if ($lbResult -ge 0) { "$($lbResult)ms" } else { "FAIL" }
    $gwDisp = if ($gwResult -ge 0) { "$($gwResult)ms" } else { "FAIL" }
    $extDispParts = @()
    for ($di = 0; $di -lt $nExternal; $di++) {
        $val = $extResults[$di]
        $extDispParts += "$($externalTargets[$di].Name):$(if ($val -ge 0) { "$($val)ms" } else { 'FAIL' })"
    }
    $extDispJoined = $extDispParts -join "  "
    $lanGwDisp = if ($null -ne $lanGwMs) {
        if ([int]$lanGwMs -ge 0) { "$([int]$lanGwMs)ms" } else { "FAIL" }
    } else { "na" }
    $tcpCfS = if (-not $doTcpProbe) { "na" } elseif ($tcpCf.Ok) { [string]$tcpCf.Ms } else { "-1" }
    $tcpGgS = if (-not $doTcpProbe) { "na" } elseif ($tcpGg.Ok) { [string]$tcpGg.Ms } else { "-1" }
    $dnsDisp = if ($skipDns) { "DNS:na" } elseif ($dnsDiag.Ok) { "DNS:$($dnsDiag.Ms)ms" } else { "DNS:FAIL" }
    $result.ConsoleLine1 = "[$Now] GW:$gwDisp  $extDispJoined  -> $verdict"
    $result.ConsoleLine2 = "         LB:$lbDisp  $dnsDisp  Eth:$ethStatus ${ethMbpsStr}Mbps  dRxE=$dRxErr dRxD=$dRxDisc dTxE=$dTxErr  LanGW:$lanGwDisp  TCP_CF_ms=$tcpCfS TCP_GG_ms=$tcpGgS  Ev=$evidence"

    $lanGwCsv = if ($null -ne $lanGwMs) { [string]([int]$lanGwMs) } else { "na" }
    $lanRxCsv = if ($underlayAvailable) { [string]$lanDRe } else { "na" }
    $lanRdCsv = if ($underlayAvailable) { [string]$lanDRd } else { "na" }
    $lanTxCsv = if ($underlayAvailable) { [string]$lanDTe } else { "na" }
    $dnsOkStr = if ($skipDns) { "na" } elseif ($dnsDiag.Ok) { "1" } else { "0" }
    $dnsMsStr = if ($skipDns) { "na" } elseif ($dnsDiag.Ok) { [string]$dnsDiag.Ms } else { "-1" }

    $csvRowVals = @{
        Timestamp          = $Now
        ProbeAddressFamily = $probeFamily
        Loopback_ms        = [string]$lbResult
        Eth_Status         = [string]$ethStatus
        Eth_Mbps           = [string]$ethMbpsStr
        RxErr_d            = [string]$dRxErr
        RxDisc_d           = [string]$dRxDisc
        TxErr_d            = [string]$dTxErr
        Gateway_ms         = [string]$gwResult
        TCP_CF_ms          = $tcpCfS
        TCP_GG_ms          = $tcpGgS
        Evidence           = [string]$evidence
        Dns_ok             = $dnsOkStr
        Dns_ms             = $dnsMsStr
        Verdict            = [string]$verdict
    }
    if ($legacyCsv) {
        $csvRowVals["Cloudflare_ms"] = if ($nExternal -ge 1) { [string]$extResults[0] } else { "na" }
        $csvRowVals["Google_ms"]     = if ($nExternal -ge 2) { [string]$extResults[1] } else { "na" }
        $csvRowVals["Quad9_ms"]      = if ($nExternal -ge 3) { [string]$extResults[2] } else { "na" }
    } else {
        for ($ci = 0; $ci -lt $nExternal; $ci++) {
            $csvRowVals["Ext$($ci + 1)_ms"] = [string]$extResults[$ci]
        }
        $csvRowVals["RoutingContext"]    = [string]$routingContext
        $csvRowVals["PrimaryAdapter"]    = [string]$primaryAdapterDisp
        $csvRowVals["UnderlayAdapter"]   = [string]$underlayAdapterCsv
        $csvRowVals["UnderlayAvailable"] = [string]$underlayAvailStr
        $csvRowVals["SchemaVersion"]     = $schemaVersion
        $csvRowVals["Lan_Status"]        = [string]$lanStatus
        $csvRowVals["Lan_Mbps"]          = [string]$lanMbpsStr
        $csvRowVals["LanGw_ms"]          = [string]$lanGwCsv
        $csvRowVals["LanRxErr_d"]        = [string]$lanRxCsv
        $csvRowVals["LanRxDisc_d"]       = [string]$lanRdCsv
        $csvRowVals["LanTxErr_d"]        = [string]$lanTxCsv
        $csvRowVals["Lan_IsEthernet"]    = [string]$lanIsEthStr
        $csvRowVals["Lan_Name"]          = [string]$lanNameStr
        $csvRowVals["ConfigAuditCode"]   = if ($configAuditCodes -and $configAuditCodes.Count -gt 0) { ($configAuditCodes -join ",") } else { "NONE" }
        $csvRowVals["CableHint"]         = if ($cableHintCodes -and $cableHintCodes.Count -gt 0) { ($cableHintCodes -join ",") } else { "NONE" }
        $csvRowVals["MultiNicRoster"]    = if ($mnRoster) { $mnRoster } else { "na" }
        $csvRowVals["MultiNicGwResults"] = $mnGw
        $csvRowVals["MultiNicExtResults"] = $mnExt
        $csvRowVals["MultiNicCertainty"] = [string]$mnCertainty
        $csvRowVals["MultiNicSuspectReason"] = [string]$primaryLinkSuspectReason
        $csvRowVals["EpisodeId"] = [string]$result.EpisodeId
        $csvRowVals["EpisodePhase"] = [string]$result.EpisodePhase
        $csvRowVals["WifiSsid"]    = [string]$wifiCsv.WifiSsid
        $csvRowVals["WifiBssid"]   = [string]$wifiCsv.WifiBssid
        $csvRowVals["WifiSignal"]  = [string]$wifiCsv.WifiSignal
        $csvRowVals["WifiRadio"]   = [string]$wifiCsv.WifiRadio
        $csvRowVals["WifiChannel"] = [string]$wifiCsv.WifiChannel
        $csvRowVals["TLS_CF_ms"]   = [string]$tlsCfMs
        $csvRowVals["TLS_GG_ms"]   = [string]$tlsGgMs
        if ($udpEnabled) {
            $udpD = if ($udpDelta) { $udpDelta } else { @{} }
            $csvRowVals["Udp_PktsSent_d"]    = if ($udpD.ContainsKey("DeltaPacketsSent")) { [string][int]$udpD.DeltaPacketsSent } else { "0" }
            $csvRowVals["Udp_SendErr_d"]     = if ($udpD.ContainsKey("DeltaSendErrors"))  { [string][int]$udpD.DeltaSendErrors }  else { "0" }
            $csvRowVals["Udp_RepliesRecv_d"] = if ($udpD.ContainsKey("DeltaRepliesRecv")) { [string][int]$udpD.DeltaRepliesRecv } else { "0" }
            $csvRowVals["Udp_ConsecErr"]     = if ($udpD.ContainsKey("ConsecSendErrors")) { [string][int]$udpD.ConsecSendErrors } else { "0" }
            $csvRowVals["Udp_LastErr"]       = if ($udpD.LastErrorCode) { ([string]$udpD.LastErrorCode) -replace '\s+', ' ' -replace ',', ';' } else { "" }
        }
        if ($tcpSessEnabled) {
            $tD = if ($tcpSessDelta) { $tcpSessDelta } else { @{} }
            $csvRowVals["TcpSess_State"] = if ($tD.IsConnected) { "Connected" } elseif ($tD.Started) { "Reconnecting" } else { "NotStarted" }
            $csvRowVals["TcpSess_UpSec"] = if ($tD.ContainsKey("UpSeconds")) { [string][int]$tD.UpSeconds } else { "-1" }
            $csvRowVals["TcpSess_Resets_d"] = if ($tD.ContainsKey("DeltaResets")) { [string][int]$tD.DeltaResets } else { "0" }
            $csvRowVals["TcpSess_LastReset"] = if ($tD.LastResetReason) { ([string]$tD.LastResetReason) -replace '\s+', ' ' -replace ',', ';' } else { "" }
        }
        if ([bool]$Cfg.EnableAutoCapture) {
            $acState = "idle"
            if ($State.AutoCaptureHandle -and $State.AutoCaptureHandle.Shared) { $acState = [string]$State.AutoCaptureHandle.Shared.State }
            elseif ($Stats.AutoCaptureLastState) { $acState = [string]$Stats.AutoCaptureLastState }
            $csvRowVals["AutoCap_State"] = [string]$acState
            $csvRowVals["AutoCap_Count"] = [string]([int]$Stats.AutoCaptureCount)
            $csvRowVals["AutoCap_LastFile"] = if ($Stats.AutoCaptureLastFile) { [string]$Stats.AutoCaptureLastFile } else { "" }
        }
        if ($perProbeTs) {
            $csvRowVals["Loopback_t_ms"] = if ($probeOffsets.ContainsKey("Loopback")) { [string]$probeOffsets["Loopback"] } else { "" }
            $csvRowVals["Dns_t_ms"]      = if ($probeOffsets.ContainsKey("Dns"))      { [string]$probeOffsets["Dns"] }      else { "" }
            $csvRowVals["LanGw_t_ms"]    = if ($probeOffsets.ContainsKey("LanGw"))    { [string]$probeOffsets["LanGw"] }    else { "" }
            $csvRowVals["Gw_t_ms"]       = if ($probeOffsets.ContainsKey("Gw"))       { [string]$probeOffsets["Gw"] }       else { "" }
            for ($pti = 1; $pti -le $nExternal; $pti++) {
                $k = "Ext$pti"
                $csvRowVals["${k}_t_ms"] = if ($probeOffsets.ContainsKey($k)) { [string]$probeOffsets[$k] } else { "" }
            }
            $csvRowVals["Tcp_CF_t_ms"]   = if ($probeOffsets.ContainsKey("TcpCf")) { [string]$probeOffsets["TcpCf"] } else { "" }
            $csvRowVals["Tcp_GG_t_ms"]   = if ($probeOffsets.ContainsKey("TcpGg")) { [string]$probeOffsets["TcpGg"] } else { "" }
            $csvRowVals["Tls_CF_t_ms"]   = if ($probeOffsets.ContainsKey("TlsCf")) { [string]$probeOffsets["TlsCf"] } else { "" }
            $csvRowVals["Tls_GG_t_ms"]   = if ($probeOffsets.ContainsKey("TlsGg")) { [string]$probeOffsets["TlsGg"] } else { "" }
        }
    }
    $result.CsvRowValues = $csvRowVals

    $detailExtras = ""
    if ($udpEnabled -and $udpDelta -and $udpDelta.Available) {
        $detailExtras += " UDP=sent$($udpDelta.DeltaPacketsSent)/err$($udpDelta.DeltaSendErrors)"
        if ([int]$udpDelta.ConsecSendErrors -gt 0) { $detailExtras += "/consec$($udpDelta.ConsecSendErrors)" }
    }
    if ($tcpSessEnabled -and $tcpSessDelta -and $tcpSessDelta.Available) {
        $tState = if ($tcpSessDelta.IsConnected) { "up" } elseif ($tcpSessDelta.Started) { "reconnecting" } else { "init" }
        $detailExtras += " TCP_SESS=$tState/upSec$($tcpSessDelta.UpSeconds)/reset_d$($tcpSessDelta.DeltaResets)"
    }
    if ([bool]$Cfg.EnableAutoCapture -and ($State.AutoCaptureHandle -or [int]$Stats.AutoCaptureCount -gt 0)) {
        $acStateD = "idle"
        if ($State.AutoCaptureHandle -and $State.AutoCaptureHandle.Shared) { $acStateD = [string]$State.AutoCaptureHandle.Shared.State }
        elseif ($Stats.AutoCaptureLastState) { $acStateD = [string]$Stats.AutoCaptureLastState }
        $detailExtras += " AC=$acStateD/n$([int]$Stats.AutoCaptureCount)"
    }
    if ($perProbeTs) {
        $tsParts = @()
        foreach ($k in @("Loopback", "Dns", "LanGw", "Gw")) {
            if ($probeOffsets.ContainsKey($k)) { $tsParts += "${k}+$($probeOffsets[$k])ms" }
        }
        for ($pti = 1; $pti -le $nExternal; $pti++) {
            $k = "Ext$pti"
            if ($probeOffsets.ContainsKey($k)) { $tsParts += "${k}+$($probeOffsets[$k])ms" }
        }
        foreach ($k in @("TcpCf", "TcpGg", "TlsCf", "TlsGg")) {
            if ($probeOffsets.ContainsKey($k)) { $tsParts += "${k}+$($probeOffsets[$k])ms" }
        }
        if ($tsParts.Count -gt 0) { $detailExtras += " ProbeTs=[$($tsParts -join ',')]" }
    }
    $result.DetailLine = "[$Now] Verdict=$verdict Evidence=$evidence LB=$lbDisp GW=$gwDisp EXT=$extDispJoined DNS=$dnsDisp Eth=$ethStatus ${ethMbpsStr}Mbps NIC_dRxE=$dRxErr dRxD=$dRxDisc dTxE=$dTxErr LanGW=$lanGwDisp Lan=$lanStatus UL_dRxE=$lanRxCsv UL_dRxD=$lanRdCsv UL_dTxE=$lanTxCsv TCP_CF_ms=$tcpCfS TCP_GG_ms=$tcpGgS$detailExtras"

    $Stats.CyclesCommitted++
    if ($gwResult -ge 0) {
        Add-NetworkDiagLatencySample -Agg $Stats.LatencyGwAgg -Value ([double]$gwResult)
        if ($null -ne $State.PrevGwGood) {
            $Stats.JitterGwSum += [math]::Abs($gwResult - [double]$State.PrevGwGood)
            $Stats.JitterGwPairs = [int]$Stats.JitterGwPairs + 1
        }
        $State.PrevGwGood = $gwResult
    } else {
        $Stats.GwFailCycles = [int]$Stats.GwFailCycles + 1
        $State.PrevGwGood = $null
    }
    for ($si = 0; $si -lt $nExternal; $si++) {
        $er = $extResults[$si]
        if ($er -ge 0) {
            Add-NetworkDiagLatencySample -Agg $Stats.LatencyExtAggs[$si] -Value ([double]$er)
            if ($null -ne $State.PrevExtGood[$si]) {
                $Stats.JitterExtSum[$si] += [math]::Abs($er - [double]$State.PrevExtGood[$si])
                $Stats.JitterExtPairs[$si] = [int]$Stats.JitterExtPairs[$si] + 1
            }
            $State.PrevExtGood[$si] = $er
        } else {
            $Stats.ExtFailCycles[$si] = [int]$Stats.ExtFailCycles[$si] + 1
            $State.PrevExtGood[$si] = $null
        }
    }
    if ($underlayAvailable -and $null -ne $lanGwMs) {
        if ([int]$lanGwMs -ge 0) {
            Add-NetworkDiagLatencySample -Agg $Stats.LatencyLanGwAgg -Value ([double][int]$lanGwMs)
        } else {
            $Stats.LanGwFailCycles = [int]$Stats.LanGwFailCycles + 1
        }
    }
    if (-not $skipDns -and -not $dnsDiag.Ok) {
        $Stats.DnsFailCycles = [int]$Stats.DnsFailCycles + 1
    }
    if ($vpnAdjustedThisCycle) { $Stats.VpnAdjustedOkCycles++ }
    if ($normalGwIcmpAdjustedThisCycle) { $Stats.NormalGwIcmpAdjustedOkCycles = [int]$Stats.NormalGwIcmpAdjustedOkCycles + 1 }

    if ($verdict -eq "OK") {
        $Stats.AllOK++
    } elseif ($verdict -eq "ISP_FAULT") {
        $Stats.ISP_Fault++
        $Stats.ExternalFails++
        if ($null -ne $incidentLine) { Add-NetworkDiagIncident -Stats $Stats -Line $incidentLine }
    } elseif ($verdict -eq "LOCAL_FAULT") {
        $Stats.Local_Fault++
        $Stats.GatewayFails++
        $Stats.ExternalFails++
        if ($null -ne $incidentLine) { Add-NetworkDiagIncident -Stats $Stats -Line $incidentLine }
    } else {
        $Stats.Anomaly++
        if ($evidence -like "VPN_TUNNEL_ONLY*") { $Stats.AnomalyVpnTunnelOnly++ }
        if ($null -ne $incidentLine) { Add-NetworkDiagIncident -Stats $Stats -Line $incidentLine }
    }

    $result.Verdict = $verdict
    $result.Color = $color
    $result.IncidentLine = $incidentLine
    $result.Evidence = $evidence
    return $result
}

function New-NetworkDiagCycleState {
    <#
    Fresh per-run state container. The outer loop owns these across cycles,
    but the cycle function reads/writes them so NIC seeding, jitter pairs,
    and the Normal-GW policy FSM all survive between invocations.
    #>
    param([int]$ExternalCount)
    $prevExt = [object[]]::new([math]::Max(0, $ExternalCount))
    for ($i = 0; $i -lt $ExternalCount; $i++) { $prevExt[$i] = $null }
    return @{
        PrevRxErr   = [uint64]0
        PrevRxDisc  = [uint64]0
        PrevTxErr   = [uint64]0
        NicCounterSeeded = $false
        UlPrevRxErr  = [uint64]0
        UlPrevRxDisc = [uint64]0
        UlPrevTxErr  = [uint64]0
        UlNicSeeded  = $false
        PrevGwGood   = $null
        PrevExtGood  = $prevExt
        NormalGwPolicyState  = "Inactive"
        NormalGwPolicyStreak = 0
        NormalGwPolicyArmedAt = $null
        ConfigAuditCache = $null
        CableConsecutiveDegradeCycles = 0
        LastLinkFlapCheckUtc = $null
        CableDiagUnavailableLogged = $false
        EpisodeActive = $false
        EpisodeNextId = 1
        EpisodeCurrentId = 0
        EpisodeStart = ""
        EpisodeLastBad = ""
        EpisodeRecoveryStreak = 0
        EpisodeRecoveryStart = ""
        EpisodeVerdictCounts = @{}
        EpisodeLastEvidence = ""
        WifiLastCaptureUtc = $null
        WifiParsedBlocks = $null
        UdpProbePrev = $null
        TcpSessionPrev = $null
        AutoCaptureHandle = $null
    }
}
