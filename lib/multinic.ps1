# lib/multinic.ps1
# Simultaneous Wi-Fi / Ethernet cross-check on non-OK cycles.
#
# Strategy:
#   * Build a roster at startup (and on route refresh) of every non-tunnel
#     Up adapter with its own default gateway for the probe family, minus
#     the primary routed adapter. Each roster entry keeps its gateway and
#     ifIndex so we can ping "its own router" straight off its L2 segment.
#   * When triggered on a fault cycle, fire one parallel round via a
#     runspace pool: Ping.Send(gateway) for each roster entry + Ping.Send
#     to one external pin IP for each roster entry.
#   * External probes are "strict" only when we can install a scoped host
#     route (-admin). On non-admin runs the ext result is "loose" and gets
#     the _LOOSE suffix so the report and Evidence tell the truth.

function Get-NetworkDiagCrossCheckRoster {
    param(
        [string]$ProbeAddressFamily = "IPv4",
        $PrimaryRouteIfIndex
    )
    $af = if ($ProbeAddressFamily -eq "IPv6") { "IPv6" } else { "IPv4" }
    $roster = [System.Collections.Generic.List[hashtable]]::new()
    try {
        $configs = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue)
        foreach ($c in $configs) {
            $idx = $c.InterfaceIndex
            if ($null -eq $idx) { continue }
            if ($null -ne $PrimaryRouteIfIndex -and [int]$idx -eq [int]$PrimaryRouteIfIndex) { continue }
            $na = Get-NetAdapter -InterfaceIndex $idx -ErrorAction SilentlyContinue
            if (-not $na -or $na.Status -ne "Up") { continue }
            if ((Test-VpnTunnelAdapter $na).IsVpnTunnel) { continue }
            $gwObj = if ($af -eq "IPv6") { $c.IPv6DefaultGateway } else { $c.IPv4DefaultGateway }
            if (-not $gwObj -or -not $gwObj.NextHop) { continue }
            $nh = [string]$gwObj.NextHop
            if (Test-NetworkDiagIsUnspecifiedNextHop -NextHop $nh -Family $af) { continue }
            $localIp = ""
            try {
                $ip = if ($af -eq "IPv6") { @($c.IPv6Address) } else { @($c.IPv4Address) }
                if ($ip -and $ip.Count -gt 0 -and $ip[0].IPAddress) {
                    $localIp = [string]$ip[0].IPAddress
                }
            } catch { }
            $isEth = Test-IsEthernetAdapter $na
            $kind = if ($isEth) { "Eth" } elseif ([string]$na.MediaType -match '(?i)802\.11|wireless|wi-fi|wifi') { "WiFi" } else { "Other" }
            $roster.Add(@{
                IfIndex  = [int]$idx
                Name     = [string]$na.Name
                Kind     = $kind
                LocalIp  = $localIp
                Gateway  = $nh
                Family   = $af
                IsEth    = $isEth
            })
        }
    } catch { }
    return , $roster
}

function Add-NetworkDiagHostRouteScoped {
    param(
        [string]$DestinationIp,
        [int]$InterfaceIndex,
        [string]$NextHop,
        [string]$AddressFamily
    )
    $prefix = if ($AddressFamily -eq "IPv6") { "$DestinationIp/128" } else { "$DestinationIp/32" }
    try {
        New-NetRoute -DestinationPrefix $prefix -InterfaceIndex $InterfaceIndex -NextHop $NextHop -RouteMetric 1 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
        return $prefix
    } catch {
        return $null
    }
}

function Remove-NetworkDiagHostRouteScoped {
    param(
        [string]$DestinationPrefix,
        [int]$InterfaceIndex,
        [string]$NextHop = ""
    )
    if (-not $DestinationPrefix) { return }
    try {
        if ($NextHop) {
            Remove-NetRoute -DestinationPrefix $DestinationPrefix -InterfaceIndex $InterfaceIndex -NextHop $NextHop -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        } else {
            Remove-NetRoute -DestinationPrefix $DestinationPrefix -InterfaceIndex $InterfaceIndex -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }
    } catch { }
}

function Invoke-NetworkDiagMultiNicProbe {
    <#
    Parallel gateway+external pings across the alt-adapter roster. Returns:
      @{ Roster; GwResults; ExtResults; AnyAltGwOk; AltExtOk; AltSummary }
    #>
    param(
        [Parameter(Mandatory = $true)]$Roster,
        [string]$ExternalPinIp,
        [string[]]$ExternalPinIps = @(),
        [int]$TimeoutMs = 2000,
        [bool]$IsAdmin = $false
    )
    if (-not $Roster -or $Roster.Count -eq 0) {
        return @{
            Roster     = ""
            GwResults  = "na"
            ExtResults = "na"
            AnyAltGwOk = $false
            AltExtOk   = $false
            AltSummary = "none"
            ExtOutcomeByIf = @{}
        }
    }
    $externalTargets = @()
    if ($ExternalPinIps -and $ExternalPinIps.Count -gt 0) {
        $externalTargets = @($ExternalPinIps | ForEach-Object { [string]$_ } | Where-Object { $_ -and $_.Trim() -ne "" })
    } elseif ($ExternalPinIp) {
        $externalTargets = @([string]$ExternalPinIp)
    }
    $dedup = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $extTargets = [System.Collections.Generic.List[string]]::new()
    foreach ($t in $externalTargets) {
        $tt = $t.Trim()
        if (-not $tt) { continue }
        if ($dedup.Add($tt)) { [void]$extTargets.Add($tt) }
    }
    $timeoutMsSafe = [math]::Max(500, $TimeoutMs)
    $pool = $null
    $jobs = [System.Collections.Generic.List[object]]::new()
    $scopedRoutes = [System.Collections.Generic.List[hashtable]]::new()
    try {
        $targetCountForPool = [math]::Max(1, $extTargets.Count)
        $pool = [runspacefactory]::CreateRunspacePool(1, [math]::Max(2, $Roster.Count * (1 + $targetCountForPool)))
        $pool.Open()
        foreach ($r in $Roster) {
            $psGw = [powershell]::Create().AddScript({
                    param($target, $timeoutMs)
                    try {
                        $p = New-Object System.Net.NetworkInformation.Ping
                        $buf = New-Object byte[] 32
                        $opts = New-Object System.Net.NetworkInformation.PingOptions 64, $false
                        $reply = $p.Send($target, $timeoutMs, $buf, $opts)
                        $ok = ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
                        $p.Dispose()
                        return @{ Ok = $ok; Ms = if ($ok) { [int]$reply.RoundtripTime } else { -1 } }
                    } catch {
                        return @{ Ok = $false; Ms = -1 }
                    }
                }).AddArgument([string]$r.Gateway).AddArgument($timeoutMsSafe)
            $psGw.RunspacePool = $pool
            $iarGw = $psGw.BeginInvoke()
            $jobs.Add(@{ Kind = "Gw"; Entry = $r; Ps = $psGw; Iar = $iarGw })

            foreach ($targetIp in $extTargets) {
                $scopedPrefix = $null
                if ($IsAdmin) {
                    $scopedPrefix = Add-NetworkDiagHostRouteScoped -DestinationIp $targetIp -InterfaceIndex $r.IfIndex -NextHop $r.Gateway -AddressFamily $r.Family
                    if ($scopedPrefix) {
                        $scopedRoutes.Add(@{ Prefix = $scopedPrefix; IfIndex = $r.IfIndex; NextHop = [string]$r.Gateway })
                    }
                }
                $psExt = [powershell]::Create().AddScript({
                        param($target, $timeoutMs)
                        try {
                            $p = New-Object System.Net.NetworkInformation.Ping
                            $buf = New-Object byte[] 32
                            $opts = New-Object System.Net.NetworkInformation.PingOptions 64, $false
                            $reply = $p.Send($target, $timeoutMs, $buf, $opts)
                            $ok = ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
                            $p.Dispose()
                            return @{ Ok = $ok; Ms = if ($ok) { [int]$reply.RoundtripTime } else { -1 } }
                        } catch {
                            return @{ Ok = $false; Ms = -1 }
                        }
                    }).AddArgument([string]$targetIp).AddArgument($timeoutMsSafe)
                $psExt.RunspacePool = $pool
                $iarExt = $psExt.BeginInvoke()
                $jobs.Add(@{
                        Kind = "Ext"; Entry = $r; Ps = $psExt; Iar = $iarExt
                        HadScopedRoute = [bool]$scopedPrefix; TargetIp = [string]$targetIp
                    })
            }
        }

        $gwResults = @{}
        $extResults = @{}
        foreach ($j in $jobs) {
            try {
                $out = $j.Ps.EndInvoke($j.Iar)
                $payload = $null
                if ($out -and $out.Count -gt 0) { $payload = $out[0] }
                if (-not $payload) { $payload = @{ Ok = $false; Ms = -1 } }
                if ($j.Kind -eq "Gw") {
                    $gwResults[$j.Entry.IfIndex] = $payload
                } else {
                    $p2 = $payload.Clone()
                    $p2["Loose"] = -not $j.HadScopedRoute
                    $p2["TargetIp"] = [string]$j.TargetIp
                    $p2["StrictReason"] = if ($j.HadScopedRoute) { "Strict" } elseif ($IsAdmin) { "RoutePinFailed" } else { "NoAdmin" }
                    if (-not $extResults.ContainsKey($j.Entry.IfIndex)) {
                        $extResults[$j.Entry.IfIndex] = [System.Collections.Generic.List[hashtable]]::new()
                    }
                    [void]$extResults[$j.Entry.IfIndex].Add($p2)
                }
            } catch {
                if ($j.Kind -eq "Gw") {
                    $gwResults[$j.Entry.IfIndex] = @{ Ok = $false; Ms = -1 }
                } else {
                    if (-not $extResults.ContainsKey($j.Entry.IfIndex)) {
                        $extResults[$j.Entry.IfIndex] = [System.Collections.Generic.List[hashtable]]::new()
                    }
                    [void]$extResults[$j.Entry.IfIndex].Add(@{
                            Ok = $false; Ms = -1; Loose = $true; TargetIp = [string]$j.TargetIp
                            StrictReason = if ($IsAdmin) { "ExceptionAfterPin" } else { "NoAdmin" }
                        })
                }
            } finally {
                try { $j.Ps.Dispose() } catch { }
            }
        }
    } finally {
        if ($null -ne $pool) {
            try { $pool.Close() } catch { }
            try { $pool.Dispose() } catch { }
        }
        foreach ($sr in $scopedRoutes) {
            Remove-NetworkDiagHostRouteScoped -DestinationPrefix $sr.Prefix -InterfaceIndex $sr.IfIndex -NextHop $sr.NextHop
        }
    }

    $rosterParts = @(); $gwParts = @(); $extParts = @(); $altSummary = @()
    $extOutcomeByIf = @{}
    $anyAltGwOk = $false; $altExtOk = $false
    foreach ($r in $Roster) {
        $tag = "$($r.Kind):$($r.Name)"
        $rosterParts += $tag
        $g = $gwResults[$r.IfIndex]
        $gwOk = ($g -and $g.Ok)
        if ($gwOk) { $anyAltGwOk = $true }
        $gwParts += "$($r.Kind)=$(if ($gwOk) { 'ok' } else { 'fail' })"
        $eList = @()
        if ($extResults.ContainsKey($r.IfIndex)) { $eList = @($extResults[$r.IfIndex]) }
        if ($eList.Count -gt 0) {
            $attemptCount = $eList.Count
            $okCount = 0
            $strictOkCount = 0
            $looseOkCount = 0
            foreach ($eo in $eList) {
                if ([bool]$eo.Ok) {
                    $okCount++
                    if ([bool]$eo.Loose) { $looseOkCount++ } else { $strictOkCount++ }
                }
            }
            $anyOk = $okCount -gt 0
            $allOk = $okCount -eq $attemptCount
            $modeTag = if ($strictOkCount -gt 0 -and $looseOkCount -gt 0) { "_mixed" } elseif ($strictOkCount -gt 0) { "_strict" } else { "_loose" }
            if ($anyOk) { $altExtOk = $true }
            $extParts += "$($r.Kind)=$(if ($anyOk) { "ok(${okCount}/${attemptCount})" } else { "fail(0/${attemptCount})" })$modeTag"
            $altSummary += "$($r.Kind)(gw_$(if ($gwOk) { 'ok' } else { 'fail' }),ext_$(if ($anyOk) { "ok_${okCount}of${attemptCount}" } else { "fail_0of${attemptCount}" })$modeTag)"
            $targetOutcomes = @()
            foreach ($eo in $eList) {
                $targetOutcomes += @{
                    TargetIp = [string]$eo.TargetIp
                    Ok = [bool]$eo.Ok
                    Ms = [int]$eo.Ms
                    Loose = [bool]$eo.Loose
                    StrictReason = [string]$eo.StrictReason
                }
            }
            $extOutcomeByIf[$r.IfIndex] = @{
                AnyOk = $anyOk
                AllOk = $allOk
                StrictOkCount = $strictOkCount
                LooseOkCount = $looseOkCount
                AttemptCount = $attemptCount
                TargetOutcomes = $targetOutcomes
            }
        } else {
            $extParts += "$($r.Kind)=na"
            $altSummary += "$($r.Kind)(gw_$(if ($gwOk) { 'ok' } else { 'fail' }),ext_na)"
            $extOutcomeByIf[$r.IfIndex] = @{
                AnyOk = $false
                AllOk = $false
                StrictOkCount = 0
                LooseOkCount = 0
                AttemptCount = 0
                TargetOutcomes = @()
            }
        }
    }
    return @{
        Roster     = ($rosterParts -join ";")
        GwResults  = ($gwParts -join ";")
        ExtResults = ($extParts -join ";")
        AnyAltGwOk = $anyAltGwOk
        AltExtOk   = $altExtOk
        AltSummary = ($altSummary -join "|")
        ExtOutcomeByIf = $extOutcomeByIf
    }
}
