# lib/routing.ps1
# Default route discovery, underlay selection when a VPN tunnel owns the
# default route, adapter classification (Ethernet/Tunnel/VirtualSwitch),
# routing identity + change detection used by -RoutingRefreshIntervalCycles.
#
# Optimization notes:
#   * A single Test-NetworkDiagIsUnspecifiedNextHop predicate replaces four
#     near-duplicate inline checks for 0.0.0.0 / "::" across the original
#     Select/Fallback/Underlay/Resolve functions.

function Test-NetworkDiagIsUnspecifiedNextHop {
    param(
        [string]$NextHop,
        [ValidateSet("IPv4", "IPv6")]
        [string]$Family
    )
    if ([string]::IsNullOrWhiteSpace($NextHop)) { return $true }
    $t = $NextHop.Trim()
    if ($Family -eq "IPv4") {
        return ($t -eq "0.0.0.0")
    }
    return ($t -eq "::" -or $t -eq "0:0:0:0:0:0:0:0")
}

function Test-IsEthernetAdapter {
    param($Adapter)
    if (-not $Adapter) { return $false }
    $mt = [string]$Adapter.MediaType
    if ($mt -eq "802.3") { return $true }
    if ($mt -match "Ethernet") { return $true }
    if ($Adapter.InterfaceDescription -match "Ethernet") { return $true }
    if ($Adapter.Name -match "Ethernet") { return $true }
    return $false
}

function Test-VpnTunnelAdapter {
    <#
    VPN / underlay: tunnel detection (priority MediaType -> Description -> Name).
    Returns { IsVpnTunnel, TunnelReason, TunnelDetail }.
    #>
    param($Adapter)
    $r = [pscustomobject]@{
        IsVpnTunnel  = $false
        TunnelReason = "None"
        TunnelDetail = ""
    }
    if (-not $Adapter) { return $r }
    $mt = [string]$Adapter.MediaType
    if ($mt -match '(?i)(wireguard|wintun|tunnel|tap|tun|vpn|ppp|ras|l2tp|ikev2|pptp|sstp)') {
        $r.IsVpnTunnel = $true
        $r.TunnelReason = "MediaType"
        $r.TunnelDetail = $mt.Trim()
        return $r
    }
    $desc = [string]$Adapter.InterfaceDescription
    $markers = @("Wintun", "WireGuard", "Mullvad", "OpenVPN Data Channel", "TAP-Windows", "TAP-Win32", "OpenVPN")
    foreach ($m in $markers) {
        if ($desc -like "*$m*") {
            $r.IsVpnTunnel = $true
            $r.TunnelReason = "Description"
            $r.TunnelDetail = $m
            return $r
        }
    }
    $name = [string]$Adapter.Name
    foreach ($m in @("Mullvad", "WireGuard", "Wintun", "OpenVPN")) {
        if ($name -like "*$m*") {
            $r.IsVpnTunnel = $true
            $r.TunnelReason = "Name"
            $r.TunnelDetail = $m
            return $r
        }
    }
    return $r
}

function Test-IsLikelyVirtualSwitchAdapter {
    param($Adapter)
    if (-not $Adapter) { return $false }
    $d = [string]$Adapter.InterfaceDescription
    $n = [string]$Adapter.Name
    if ($d -match '(?i)hyper-v|virtual\s+ethernet|vmware|virtualbox|vbox') { return $true }
    if ($n -match '(?i)vEthernet|vethernet') { return $true }
    return $false
}

function Select-NetworkDiagDefaultRoute {
    <#
    Picks the active default route for IPv4 (0.0.0.0/0) or IPv6 (::/0) using
    RouteMetric + InterfaceMetric (combined ascending).
    #>
    param(
        [ValidateSet("IPv4", "IPv6")]
        [string]$AddressFamily
    )
    $prefix = if ($AddressFamily -eq "IPv6") { "::/0" } else { "0.0.0.0/0" }
    $af = if ($AddressFamily -eq "IPv6") { "IPv6" } else { "IPv4" }
    $routes = @(Get-NetRoute -DestinationPrefix $prefix -AddressFamily $af -ErrorAction Stop | Where-Object {
            -not (Test-NetworkDiagIsUnspecifiedNextHop -NextHop ([string]$_.NextHop) -Family $AddressFamily)
        })
    if ($routes.Count -eq 0) {
        throw "No qualifying ${AddressFamily} default routes."
    }
    $scored = foreach ($r in $routes) {
        $rm = 256
        if ($null -ne $r.RouteMetric) { try { $rm = [int]$r.RouteMetric } catch { } }
        $im = 999999
        try {
            $ipi = Get-NetIPInterface -InterfaceIndex $r.InterfaceIndex -AddressFamily $af -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($ipi -and $null -ne $ipi.InterfaceMetric) { $im = [int]$ipi.InterfaceMetric }
        } catch { }
        $combined = $rm + $im
        [pscustomobject]@{
            Route             = $r
            CombinedMetric    = $combined
            RouteMetric       = $rm
            InterfaceMetric   = $im
        }
    }
    $best = $scored | Sort-Object CombinedMetric, RouteMetric, @{ Expression = { $_.Route.InterfaceIndex } } |
        Select-Object -First 1
    $rr = $best.Route
    $reason = "ifIndex=$($rr.InterfaceIndex) routeMetric=$($best.RouteMetric) ifMetric=$($best.InterfaceMetric) combined=$($best.CombinedMetric) nextHop=$($rr.NextHop)"
    return [pscustomobject]@{
        NextHop          = [string]$rr.NextHop
        InterfaceIndex   = [int]$rr.InterfaceIndex
        Route            = $rr
        SelectionReason  = $reason
        CombinedMetric   = $best.CombinedMetric
    }
}

function Get-NetworkDiagDefaultGatewayFromNetIPConfiguration {
    <#
    Fallback when Get-NetRoute default-route query fails: pick best default
    gateway from Get-NetIPConfiguration using combined route + interface
    metrics (parallel logic for IPv4 and IPv6).
    #>
    param(
        [ValidateSet("IPv4", "IPv6")]
        [string]$AddressFamily = "IPv4"
    )
    $prefix = if ($AddressFamily -eq "IPv6") { "::/0" } else { "0.0.0.0/0" }
    $af = if ($AddressFamily -eq "IPv6") { "IPv6" } else { "IPv4" }
    $configs = @(Get-NetIPConfiguration -ErrorAction Stop)
    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($cfg in $configs) {
        $idx = $cfg.InterfaceIndex
        if ($null -eq $idx) { continue }
        $gwObj = if ($AddressFamily -eq "IPv6") { $cfg.IPv6DefaultGateway } else { $cfg.IPv4DefaultGateway }
        if (-not $gwObj -or -not $gwObj.NextHop) { continue }
        $nh = [string]$gwObj.NextHop
        if (Test-NetworkDiagIsUnspecifiedNextHop -NextHop $nh -Family $AddressFamily) { continue }
        $rm = 256
        $routeMatches = @(Get-NetRoute -DestinationPrefix $prefix -InterfaceIndex $idx -AddressFamily $af -ErrorAction SilentlyContinue |
            Where-Object {
                -not (Test-NetworkDiagIsUnspecifiedNextHop -NextHop ([string]$_.NextHop) -Family $AddressFamily)
            })
        if ($routeMatches.Count -gt 0) {
            $rms = @($routeMatches | ForEach-Object {
                    try { [int]$_.RouteMetric } catch { 256 }
                })
            $rm = ($rms | Measure-Object -Minimum).Minimum
        }
        $im = 999999
        try {
            $ipi = Get-NetIPInterface -InterfaceIndex $idx -AddressFamily $af -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($ipi -and $null -ne $ipi.InterfaceMetric) { $im = [int]$ipi.InterfaceMetric }
        } catch { }
        $combined = $rm + $im
        [void]$candidates.Add([pscustomobject]@{
                NextHop          = $nh
                InterfaceIndex   = [int]$idx
                CombinedMetric   = $combined
                RouteMetric      = $rm
                InterfaceMetric  = $im
            })
    }
    if ($candidates.Count -eq 0) { return $null }
    $best = $candidates | Sort-Object CombinedMetric, RouteMetric, InterfaceIndex | Select-Object -First 1
    $reason = "fallback=NetIPConfiguration ifIndex=$($best.InterfaceIndex) routeMetric=$($best.RouteMetric) ifMetric=$($best.InterfaceMetric) combined=$($best.CombinedMetric) nextHop=$($best.NextHop)"
    return [pscustomobject]@{
        NextHop         = [string]$best.NextHop
        InterfaceIndex  = [int]$best.InterfaceIndex
        Route           = $null
        SelectionReason = $reason
        CombinedMetric  = $best.CombinedMetric
    }
}

function Resolve-NetworkDiagUnderlayLan {
    param(
        [Parameter(Mandatory = $true)][bool]$VpnTunnelDefault,
        [ValidateSet("IPv4", "IPv6")]
        [string]$AddressFamily = "IPv4"
    )
    $out = [ordered]@{
        Available       = $false
        IfIndex         = $null
        Gateway         = $null
        AdapterName     = ""
        IsEthernet      = $false
        Reason          = ""
        MayBeVirtual    = $false
        InterfaceMetric = $null
    }
    if (-not $VpnTunnelDefault) {
        $out.Reason = "NORMAL_NO_UNDERLAY"
        return [pscustomobject]$out
    }
    $af = if ($AddressFamily -eq "IPv6") { "IPv6" } else { "IPv4" }
    $configs = $null
    try {
        $configs = @(Get-NetIPConfiguration -ErrorAction Stop)
    } catch {
        $out.Reason = "UNDERLAY_RESOLVE_FAIL"
        return [pscustomobject]$out
    }
    $upNonTunnelNoGw = 0
    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($cfg in $configs) {
        $idx = $cfg.InterfaceIndex
        if ($null -eq $idx) { continue }
        $na = Get-NetAdapter -InterfaceIndex $idx -ErrorAction SilentlyContinue
        if (-not $na -or $na.Status -ne "Up") { continue }
        if ((Test-VpnTunnelAdapter $na).IsVpnTunnel) { continue }
        $gwObj = if ($AddressFamily -eq "IPv6") { $cfg.IPv6DefaultGateway } else { $cfg.IPv4DefaultGateway }
        $nh = if ($gwObj -and $gwObj.NextHop) { [string]$gwObj.NextHop } else { "" }
        if (Test-NetworkDiagIsUnspecifiedNextHop -NextHop $nh -Family $AddressFamily) {
            if ($AddressFamily -eq "IPv6") {
                if ($cfg.IPv6Address -and @($cfg.IPv6Address).Count -gt 0) { $upNonTunnelNoGw++ }
            } else {
                if ($cfg.IPv4Address -and @($cfg.IPv4Address).Count -gt 0) {
                    $upNonTunnelNoGw++
                }
            }
            continue
        }
        $candidates.Add([pscustomobject]@{
                Na         = $na
                IfIndex    = [int]$idx
                NextHop    = $nh
                IsEthernet = [bool](Test-IsEthernetAdapter $na)
                IsVirtual  = [bool](Test-IsLikelyVirtualSwitchAdapter $na)
            })
    }
    if ($candidates.Count -eq 0) {
        if ($upNonTunnelNoGw -gt 0) {
            $out.Reason = "UNDERLAY_NO_GW"
        } else {
            $out.Reason = "UNDERLAY_UNAVAILABLE"
        }
        return [pscustomobject]$out
    }

    $nonVirt = @($candidates | Where-Object { -not $_.IsVirtual })
    $pick = Select-NetworkDiagUnderlayFromList -List $nonVirt -AddressFamily $af
    if (-not $pick) {
        $pick = Select-NetworkDiagUnderlayFromList -List @($candidates) -AddressFamily $af
        if ($pick) { $out.MayBeVirtual = $true }
    }
    if (-not $pick) {
        $out.Reason = "UNDERLAY_UNAVAILABLE"
        return [pscustomobject]$out
    }
    $out.Available = $true
    $out.IfIndex = $pick.IfIndex
    $out.Gateway = $pick.NextHop
    $out.AdapterName = [string]$pick.Na.Name
    $out.IsEthernet = $pick.IsEthernet
    $out.Reason = ""
    try {
        $ipi0 = Get-NetIPInterface -InterfaceIndex $pick.IfIndex -AddressFamily $af -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($ipi0 -and $null -ne $ipi0.InterfaceMetric) {
            $out.InterfaceMetric = [int]$ipi0.InterfaceMetric
        }
    } catch { }
    return [pscustomobject]$out
}

function Select-NetworkDiagUnderlayFromList {
    param(
        [object[]]$List,
        [string]$AddressFamily
    )
    if (-not $List -or $List.Count -eq 0) { return $null }
    foreach ($c in $List) {
        $metric = 999999
        try {
            $ipi = Get-NetIPInterface -InterfaceIndex $c.IfIndex -AddressFamily $AddressFamily -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($ipi -and $null -ne $ipi.InterfaceMetric) {
                $metric = [int]$ipi.InterfaceMetric
            }
        } catch { }
        $c | Add-Member -NotePropertyName SortMetric -NotePropertyValue $metric -Force
    }
    return @($List | Sort-Object @{ Expression = { if ($_.IsEthernet) { 0 } else { 1 } } },
        @{ Expression = { $_.SortMetric } },
        @{ Expression = { $_.IfIndex } }) | Select-Object -First 1
}

function Invoke-NetworkDiagRoutingResolution {
    param(
        [ValidateSet("Startup", "Refresh")]
        [string]$Mode = "Startup",
        [bool]$RequireEthernetSwitch = $false,
        [string[]]$AbortRoots = @()
    )
    $sf = $script:NetworkDiagProbeAddressFamily
    $gw = $null
    $rif = $null
    $defRt = $null
    $selReason = ""
    try {
        $picked = Select-NetworkDiagDefaultRoute -AddressFamily $sf
        $defRt = $picked.Route
        $gw = $picked.NextHop
        $rif = $picked.InterfaceIndex
        $selReason = $picked.SelectionReason
        if ($Mode -eq "Startup") {
            Write-Host "  Default route ($sf): $selReason" -ForegroundColor Gray
        }
    } catch {
        try {
            $fb = Get-NetworkDiagDefaultGatewayFromNetIPConfiguration -AddressFamily $sf
            if ($fb) {
                $gw = $fb.NextHop
                $rif = $fb.InterfaceIndex
                $defRt = $fb.Route
                $selReason = $fb.SelectionReason
                if ($Mode -eq "Startup") {
                    Write-Host "  Default route (NetIPConfiguration fallback, $sf): $selReason" -ForegroundColor Gray
                }
            }
        } catch { }
    }

    $gwTrim = if ($gw) { $gw.Trim() } else { "" }
    if (Test-NetworkDiagIsUnspecifiedNextHop -NextHop $gwTrim -Family $sf) {
        if ($Mode -eq "Startup") {
            if ($sf -eq "IPv6") {
                Write-Host "ERROR: Could not detect a usable IPv6 default gateway (::/0). Enable IPv6 or check routing." -ForegroundColor Red
                $null = Write-NetworkDiagAbortFile -Reason "NoDefaultGateway" -Details "Get-NetRoute/NetIPConfiguration did not yield a usable IPv6 default gateway (no qualifying ::/0 next hop)." -OutputRoots $AbortRoots
            } else {
                Write-Host "ERROR: Could not detect a default gateway. Are you connected to a network?" -ForegroundColor Red
                $null = Write-NetworkDiagAbortFile -Reason "NoDefaultGateway" -Details "Get-NetRoute/NetIPConfiguration did not yield a usable IPv4 default gateway." -OutputRoots $AbortRoots
            }
            exit 1
        }
        return [pscustomobject]@{ Ok = $false }
    }

    if ($null -eq $rif -and $gw) {
        try {
            $cfg = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
                Where-Object {
                    if ($sf -eq "IPv6") {
                        $_.IPv6DefaultGateway -and [string]$_.IPv6DefaultGateway.NextHop -eq $gw
                    } else {
                        $_.IPv4DefaultGateway -and [string]$_.IPv4DefaultGateway.NextHop -eq $gw
                    }
                } |
                Select-Object -First 1
            if ($cfg) { $rif = $cfg.InterfaceIndex }
        } catch { }
    }

    $rifForNorm = if ($null -eq $rif) { -1 } else { [int]$rif }
    try {
        $gw = Normalize-NetworkDiagProbeEndpoint -Raw $gwTrim -ProbeAddressFamily $sf -InterfaceIndex $rifForNorm
    } catch {
        if ($Mode -eq "Startup") {
            Write-Host "ERROR: Default gateway address could not be normalized for ${sf}: $($_.Exception.Message)" -ForegroundColor Red
            $null = Write-NetworkDiagAbortFile -Reason "GatewayNormalizeFailed" -Details "$($_.Exception.Message)" -OutputRoots $AbortRoots
            exit 1
        }
        return [pscustomobject]@{ Ok = $false }
    }

    $ba = $null
    if ($null -ne $rif) {
        $ba = Get-NetAdapter -InterfaceIndex $rif -ErrorAction SilentlyContinue
    }

    $tun = Test-VpnTunnelAdapter $ba
    $rctx = if ($tun.IsVpnTunnel) { "VpnTunnelDefault" } else { "Normal" }
    $ulSt = Resolve-NetworkDiagUnderlayLan -VpnTunnelDefault ($rctx -eq "VpnTunnelDefault") -AddressFamily $sf

    $isEth = Test-IsEthernetAdapter $ba
    $ulAvail = [bool]$ulSt.Available
    $ulEth = [bool]$ulSt.IsEthernet
    $reqSat = $isEth -or ($rctx -eq "VpnTunnelDefault" -and $ulAvail -and $ulEth)
    $refreshEthViol = ($Mode -eq "Refresh" -and $RequireEthernetSwitch -and -not $reqSat)

    $underlayGwNorm = $ulSt.Gateway
    if ($ulAvail -and $ulSt.Gateway) {
        $ulIdxN = if ($null -eq $ulSt.IfIndex) { -1 } else { [int]$ulSt.IfIndex }
        try {
            $underlayGwNorm = Normalize-NetworkDiagProbeEndpoint -Raw ([string]$ulSt.Gateway) -ProbeAddressFamily $sf -InterfaceIndex $ulIdxN
        } catch {
            $underlayGwNorm = [string]$ulSt.Gateway
        }
    }

    if ($Mode -eq "Startup") {
        Write-Host "  Gateway: $($gw) (ifIndex=$rif)" -ForegroundColor Green
        if ($ba) {
            $initMbps = ConvertTo-LinkMbps $ba.LinkSpeed
            Write-Host "  Routed adapter: $($ba.Name) | MediaType=$($ba.MediaType) | Status=$($ba.Status) | LinkMbps=$(if ($null -ne $initMbps) { $initMbps } else { 'n/a' })" -ForegroundColor Green
            if (-not $isEth) {
                Write-Host "  WARNING: Default route is not on a detected Ethernet-class adapter (Wi-Fi or other?)." -ForegroundColor Yellow
                if ($RequireEthernetSwitch -and -not $reqSat) {
                    Write-Host "ERROR: -RequireEthernet specified but active route is not Ethernet-class and no Ethernet underlay with LAN gateway was resolved." -ForegroundColor Red
                    $null = Write-NetworkDiagAbortFile -Reason "RequireEthernetNotMet" -Details "Default route is not Ethernet-class; VPN underlay did not yield an Ethernet adapter with $($sf) default gateway." -OutputRoots $AbortRoots
                    exit 1
                }
                if ($RequireEthernetSwitch -and $rctx -eq "VpnTunnelDefault" -and $reqSat) {
                    Write-Host "  NOTE: -RequireEthernet satisfied via Ethernet underlay while default route is VPN tunnel." -ForegroundColor Gray
                }
            }
        } else {
            Write-Host "  WARNING: Could not resolve Get-NetAdapter for ifIndex $rif (NIC stats/link lines will be sparse)." -ForegroundColor Yellow
            if ($RequireEthernetSwitch -and -not $reqSat) {
                Write-Host "ERROR: -RequireEthernet specified but adapter could not be resolved (and no Ethernet underlay)." -ForegroundColor Red
                $null = Write-NetworkDiagAbortFile -Reason "RequireEthernetAdapterUnresolved" -Details "Could not resolve Get-NetAdapter for routed ifIndex." -OutputRoots $AbortRoots
                exit 1
            }
        }
        $tunSuf = if ($tun.TunnelReason -ne "None") {
            " (TunnelReason=$($tun.TunnelReason), TunnelDetail=$($tun.TunnelDetail))"
        } else { "" }
        Write-Host "`nRouting context: $rctx$tunSuf" -ForegroundColor Cyan
        $pad = if ($ba) { $ba.Name } else { "na" }
        Write-Host "  Primary route: $pad  ifIndex=$rif  gw=$gw" -ForegroundColor Gray
        $uAs = if ($ulAvail) { "yes" } else { "no" }
        $uEs = if (-not $ulAvail) { "n/a" } elseif ($ulEth) { "yes" } else { "no" }
        $uGw = if ($ulAvail) { $underlayGwNorm } else { "($($ulSt.Reason))" }
        $uNm = if ($ulAvail) { $ulSt.AdapterName } else { "na" }
        if ($ulSt.MayBeVirtual) {
            Write-Host "  WARNING: UnderlayMayBeVirtual - only virtual-switch-class adapters had a LAN gateway; using best ranked candidate." -ForegroundColor Yellow
        }
        Write-Host "  Underlay:      $uNm -> $uGw  (available=$uAs, Ethernet-class=$uEs)" -ForegroundColor Gray
    }

    return [pscustomobject]@{
        Ok                            = $true
        Gateway                       = $gw
        RouteIfIndex                  = $rif
        DefaultRoute                  = $defRt
        DefaultRouteSelectionReason   = $selReason
        BoundAdapter                  = $ba
        TunnelClass                   = $tun
        RoutingContext                = $rctx
        UnderlayState                 = $ulSt
        UnderlayIfIndex               = $ulSt.IfIndex
        UnderlayGateway               = $underlayGwNorm
        UnderlayAdapterName           = $ulSt.AdapterName
        UnderlayAvailable             = $ulAvail
        UnderlayIsEthernet            = $ulEth
        UnderlayReasonCode            = [string]$ulSt.Reason
        UnderlayMayBeVirtual          = [bool]$ulSt.MayBeVirtual
        UnderlayMetric                = $ulSt.InterfaceMetric
        PrimaryAdapterDisp            = if ($ba) { $ba.Name } else { "na" }
        IsEthernetBound               = $isEth
        RequireEthernetSatisfied      = $reqSat
        RefreshRequireEthernetViolation = $refreshEthViol
    }
}

function Format-NetworkDiagRouteRefreshIncidentLine {
    param(
        [string]$Timestamp,
        [hashtable]$OldSnap,
        [hashtable]$NewSnap,
        [bool]$BaselinesReset,
        [string]$RequireEthernetViolation = ""
    )
    $escTok = {
        param([string]$s)
        if ([string]::IsNullOrWhiteSpace($s)) { return "na" }
        return ($s -replace "\s+", "_")
    }
    $parts = @(
        "ROUTE_REFRESH",
        "old_gateway=$(& $escTok $OldSnap.gateway)",
        "new_gateway=$(& $escTok $NewSnap.gateway)",
        "old_routed_ifIndex=$($OldSnap.routeIfIndex)",
        "new_routed_ifIndex=$($NewSnap.routeIfIndex)",
        "old_routed_adapter=$(& $escTok $OldSnap.routedAdapter)",
        "new_routed_adapter=$(& $escTok $NewSnap.routedAdapter)",
        "old_routingContext=$($OldSnap.routingContext)",
        "new_routingContext=$($NewSnap.routingContext)",
        "old_underlay_ifIndex=$($OldSnap.underlayIfIndex)",
        "new_underlay_ifIndex=$($NewSnap.underlayIfIndex)",
        "baselines_reset=$(if ($BaselinesReset) { 'yes' } else { 'no' })"
    )
    if ($RequireEthernetViolation) {
        $parts += "require_ethernet_violation=$(& $escTok $RequireEthernetViolation)"
    }
    return "$Timestamp  $($parts -join ' ')"
}

function Get-NetworkDiagRoutingIdentityHashtable {
    param(
        [string]$Gateway,
        $RouteIfIndex,
        [string]$RoutingContext,
        $UnderlayIfIndex,
        [string]$RoutedAdapterName = "",
        [string]$ProbeAddressFamily = "IPv4"
    )
    return @{
        gateway             = [string]$Gateway
        routeIfIndex        = $(if ($null -eq $RouteIfIndex) { "na" } else { [string]$RouteIfIndex })
        routingContext      = [string]$RoutingContext
        underlayIfIndex     = $(if ($null -eq $UnderlayIfIndex) { "na" } else { [string]$UnderlayIfIndex })
        routedAdapter       = [string]$RoutedAdapterName
        probeAddressFamily  = [string]$ProbeAddressFamily
    }
}

function Test-NetworkDiagRoutingIdentityChanged {
    param([hashtable]$A, [hashtable]$B)
    return ($A.gateway -ne $B.gateway) -or ($A.routeIfIndex -ne $B.routeIfIndex) -or
    ($A.routingContext -ne $B.routingContext) -or ($A.underlayIfIndex -ne $B.underlayIfIndex) -or
    ($A.probeAddressFamily -ne $B.probeAddressFamily)
}
