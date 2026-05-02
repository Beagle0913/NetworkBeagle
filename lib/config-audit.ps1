# lib/config-audit.ps1
# Device configuration audit. Flags known misconfigurations that make the
# rest of the diagnostic reach "can't talk to anyone" before the cable /
# NIC / ISP layers even get a chance:
#
#   APIPA, duplicate/tentative IP, gateway-not-in-subnet, missing DNS,
#   unreachable DNS, multiple default gateways, DHCP mismatch, WinHTTP
#   proxy, recent Tcpip IP-conflict + NDIS media-disconnect events,
#   power/EEE/WoL on the routed NIC, optional path-MTU probe.
#
# The audit is cached per call site; the cycle hook re-uses a 30s cached
# result so non-OK cycles do not hammer the event log or adapter APIs.

function Invoke-NetworkDiagConfigAudit {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Cfg,
        [Parameter(Mandatory = $true)][hashtable]$Snap,
        [datetime]$RunStart,
        [hashtable]$Cached,
        [int]$LookbackMinutes = 0
    )
    $routedIdxEarly = $Snap.RouteIfIndex
    $gatewayEarly = [string]$Snap.Gateway
    $familyEarly = [string]$Cfg.ProbeAddressFamily
    if ($Cached -and $Cached.ContainsKey("Ts")) {
        $age = ([datetime]::UtcNow - [datetime]$Cached.Ts).TotalSeconds
        $stillValid = $age -lt 30
        if ($stillValid -and $Cached.ContainsKey("RouteIfIndex") -and $null -ne $routedIdxEarly) {
            if ([string]$Cached.RouteIfIndex -ne [string]$routedIdxEarly) { $stillValid = $false }
        }
        if ($stillValid -and $Cached.ContainsKey("Gateway") -and $gatewayEarly) {
            if ([string]$Cached.Gateway -ne $gatewayEarly) { $stillValid = $false }
        }
        if ($stillValid -and $Cached.ContainsKey("Family") -and $familyEarly) {
            if ([string]$Cached.Family -ne $familyEarly) { $stillValid = $false }
        }
        if ($stillValid) { return $Cached }
    }
    $codes = [System.Collections.Generic.List[string]]::new()
    $details = @{}
    $severity = "Ok"
    $family = [string]$Cfg.ProbeAddressFamily
    $af = if ($family -eq "IPv6") { "IPv6" } else { "IPv4" }
    $routedIdx = $Snap.RouteIfIndex
    $gateway = [string]$Snap.Gateway

    try {
        if ($null -ne $routedIdx -and $family -eq "IPv4") {
            $addrs = @(Get-NetIPAddress -InterfaceIndex $routedIdx -AddressFamily IPv4 -ErrorAction SilentlyContinue)
            foreach ($a in $addrs) {
                $ip = [string]$a.IPAddress
                $prefix = [int]$a.PrefixLength
                if ($ip -match '^169\.254\.') {
                    if (-not $codes.Contains("APIPA")) { [void]$codes.Add("APIPA") }
                    $details["APIPA"] = "$ip/$prefix on ifIndex=$routedIdx"
                }
                $st = [string]$a.AddressState
                if ($st -and ($st -ne "Preferred")) {
                    $c = "IP_ADDR_STATE_$($st.ToUpperInvariant())"
                    if (-not $codes.Contains($c)) { [void]$codes.Add($c) }
                    $details[$c] = "$ip/$prefix"
                }
                if ($gateway) {
                    $gwIp = $null
                    $hostIp = $null
                    if ([System.Net.IPAddress]::TryParse($gateway, [ref]$gwIp) -and [System.Net.IPAddress]::TryParse($ip, [ref]$hostIp)) {
                        if ($gwIp.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and $hostIp.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                            $mask = 0
                            if ($prefix -gt 0 -and $prefix -le 32) { $mask = [uint32]0xFFFFFFFF -shl (32 - $prefix) }
                            $hb = $hostIp.GetAddressBytes()
                            $gb = $gwIp.GetAddressBytes()
                            $hi = ([uint32]$hb[0] -shl 24) -bor ([uint32]$hb[1] -shl 16) -bor ([uint32]$hb[2] -shl 8) -bor [uint32]$hb[3]
                            $gi = ([uint32]$gb[0] -shl 24) -bor ([uint32]$gb[1] -shl 16) -bor ([uint32]$gb[2] -shl 8) -bor [uint32]$gb[3]
                            if ($prefix -gt 0 -and (($hi -band $mask) -ne ($gi -band $mask))) {
                                if (-not $codes.Contains("GW_SUBNET_MISMATCH")) { [void]$codes.Add("GW_SUBNET_MISMATCH") }
                                $details["GW_SUBNET_MISMATCH"] = "host=$ip/$prefix gw=$gateway"
                            }
                        }
                    }
                }
            }
        }
    } catch { }

    try {
        if ($null -ne $routedIdx) {
            $dns = Get-DnsClientServerAddress -InterfaceIndex $routedIdx -AddressFamily $af -ErrorAction SilentlyContinue
            $serverAddrs = @()
            if ($dns) { $serverAddrs = @($dns.ServerAddresses | Where-Object { $_ }) }
            if ($serverAddrs.Count -eq 0) {
                if (-not $codes.Contains("NO_DNS")) { [void]$codes.Add("NO_DNS") }
                $details["NO_DNS"] = "ifIndex=$routedIdx family=$af"
            } else {
                $anyReach = $false
                foreach ($s in ($serverAddrs | Select-Object -First 3)) {
                    $r = Invoke-IcmpProbe -Address $s -Count 1 -TimeoutSeconds 1
                    if ($r.MeanMs -ge 0) { $anyReach = $true; break }
                }
                if (-not $anyReach) {
                    if (-not $codes.Contains("DNS_UNREACH")) { [void]$codes.Add("DNS_UNREACH") }
                    $details["DNS_UNREACH"] = ($serverAddrs -join ",")
                }
            }
        }
    } catch { }

    try {
        $gws = 0
        $all = Get-NetIPConfiguration -ErrorAction SilentlyContinue
        foreach ($c in $all) {
            $na = Get-NetAdapter -InterfaceIndex $c.InterfaceIndex -ErrorAction SilentlyContinue
            if (-not $na -or $na.Status -ne "Up") { continue }
            if ((Test-VpnTunnelAdapter $na).IsVpnTunnel) { continue }
            $gw = if ($af -eq "IPv6") { $c.IPv6DefaultGateway } else { $c.IPv4DefaultGateway }
            if ($gw -and $gw.NextHop) {
                $nh = [string]$gw.NextHop
                if (-not (Test-NetworkDiagIsUnspecifiedNextHop -NextHop $nh -Family $af)) { $gws++ }
            }
        }
        if ($gws -ge 2) {
            [void]$codes.Add("MULTI_GW")
            $details["MULTI_GW"] = "count=$gws"
        }
    } catch { }

    try {
        if ($null -ne $routedIdx -and $family -eq "IPv4") {
            $ipif = Get-NetIPInterface -InterfaceIndex $routedIdx -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
            $dhcpEnabled = $false
            if ($ipif) { $dhcpEnabled = ($ipif.Dhcp -eq "Enabled") }
            $addrs = @(Get-NetIPAddress -InterfaceIndex $routedIdx -AddressFamily IPv4 -ErrorAction SilentlyContinue)
            $allManual = $true
            foreach ($a in $addrs) {
                if ([string]$a.PrefixOrigin -ne "Manual") { $allManual = $false; break }
            }
            if ($dhcpEnabled -and $allManual -and $addrs.Count -gt 0) {
                [void]$codes.Add("DHCP_CONFIG")
                $details["DHCP_CONFIG"] = "DHCP=Enabled but all IPv4 addresses are Manual origin"
            }
            if (-not $dhcpEnabled -and -not $allManual -and $addrs.Count -gt 0) {
                [void]$codes.Add("DHCP_CONFIG")
                $details["DHCP_CONFIG"] = "DHCP=Disabled but at least one IPv4 address is non-Manual origin"
            }
        }
    } catch { }

    try {
        $proxyProbe = Start-NetworkDiagBoundedExternalProcess -FilePath "netsh" -ArgumentList @("winhttp", "show", "proxy") -TimeoutSeconds 6
        if ($proxyProbe.Ok -and $proxyProbe.StdOut) {
            $txt = [string]$proxyProbe.StdOut
            if ($txt -notmatch '(?im)Direct access') {
                [void]$codes.Add("WINHTTP_PROXY")
                $snippet = ($txt -split "`n" | Where-Object { $_ -match ':' } | Select-Object -First 4) -join " | "
                $details["WINHTTP_PROXY"] = $snippet
            }
        }
    } catch { }

    try {
        if ($RunStart) {
            $eventStart = $RunStart
            if ($LookbackMinutes -gt 0) {
                $eventStart = (Get-Date).AddMinutes(-1 * [int]$LookbackMinutes)
            }
            $hashTcpip = @{ LogName = "System"; ProviderName = "Microsoft-Windows-Tcpip"; Id = @(4198, 4199); StartTime = $eventStart }
            $ev = @(Get-WinEvent -FilterHashtable $hashTcpip -MaxEvents 5 -ErrorAction SilentlyContinue)
            if ($ev -and $ev.Count -gt 0) {
                [void]$codes.Add("IP_CONFLICT_EVENT")
                $details["IP_CONFLICT_EVENT"] = "count=$($ev.Count) latest=$($ev[0].TimeCreated)"
            }
            if ($Snap.BoundAdapter -and $Snap.BoundAdapter.MacAddress) {
                $mac = [string]$Snap.BoundAdapter.MacAddress
                $hashNdis = @{ LogName = "System"; ProviderName = "Microsoft-Windows-NDIS"; Id = @(27, 10317); StartTime = $eventStart }
                $evN = @(Get-WinEvent -FilterHashtable $hashNdis -MaxEvents 25 -ErrorAction SilentlyContinue)
                $macNorm = ($mac -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
                $macHits = @()
                if ($evN -and $evN.Count -gt 0) {
                    foreach ($e in $evN) {
                        $msg = [string]$e.Message
                        if (-not $msg) { continue }
                        $msgNorm = ($msg -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
                        if ($macNorm -and ($msgNorm -match [regex]::Escape($macNorm) -or $msg -match [regex]::Escape($mac))) {
                            $macHits += $e
                            if ($macHits.Count -ge 3) { break }
                        }
                    }
                    if ($macHits.Count -eq 0 -and $Snap.BoundAdapter.Name) {
                        $rxName = [regex]::Escape([string]$Snap.BoundAdapter.Name)
                        foreach ($e in $evN) {
                            if ($e.Message -and ($e.Message -match $rxName)) {
                                $macHits += $e
                                if ($macHits.Count -ge 3) { break }
                            }
                        }
                    }
                }
                if ($macHits.Count -gt 0) {
                    [void]$codes.Add("NDIS_LINK_DOWN_EVENT")
                    $details["NDIS_LINK_DOWN_EVENT"] = "count=$($macHits.Count) latest=$($macHits[0].TimeCreated)"
                }
            }
        }
    } catch { }

    try {
        if ($null -ne $routedIdx) {
            $na = $Snap.BoundAdapter
            if ($na) {
                try {
                    $pm = Get-NetAdapterPowerManagement -Name $na.Name -ErrorAction SilentlyContinue
                    if ($pm) {
                        $saving = $false
                        foreach ($p in @("AllowComputerToTurnOffDevice", "SelectiveSuspend", "WakeOnMagicPacket")) {
                            $val = $pm.$p
                            if ($null -ne $val -and [string]$val -match '(?i)(enabled|allowed|true)') { $saving = $true }
                        }
                        if ($saving) {
                            [void]$codes.Add("POWER_SAVING")
                            $details["POWER_SAVING"] = "power-mgmt options allow device sleep; may drop link briefly"
                        }
                    }
                } catch { }
                try {
                    $adv = @(Get-NetAdapterAdvancedProperty -Name $na.Name -ErrorAction SilentlyContinue)
                    foreach ($p in $adv) {
                        $k = [string]$p.DisplayName
                        $v = [string]$p.DisplayValue
                        if ($k -match '(?i)energy-?efficient|EEE' -and $v -match '(?i)enabled|on|1') {
                            [void]$codes.Add("EEE_ENABLED")
                            $details["EEE_ENABLED"] = "$k=$v"
                        }
                    }
                } catch { }
            }
        }
    } catch { }

    if ($Cfg.PathMtuProbeTarget -and $family -eq "IPv4") {
        try {
            $mtu = Get-NetworkDiagPathMtuSoftProbe -Target ([string]$Cfg.PathMtuProbeTarget) -TimeoutMs 1500 -MaxSize 1472 -MinSize 1200
            if ($null -ne $mtu -and $mtu -gt 0 -and $mtu -lt 1400) {
                [void]$codes.Add("MTU_LOW_$mtu")
                $details["MTU_LOW"] = "effective=$mtu target=$($Cfg.PathMtuProbeTarget)"
            }
        } catch { }
    }

    if ($codes.Count -gt 0) { $severity = "Warn" }
    return @{
        FindingCodes = @($codes)
        Details      = $details
        Severity     = $severity
        Ts           = [datetime]::UtcNow
        RouteIfIndex = $routedIdx
        Gateway      = $gateway
        Family       = $family
    }
}

function Get-NetworkDiagPathMtuSoftProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [int]$TimeoutMs = 1500,
        [int]$MaxSize = 1472,
        [int]$MinSize = 1200
    )
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $opts = New-Object System.Net.NetworkInformation.PingOptions 64, $true
        $low = $MinSize; $high = $MaxSize; $best = 0
        while ($low -le $high) {
            $mid = [int](($low + $high) / 2)
            $buf = New-Object byte[] $mid
            $ok = $false
            try {
                $r = $ping.Send($Target, $TimeoutMs, $buf, $opts)
                if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $ok = $true }
            } catch { }
            if ($ok) { $best = $mid + 28; $low = $mid + 1 } else { $high = $mid - 1 }
        }
        $ping.Dispose()
        return $best
    } catch {
        return 0
    }
}
