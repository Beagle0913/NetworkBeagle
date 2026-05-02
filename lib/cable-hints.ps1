# lib/cable-hints.ps1
# Cable / NIC physical-layer hints. Software cannot prove a bad cable
# vs a bad NIC vs a driver bug - these codes are correlated hints only:
#
#   LINK_DEGRADED            current LinkSpeed stuck <=50% of baseline for 3+ consecutive cycles
#   LINK_FLAP                NDIS media-disconnect event on the routed NIC since last check
#   CABLE_SUSPECT            recent cycles also had NIC error deltas + LINK_* flags
#   CABLE_DIAG_<key>=<value> vendor advanced-property exposing a Cable*/Diagnostic* key
#   CABLE_DIAG_UNAVAILABLE   driver exposes nothing relevant (emitted once per run)

function Get-NetworkDiagCableBaseline {
    param($Adapter)
    $b = @{
        Adapter    = if ($Adapter) { [string]$Adapter.Name } else { "" }
        LinkMbps   = $null
        Configured = $null
        Ts         = [datetime]::UtcNow
    }
    if (-not $Adapter) { return $b }
    $b.LinkMbps = ConvertTo-LinkMbps $Adapter.LinkSpeed
    try {
        $adv = @(Get-NetAdapterAdvancedProperty -Name $Adapter.Name -ErrorAction SilentlyContinue)
        foreach ($p in $adv) {
            if ([string]$p.DisplayName -match '(?i)speed.*duplex|link\s*speed') {
                $b.Configured = [string]$p.DisplayValue
                break
            }
        }
    } catch { }
    return $b
}

function Get-NetworkDiagCableHints {
    param(
        $Adapter,
        [hashtable]$Baseline,
        [datetime]$RunStart,
        [hashtable]$State,
        [string]$Now,
        [int64]$DRxErr = 0,
        [int64]$DRxDisc = 0,
        [int64]$DTxErr = 0
    )
    $codes = [System.Collections.Generic.List[string]]::new()
    $details = @{}
    if (-not $Adapter) {
        return @{ HintCodes = @($codes); Details = $details }
    }

    $currentMbps = ConvertTo-LinkMbps $Adapter.LinkSpeed
    $baseMbps = if ($Baseline) { $Baseline.LinkMbps } else { $null }
    $degradedThisCycle = $false
    if ($null -ne $baseMbps -and $null -ne $currentMbps -and $baseMbps -gt 0) {
        if (([double]$currentMbps * 2.0) -le [double]$baseMbps) {
            $degradedThisCycle = $true
        }
    }
    if ($degradedThisCycle) {
        $State.CableConsecutiveDegradeCycles = [int]$State.CableConsecutiveDegradeCycles + 1
    } else {
        $State.CableConsecutiveDegradeCycles = 0
    }
    if ([int]$State.CableConsecutiveDegradeCycles -ge 3) {
        [void]$codes.Add("LINK_DEGRADED")
        $details["LINK_DEGRADED"] = "current=${currentMbps}Mbps baseline=${baseMbps}Mbps"
    }

    try {
        $startTime = if ($State.LastLinkFlapCheckUtc) { [datetime]$State.LastLinkFlapCheckUtc } elseif ($RunStart) { [datetime]$RunStart } else { (Get-Date).AddMinutes(-5) }
        $State.LastLinkFlapCheckUtc = [datetime]::UtcNow
        $hash = @{ LogName = "System"; ProviderName = "Microsoft-Windows-NDIS"; Id = @(27, 10317); StartTime = $startTime }
        $ev = @(Get-WinEvent -FilterHashtable $hash -MaxEvents 5 -ErrorAction SilentlyContinue)
        if ($ev -and $ev.Count -gt 0) {
            if ($Adapter.MacAddress) {
                $mac = [string]$Adapter.MacAddress
                $hit = @($ev | Where-Object { ($_.Message -and ($_.Message -match [regex]::Escape($mac))) })
                if ($hit -and $hit.Count -gt 0) {
                    [void]$codes.Add("LINK_FLAP")
                    $details["LINK_FLAP"] = "count=$($hit.Count) latest=$($hit[0].TimeCreated)"
                }
            }
        }
    } catch { }

    $sawVendorKey = $false
    try {
        $adv = @(Get-NetAdapterAdvancedProperty -Name $Adapter.Name -ErrorAction SilentlyContinue)
        foreach ($p in $adv) {
            $k = [string]$p.DisplayName
            if ($k -match '(?i)cable|diagnostic') {
                $sawVendorKey = $true
                $safeK = ($k -replace '\s+', '_') -replace '[,=]', '_'
                $safeV = ([string]$p.DisplayValue) -replace '[,=]', '_'
                [void]$codes.Add("CABLE_DIAG_${safeK}=${safeV}")
            }
        }
    } catch { }
    if (-not $sawVendorKey -and -not $State.CableDiagUnavailableLogged) {
        [void]$codes.Add("CABLE_DIAG_UNAVAILABLE")
        $State.CableDiagUnavailableLogged = $true
    }

    if ((($DRxErr + $DRxDisc + $DTxErr) -gt 0) -and
        ($codes -contains "LINK_DEGRADED" -or $codes -contains "LINK_FLAP")) {
        [void]$codes.Add("CABLE_SUSPECT")
        $details["CABLE_SUSPECT"] = "NIC deltas + LINK_* in this cycle"
    }

    return @{ HintCodes = @($codes); Details = $details }
}
