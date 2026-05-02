# lib/probes.ps1
# ICMP, TCP/443, DNS, hostname resolution, address normalization, NIC
# counter reads, and the external-target build helper.
#
# Optimization notes (vs the original single-file script):
#   * Single family-aware hostname resolver (dropped the IPv4-only wrapper).
#   * External-target builder is factored out so the entrypoint only owns
#     orchestration, not per-target plumbing.

function Normalize-NetworkDiagProbeEndpoint {
    <#
    Single entry point for strings passed to Ping.Send and TcpClient.BeginConnect.
    Accepts IPv4/IPv6 literals (including bracketed forms), rejects wrong-family
    literals. When -AllowHostnameOrUnresolved is set, non-literal names pass through
    unchanged (the caller is expected to resolve).
    #>
    param(
        [string]$Raw,
        [ValidateSet("IPv4", "IPv6")]
        [string]$ProbeAddressFamily,
        [int]$InterfaceIndex = -1,
        [switch]$AllowHostnameOrUnresolved
    )
    if ([string]::IsNullOrWhiteSpace($Raw)) {
        if ($AllowHostnameOrUnresolved) { return "" }
        throw "Normalize-NetworkDiagProbeEndpoint: empty address."
    }
    $s = $Raw.Trim()
    if ($s.StartsWith("[") -and $s.Contains("]")) {
        $close = $s.IndexOf("]")
        if ($close -gt 1) {
            $s = $s.Substring(1, $close - 1).Trim()
        }
    }
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($s, [ref]$ip)) {
        if ($ProbeAddressFamily -eq "IPv4" -and $ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw "Normalize-NetworkDiagProbeEndpoint: expected IPv4 literal, got $($ip.AddressFamily): $Raw"
        }
        if ($ProbeAddressFamily -eq "IPv6") {
            if ($ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
                throw "Normalize-NetworkDiagProbeEndpoint: expected IPv6 literal, got $($ip.AddressFamily): $Raw"
            }
            if ($ip.IsIPv4MappedToIPv6) {
                throw "Normalize-NetworkDiagProbeEndpoint: IPv4-mapped IPv6 not allowed in IPv6 probe mode: $Raw"
            }
        }
        $out = $ip.ToString()
        if ($ProbeAddressFamily -eq "IPv6" -and $ip.IsIPv6LinkLocal) {
            if ($out -notmatch '%') {
                $zone = [uint32]$ip.ScopeId
                if ($zone -gt 0) {
                    $out = "$out%$zone"
                } elseif ($InterfaceIndex -ge 0) {
                    $out = "$out%$InterfaceIndex"
                }
            }
        }
        return $out
    }
    if ($AllowHostnameOrUnresolved) {
        return $Raw.Trim()
    }
    throw "Normalize-NetworkDiagProbeEndpoint: expected literal IP for $ProbeAddressFamily : $Raw"
}

function Resolve-NetworkDiagHostnameForProbeFamilyWithTimeout {
    <#
    Async DNS lookup with a hard wait cap. Returns the best-matching address
    for $ProbeAddressFamily. IPv4: numerically-lowest wins. IPv6: lowest
    address tier wins (GUA > ULA > LL > other), ties broken by lex-lowest.
    Returns "" on timeout / no match / error.
    #>
    param(
        [string]$Name,
        [int]$TimeoutMs,
        [ValidateSet("IPv4", "IPv6")]
        [string]$ProbeAddressFamily
    )
    if (-not $Name) { return "" }
    $ipTry = $null
    if ([System.Net.IPAddress]::TryParse($Name.Trim(), [ref]$ipTry)) {
        if ($ProbeAddressFamily -eq "IPv4" -and $ipTry.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
            return $ipTry.ToString()
        }
        if ($ProbeAddressFamily -eq "IPv6" -and $ipTry.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6 -and -not $ipTry.IsIPv4MappedToIPv6) {
            return $ipTry.ToString()
        }
        return ""
    }
    $iar = $null
    $wh = $null
    try {
        $iar = [System.Net.Dns]::BeginGetHostAddresses($Name, $null, $null)
        $wh = $iar.AsyncWaitHandle
        if (-not $wh.WaitOne($TimeoutMs, $false)) {
            return ""
        }
        $addrs = @([System.Net.Dns]::EndGetHostAddresses($iar))
        $want = if ($ProbeAddressFamily -eq "IPv6") {
            [System.Net.Sockets.AddressFamily]::InterNetworkV6
        } else {
            [System.Net.Sockets.AddressFamily]::InterNetwork
        }
        $list = [System.Collections.Generic.List[System.Net.IPAddress]]::new()
        foreach ($a in $addrs) {
            if ($null -eq $a) { continue }
            if ($a.AddressFamily -ne $want) { continue }
            if ($ProbeAddressFamily -eq "IPv6" -and $a.IsIPv4MappedToIPv6) { continue }
            [void]$list.Add($a)
        }
        if ($list.Count -eq 0) { return "" }
        if ($ProbeAddressFamily -eq "IPv4") {
            $picked = $list.ToArray() | Sort-Object @{ Expression = {
                    $bb = $_.GetAddressBytes()
                    [uint32](([uint32]$bb[0] -shl 24) -bor ([uint32]$bb[1] -shl 16) -bor ([uint32]$bb[2] -shl 8) -bor [uint32]$bb[3])
                } } | Select-Object -First 1
            return $picked.ToString()
        }
        $picked = $list.ToArray() | Sort-Object @{ Expression = { Get-NetworkDiagIpv6AddressTier $_ } },
        @{ Expression = { -join ($_.GetAddressBytes() | ForEach-Object { "{0:x2}" -f $_ }) } } | Select-Object -First 1
        return $picked.ToString()
    } catch {
        return ""
    } finally {
        if ($null -ne $wh) {
            try { $wh.Dispose() } catch { }
        }
    }
}

function Test-NetworkDiagIsLiteralProbeIp {
    param(
        [string]$Candidate,
        [ValidateSet("IPv4", "IPv6")]
        [string]$ProbeAddressFamily
    )
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Candidate.Trim(), [ref]$ip)) { return $false }
    if ($ProbeAddressFamily -eq "IPv4") {
        return ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork)
    }
    return ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6 -and -not $ip.IsIPv4MappedToIPv6)
}

function Test-DnsResolutionDiag {
    param(
        [string]$Name,
        [int]$TimeoutMs
    )
    if (-not $Name) { return @{ Ok = $false; Ms = -1 } }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $iar = $null
    $wh = $null
    try {
        $iar = [System.Net.Dns]::BeginGetHostAddresses($Name, $null, $null)
        $wh = $iar.AsyncWaitHandle
        if (-not $wh.WaitOne($TimeoutMs, $false)) {
            try { $sw.Stop() } catch { }
            return @{ Ok = $false; Ms = -1 }
        }
        $addrs = [System.Net.Dns]::EndGetHostAddresses($iar)
        $sw.Stop()
        if ($addrs -and @($addrs).Count -gt 0) {
            return @{ Ok = $true; Ms = [int]$sw.ElapsedMilliseconds }
        }
        return @{ Ok = $false; Ms = -1 }
    } catch {
        try { $sw.Stop() } catch { }
        return @{ Ok = $false; Ms = -1 }
    } finally {
        if ($null -ne $wh) {
            try { $wh.Dispose() } catch { }
        }
    }
}

function Invoke-Tcp443Probe {
    param(
        [string]$ComputerName,
        [int]$TimeoutMs = 2500
    )
    if (-not $ComputerName) { return @{ Ok = $false; Ms = -1 } }
    $sf = $script:NetworkDiagProbeAddressFamily
    try {
        $ComputerName = Normalize-NetworkDiagProbeEndpoint -Raw $ComputerName -ProbeAddressFamily $sf -InterfaceIndex -1 -AllowHostnameOrUnresolved
    } catch {
        return @{ Ok = $false; Ms = -1 }
    }
    if (-not $ComputerName) { return @{ Ok = $false; Ms = -1 } }
    $client = $null
    $sw = [System.Diagnostics.Stopwatch]::new()
    $iar = $null
    $wh = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $sw.Start()
        $iar = $client.BeginConnect($ComputerName, 443, $null, $null)
        $wh = $iar.AsyncWaitHandle
        if (-not $wh.WaitOne($TimeoutMs, $false)) {
            try { $sw.Stop() } catch { }
            return @{ Ok = $false; Ms = -1 }
        }
        $client.EndConnect($iar)
        $sw.Stop()
        return @{ Ok = $true; Ms = [int]$sw.ElapsedMilliseconds }
    } catch {
        try { $sw.Stop() } catch { }
        return @{ Ok = $false; Ms = -1 }
    } finally {
        if ($null -ne $wh) {
            try { $wh.Dispose() } catch { }
        }
        if ($null -ne $client) {
            try { $client.Close() } catch { }
        }
    }
}

function Initialize-NetworkDiagTlsTrustAllCallback {
    <#
    Returns a [RemoteCertificateValidationCallback] that always approves
    the cert (so handshake latency reflects network + crypto, not chain
    policy). The callback is implemented as a compiled C# static method
    via Add-Type because a PowerShell scriptblock, when invoked by the
    async SslStream pipeline, runs on a threadpool thread that has no
    PowerShell Runspace attached and throws
    'no Runspace available to run scripts in this thread'. The Add-Type
    compilation happens once per session.
    #>
    $existing = Get-Variable -Scope Script -Name "NetworkDiagTlsTrustCallback" -ValueOnly -ErrorAction SilentlyContinue
    if ($existing) { return $existing }
    $src = @"
using System;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

namespace NetworkDiagTlsInternal {
    public static class Trust {
        public static bool Always(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
            return true;
        }
    }
}
"@
    if (-not ([System.Management.Automation.PSTypeName]"NetworkDiagTlsInternal.Trust").Type) {
        try {
            Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop | Out-Null
        } catch {
            return $null
        }
    }
    $t = [NetworkDiagTlsInternal.Trust]
    $mi = $t.GetMethod("Always")
    if (-not $mi) { return $null }
    $cb = [System.Net.Security.RemoteCertificateValidationCallback]::CreateDelegate([System.Net.Security.RemoteCertificateValidationCallback], $mi)
    Set-Variable -Scope Script -Name "NetworkDiagTlsTrustCallback" -Value $cb -Force
    return $cb
}

function Invoke-Tls443Probe {
    <#
    TLS handshake probe against port 443. Opens a TCP connection, wraps it
    in SslStream, runs AuthenticateAsClient with a short hard timeout, and
    reports handshake latency. Success means the full handshake completed
    with a cert chain the OS trust store accepted.

    Returns @{ Ok (bool); Ms (int; -1 on failure); TcpOk (bool); TcpMs (int) }

    The TCP leg is reported separately so callers can tell "TCP OK but TLS
    failed" (MITM / SNI filter / cert mismatch / stale clock) apart from
    "TCP failed" (network/firewall). Caller supplies a SNI hostname; if an
    IPv4/IPv6 literal comes in we send it anyway (many CDNs will answer but
    cert may not validate - expected).
    #>
    param(
        [string]$ComputerName,
        [int]$TimeoutMs = 4000
    )
    $res = @{ Ok = $false; Ms = -1; TcpOk = $false; TcpMs = -1 }
    if (-not $ComputerName) { return $res }
    $sf = $script:NetworkDiagProbeAddressFamily
    $rawHost = $ComputerName
    try {
        $rawHost = Normalize-NetworkDiagProbeEndpoint -Raw $ComputerName -ProbeAddressFamily $sf -InterfaceIndex -1 -AllowHostnameOrUnresolved
    } catch { return $res }
    if (-not $rawHost) { return $res }
    $sniHost = $ComputerName
    $client = $null
    $net = $null
    $ssl = $null
    $sw = [System.Diagnostics.Stopwatch]::new()
    $iar = $null
    $wh = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $sw.Start()
        $iar = $client.BeginConnect($rawHost, 443, $null, $null)
        $wh = $iar.AsyncWaitHandle
        if (-not $wh.WaitOne([math]::Max(500, [int]($TimeoutMs * 0.6)), $false)) {
            try { $sw.Stop() } catch { }
            return $res
        }
        $client.EndConnect($iar)
        $tcpMs = [int]$sw.ElapsedMilliseconds
        $res.TcpOk = $true
        $res.TcpMs = $tcpMs
        $client.ReceiveTimeout = $TimeoutMs
        $client.SendTimeout = $TimeoutMs
        $net = $client.GetStream()
        $cb = Initialize-NetworkDiagTlsTrustAllCallback
        if ($null -eq $cb) { return $res }
        $ssl = New-Object System.Net.Security.SslStream($net, $false, $cb)
        # .NET Framework 4.x's `SslProtocols.Default` is SSL3 | Tls (1.0). Most public
        # endpoints refuse < TLS 1.2 now - enable Tls12 (and Tls13 when the CLR knows it).
        $protoVal = 0
        try { $protoVal = $protoVal -bor [int][System.Security.Authentication.SslProtocols]::Tls12 } catch { }
        try { $protoVal = $protoVal -bor [int][System.Security.Authentication.SslProtocols]::Tls13 } catch { }
        if ($protoVal -eq 0) {
            try { $protoVal = [int][System.Security.Authentication.SslProtocols]::Tls12 } catch { $protoVal = 3072 }
        }
        $proto = [System.Security.Authentication.SslProtocols]$protoVal
        $certColl = New-Object System.Security.Cryptography.X509Certificates.X509CertificateCollection
        $swH = [System.Diagnostics.Stopwatch]::StartNew()
        $task = $ssl.AuthenticateAsClientAsync($sniHost, $certColl, $proto, $false)
        $remaining = $TimeoutMs - $tcpMs
        if ($remaining -lt 500) { $remaining = 500 }
        if (-not $task.Wait($remaining)) {
            try { $swH.Stop() } catch { }
            return $res
        }
        $swH.Stop()
        if ($task.IsFaulted -or $task.IsCanceled) { return $res }
        $res.Ok = $true
        $res.Ms = [int]$swH.ElapsedMilliseconds
        return $res
    } catch {
        return $res
    } finally {
        try { if ($sw.IsRunning) { $sw.Stop() } } catch { }
        if ($null -ne $wh) { try { $wh.Dispose() } catch { } }
        if ($null -ne $ssl) { try { $ssl.Dispose() } catch { } }
        if ($null -ne $net) { try { $net.Dispose() } catch { } }
        if ($null -ne $client) { try { $client.Close() } catch { } }
    }
}

function Invoke-IcmpProbe {
    <#
    ICMP round-trip with optional reuse of a preallocated Ping object. When
    -Ping is supplied the caller owns its lifecycle (saves 4-6 native handle
    churns per cycle across loopback/gateway/externals/underlay). Falls back
    to a fresh Ping object when no -Ping is passed.

    Returns a rich ICMP result object: MeanMs (-1 if all attempts failed),
    Attempts, Successes, MinMs, MaxMs, LossPct (0..100).
    #>
    param(
        [string]$Address,
        [int]$Count = 2,
        [int]$TimeoutSeconds = 2,
        [System.Net.NetworkInformation.Ping]$Ping
    )
    $empty = [pscustomobject]@{
        MeanMs     = -1
        Attempts   = $Count
        Successes  = 0
        MinMs      = $null
        MaxMs      = $null
        LossPct    = 100.0
    }
    if (-not $Address) { return $empty }
    $timeoutMs = [int]([math]::Max(100, $TimeoutSeconds * 1000))
    $times = [System.Collections.Generic.List[int]]::new()
    $ownPing = $false
    $p = $Ping
    try {
        if ($null -eq $p) {
            $p = New-Object System.Net.NetworkInformation.Ping
            $ownPing = $true
        }
        $opts = New-Object System.Net.NetworkInformation.PingOptions 128, $false
        $buffer = New-Object byte[] 32
        for ($pi = 0; $pi -lt $Count; $pi++) {
            try {
                $reply = $p.Send($Address, $timeoutMs, $buffer, $opts)
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success -and $reply.RoundtripTime -ge 0) {
                    [void]$times.Add([int]$reply.RoundtripTime)
                }
            } catch { }
        }
    } finally {
        if ($ownPing -and $null -ne $p) {
            try { $p.Dispose() } catch { }
        }
    }
    $succ = $times.Count
    $loss = if ($Count -gt 0) { [math]::Round(100.0 * ($Count - $succ) / [double]$Count, 1) } else { 0.0 }
    if ($succ -eq 0) {
        return [pscustomobject]@{
            MeanMs = -1; Attempts = $Count; Successes = 0; MinMs = $null; MaxMs = $null; LossPct = $loss
        }
    }
    $avg = ($times | Measure-Object -Average).Average
    $mean = [int]([math]::Round([double]$avg))
    $min = [int](($times | Measure-Object -Minimum).Minimum)
    $max = [int](($times | Measure-Object -Maximum).Maximum)
    return [pscustomobject]@{
        MeanMs = $mean; Attempts = $Count; Successes = $succ; MinMs = $min; MaxMs = $max; LossPct = $loss
    }
}

function Get-NicCounterTotals {
    param(
        [string]$AdapterName,
        [int]$InterfaceIndex = -1,
        $CachedAdapter
    )
    $z = @{ RxErr = [uint64]0; RxDisc = [uint64]0; TxErr = [uint64]0 }
    $name = $AdapterName
    if ($null -ne $CachedAdapter) {
        $name = [string]$CachedAdapter.Name
    } elseif ($InterfaceIndex -ge 0) {
        $naByIdx = Get-NetAdapter -InterfaceIndex $InterfaceIndex -ErrorAction SilentlyContinue
        if ($naByIdx) { $name = [string]$naByIdx.Name }
    }
    if (-not $name) { return $z }
    try {
        $s = Get-NetAdapterStatistics -Name $name -ErrorAction Stop
        if ($null -ne $s.ReceivedPacketErrors) {
            $z.RxErr = [uint64]$s.ReceivedPacketErrors
        } elseif ($null -ne $s.ReceivedErrors) {
            $z.RxErr = [uint64]$s.ReceivedErrors
        }
        if ($null -ne $s.ReceivedDiscardedPackets) {
            $z.RxDisc = [uint64]$s.ReceivedDiscardedPackets
        }
        if ($null -ne $s.OutboundPacketsErrors) {
            $z.TxErr = [uint64]$s.OutboundPacketsErrors
        } elseif ($null -ne $s.OutboundErrors) {
            $z.TxErr = [uint64]$s.OutboundErrors
        }
    } catch { }
    return $z
}

function Build-NetworkDiagExternalTargets {
    <#
    Given user-specified external hostnames/IPs and an address family,
    produce a normalized roster with per-entry Label / Host / IcmpTarget /
    TcpHostForProbe / ResolvedProbeIp. Keeps the entrypoint free of
    per-target plumbing and centralizes IPv6-vs-IPv4 targeting rules.
    Exits the process with code 3 on IPv6-host resolution failure (same
    contract as the original inline block).
    #>
    param(
        [Parameter(Mandatory = $true)][string[]]$ExternalIcmpHosts,
        [string[]]$ExternalIcmpLabels,
        [Parameter(Mandatory = $true)]
        [ValidateSet("IPv4", "IPv6")]
        [string]$ProbeAddressFamily,
        [Parameter(Mandatory = $true)][int]$DnsTimeoutMs,
        [switch]$PinExternalIcmpToResolvedIp
    )
    $n = $ExternalIcmpHosts.Count
    $targets = @()
    for ($ti = 0; $ti -lt $n; $ti++) {
        $h = [string]$ExternalIcmpHosts[$ti]
        $lbl = if ($null -ne $ExternalIcmpLabels -and $ExternalIcmpLabels.Count -gt $ti) {
            [string]$ExternalIcmpLabels[$ti].Trim()
        } else {
            "Ext$($ti + 1)-$h"
        }
        $isLit = Test-NetworkDiagIsLiteralProbeIp -Candidate $h -ProbeAddressFamily $ProbeAddressFamily
        $resolvedProbeIp = ""
        $icmpTarget = ""
        if ($isLit) {
            $resolvedProbeIp = Normalize-NetworkDiagProbeEndpoint -Raw $h -ProbeAddressFamily $ProbeAddressFamily -InterfaceIndex -1
            $icmpTarget = $resolvedProbeIp
        } else {
            $rawRes = Resolve-NetworkDiagHostnameForProbeFamilyWithTimeout -Name $h -TimeoutMs $DnsTimeoutMs -ProbeAddressFamily $ProbeAddressFamily
            if ($rawRes) {
                $resolvedProbeIp = Normalize-NetworkDiagProbeEndpoint -Raw $rawRes -ProbeAddressFamily $ProbeAddressFamily -InterfaceIndex -1
            }
            if ($ProbeAddressFamily -eq "IPv6" -and -not $resolvedProbeIp) {
                Write-Host "ERROR: -ExternalIcmpHosts entry '$h' could not be resolved to IPv6 for -ProbeAddressFamily IPv6." -ForegroundColor Red
                exit 3
            }
            if ($ProbeAddressFamily -eq "IPv6") {
                $icmpTarget = $resolvedProbeIp
            } elseif ($PinExternalIcmpToResolvedIp -and $resolvedProbeIp) {
                $icmpTarget = $resolvedProbeIp
            } else {
                $icmpTarget = $h
            }
        }
        $tcpHostForProbe = if ($ProbeAddressFamily -eq "IPv6" -and $resolvedProbeIp) {
            $resolvedProbeIp
        } elseif ($PinExternalIcmpToResolvedIp -and $resolvedProbeIp) {
            $resolvedProbeIp
        } else {
            $h
        }
        $targets += @{
            Name            = $lbl
            Host            = $h
            ProbeHost       = $tcpHostForProbe
            ResolvedProbeIp = $resolvedProbeIp
            IcmpTarget      = $icmpTarget
            TcpHostForProbe = $tcpHostForProbe
        }
    }
    return , $targets
}
