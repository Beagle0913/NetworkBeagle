#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-TestCycleVerdictState {
    return @{
        NormalGwPolicyState = "Inactive"
        NormalGwPolicyStreak = 0
        NormalGwPolicyArmedAt = $null
    }
}

function New-TestCycleVerdictProbes {
    param(
        [bool]$GwOk = $true,
        [bool]$ExtOk = $true,
        [bool]$DoTcp = $true,
        [bool]$TcpExtOk = $true,
        [int]$ExtCount = 3,
        [int]$ExtUnreachable = 0,
        [int]$LbMs = 1
    )
    return @{
        GwOk = $GwOk
        ExtOk = $ExtOk
        ExtOkCount = if ($ExtOk) { $ExtCount } else { 0 }
        ExtCount = $ExtCount
        ExtUnreachable = $ExtUnreachable
        TcpExtOk = $TcpExtOk
        DoTcp = $DoTcp
        LbMs = $LbMs
    }
}

function New-TestCycleVerdictContext {
    param(
        [string]$RoutingContext = "Normal",
        [bool]$SkipGwIcmpPolicy = $false,
        [bool]$DnsOk = $true
    )
    return @{
        RoutingContext = $RoutingContext
        UnderlayAvailable = $false
        LanGwMs = $null
        LanStatus = "na"
        LanDeltaSum = 0
        LanDRe = 0
        LanDRd = 0
        LanDTe = 0
        GwResult = 1
        EthStatus = "Up"
        DRxErr = 0
        DRxDisc = 0
        DTxErr = 0
        DeltaSum = 0
        DnsOk = $DnsOk
        SkipDnsProbe = $false
        LinkSpeedChanged = $false
        SkipGwIcmpPolicy = $SkipGwIcmpPolicy
        Now = "2026-05-03 00:00:00.000"
        GwIcmpPolicyConfirmCycles = 3
        NaRefreshPresent = $true
    }
}

function New-TestRoutingIdentity {
    param(
        [string]$Gateway = "192.168.1.1",
        [string]$RouteIfIndex = "5",
        [string]$RoutingContext = "Normal",
        [string]$UnderlayIfIndex = "na",
        [string]$ProbeAddressFamily = "IPv4"
    )
    return @{
        gateway = $Gateway
        routeIfIndex = $RouteIfIndex
        routingContext = $RoutingContext
        underlayIfIndex = $UnderlayIfIndex
        routedAdapter = "Ethernet"
        probeAddressFamily = $ProbeAddressFamily
    }
}
