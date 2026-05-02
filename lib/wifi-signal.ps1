# lib/wifi-signal.ps1
# Wi-Fi signal capture. Parses `netsh wlan show interfaces` with a bounded
# timeout and extracts per-interface RF state:
#
#   Ssid, Bssid, State, RadioType, Channel, Signal (percent),
#   RxRateMbps, TxRateMbps
#
# Used when the primary bound adapter is Wi-Fi, or when the multi-NIC
# roster has a Wi-Fi entry, to separate "AP upstream is bad" from
# "RSSI collapsed / roamed / client radio state changed" quickly.
#
# Cheap: one external invocation via Start-NetworkDiagBoundedExternalProcess
# with a 5-second cap; parsing is regex on the already-collected text.

function Test-IsWirelessAdapter {
    param($Adapter)
    if (-not $Adapter) { return $false }
    $mt = [string]$Adapter.MediaType
    if ($mt -match '(?i)802\.?11|wireless|wi-?fi|wlan') { return $true }
    $desc = [string]$Adapter.InterfaceDescription
    if ($desc -match '(?i)wi-?fi|wireless') { return $true }
    $name = [string]$Adapter.Name
    if ($name -match '(?i)wi-?fi|wlan|wireless') { return $true }
    return $false
}

function Get-NetworkDiagWifiSignalRaw {
    <#
    Shell out to `netsh wlan show interfaces`, with a bounded timeout.
    Returns the raw StdOut on success, or $null on failure / timeout.
    Captured once per cycle and re-parsed per adapter of interest.
    #>
    param([int]$TimeoutSeconds = 5)
    try {
        $r = Start-NetworkDiagBoundedExternalProcess -FilePath "netsh" -ArgumentList @("wlan", "show", "interfaces") -TimeoutSeconds $TimeoutSeconds
        if ($r.Ok -and $r.StdOut) { return [string]$r.StdOut }
    } catch { }
    return $null
}

function ConvertFrom-NetworkDiagNetshWlanInterfaces {
    <#
    Split the raw netsh output into per-interface blocks and parse each
    into a hashtable. Handles the common English localization; on a
    localized Windows some keys will be empty (we keep what we got).
    Returns an array of hashtables.
    #>
    param([string]$Raw)
    $out = @()
    if (-not $Raw) { return $out }
    $lines = $Raw -split "`r?`n"
    $blocks = [System.Collections.Generic.List[System.Collections.Generic.List[string]]]::new()
    $cur = $null
    foreach ($ln in $lines) {
        if ($ln -match '^\s*Name\s*:') {
            if ($null -ne $cur -and $cur.Count -gt 0) { [void]$blocks.Add($cur) }
            $cur = [System.Collections.Generic.List[string]]::new()
        }
        if ($null -ne $cur) { [void]$cur.Add($ln) }
    }
    if ($null -ne $cur -and $cur.Count -gt 0) { [void]$blocks.Add($cur) }

    foreach ($b in $blocks) {
        $h = @{
            Name        = ""
            Ssid        = ""
            Bssid       = ""
            State       = ""
            RadioType   = ""
            Channel     = ""
            Band        = ""
            SignalPct   = $null
            RssiDbm     = $null
            RxRateMbps  = $null
            TxRateMbps  = $null
        }
        foreach ($ln in $b) {
            if ($ln -match '^\s*Name\s*:\s*(.+?)\s*$')                    { $h.Name = $matches[1]; continue }
            # SSID (but NOT BSSID / AP BSSID / BSSID type): negative lookahead excludes lines that continue with other letters after SSID.
            if ((-not $h.Ssid) -and $ln -match '^\s*SSID\s*:\s*(.+?)\s*$') { $h.Ssid = $matches[1]; continue }
            if ($ln -match '^\s*(?:AP\s+)?BSSID\s*:\s*(.+?)\s*$')          { $h.Bssid = $matches[1].ToUpperInvariant(); continue }
            if ($ln -match '^\s*State\s*:\s*(.+?)\s*$')                   { $h.State = $matches[1]; continue }
            if ($ln -match '^\s*Radio\s+type\s*:\s*(.+?)\s*$')            { $h.RadioType = $matches[1]; continue }
            if ($ln -match '^\s*Channel\s*:\s*(.+?)\s*$')                 { $h.Channel = $matches[1]; continue }
            if ($ln -match '^\s*Band\s*:\s*(.+?)\s*$')                    { $h.Band = $matches[1]; continue }
            if ($ln -match '^\s*Signal\s*:\s*(\d+)\s*%') {
                try { $h.SignalPct = [int]$matches[1] } catch { }
                continue
            }
            if ($ln -match '^\s*Rssi\s*:\s*(-?\d+)') {
                try { $h.RssiDbm = [int]$matches[1] } catch { }
                continue
            }
            if ($ln -match '^\s*Receive\s+rate\s*\(Mbps\)\s*:\s*([\d.]+)') {
                try { $h.RxRateMbps = [double]$matches[1] } catch { }
                continue
            }
            if ($ln -match '^\s*Transmit\s+rate\s*\(Mbps\)\s*:\s*([\d.]+)') {
                try { $h.TxRateMbps = [double]$matches[1] } catch { }
                continue
            }
        }
        if ($h.Name -or $h.Bssid) { $out += , $h }
    }
    return , $out
}

function Get-NetworkDiagWifiSignalForAdapter {
    <#
    Look up a previously parsed netsh snapshot by adapter name (case-
    insensitive) and return a hashtable normalized for CSV use:
      { Available, Ssid, Bssid, State, RadioType, Channel,
        SignalPct, RxRateMbps, TxRateMbps }
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AdapterName,
        $ParsedBlocks
    )
    $empty = @{
        Available  = $false
        Ssid       = ""
        Bssid      = ""
        State      = ""
        RadioType  = ""
        Channel    = ""
        Band       = ""
        SignalPct  = $null
        RssiDbm    = $null
        RxRateMbps = $null
        TxRateMbps = $null
    }
    if (-not $ParsedBlocks -or -not $AdapterName) { return $empty }
    foreach ($h in $ParsedBlocks) {
        if ([string]$h.Name -and ([string]$h.Name).Trim().ToLowerInvariant() -eq $AdapterName.Trim().ToLowerInvariant()) {
            return @{
                Available  = $true
                Ssid       = [string]$h.Ssid
                Bssid      = [string]$h.Bssid
                State      = [string]$h.State
                RadioType  = [string]$h.RadioType
                Channel    = [string]$h.Channel
                Band       = [string]$h.Band
                SignalPct  = $h.SignalPct
                RssiDbm    = $h.RssiDbm
                RxRateMbps = $h.RxRateMbps
                TxRateMbps = $h.TxRateMbps
            }
        }
    }
    return $empty
}

function Format-NetworkDiagWifiCsvFields {
    <#
    Flatten a Wi-Fi snapshot hashtable into CSV-safe string columns.
    Returns @{ WifiSsid; WifiBssid; WifiSignal; WifiRadio; WifiChannel }.
    Values commas/quotes are replaced; missing-or-off becomes "na".
    #>
    param($Snap)
    if (-not $Snap -or -not $Snap.Available) {
        return @{
            WifiSsid    = "na"
            WifiBssid   = "na"
            WifiSignal  = "na"
            WifiRadio   = "na"
            WifiChannel = "na"
        }
    }
    $safe = {
        param($s)
        if ($null -eq $s -or "$s" -eq "") { return "" }
        ([string]$s) -replace '[\r\n]', ' ' -replace ',', ';'
    }
    $sig = if ($null -ne $Snap.SignalPct) { "$([int]$Snap.SignalPct)%" } else { "na" }
    return @{
        WifiSsid    = if ($Snap.Ssid) { & $safe $Snap.Ssid } else { "na" }
        WifiBssid   = if ($Snap.Bssid) { & $safe $Snap.Bssid } else { "na" }
        WifiSignal  = $sig
        WifiRadio   = if ($Snap.RadioType) { & $safe $Snap.RadioType } else { "na" }
        WifiChannel = if ($Snap.Channel) { & $safe $Snap.Channel } else { "na" }
    }
}

function Update-NetworkDiagWifiStats {
    <#
    Fold a per-cycle Wi-Fi snapshot into the run-level stats bag. Tracks
    min/avg signal, a bounded set of unique BSSIDs (roaming indicator),
    the most recent snapshot, and counts cycles where Wi-Fi was seen.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Stats,
        $Snap,
        [string]$ContextTag = "primary"
    )
    if (-not $Snap -or -not $Snap.Available) { return }
    if (-not $Stats.ContainsKey("WifiCapturedCycles")) {
        $Stats["WifiCapturedCycles"]  = 0
        $Stats["WifiSignalSumPct"]    = 0.0
        $Stats["WifiSignalSamples"]   = 0
        $Stats["WifiSignalMinPct"]    = $null
        $Stats["WifiSignalMaxPct"]    = $null
        $Stats["WifiUniqueBssids"]    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $Stats["WifiBssidChangeCycles"] = 0
        $Stats["WifiLastBssid"]       = ""
        $Stats["WifiLastSsid"]        = ""
        $Stats["WifiLastSignalPct"]   = $null
        $Stats["WifiLastRadio"]       = ""
        $Stats["WifiLastChannel"]     = ""
        $Stats["WifiLastContext"]     = ""
        $Stats["WifiBssidsCappedAt"]  = 0
    }
    $Stats["WifiCapturedCycles"] = [int]$Stats["WifiCapturedCycles"] + 1
    if ($null -ne $Snap.SignalPct) {
        $p = [int]$Snap.SignalPct
        $Stats["WifiSignalSumPct"] = [double]$Stats["WifiSignalSumPct"] + $p
        $Stats["WifiSignalSamples"] = [int]$Stats["WifiSignalSamples"] + 1
        if ($null -eq $Stats["WifiSignalMinPct"] -or $p -lt [int]$Stats["WifiSignalMinPct"]) {
            $Stats["WifiSignalMinPct"] = $p
        }
        if ($null -eq $Stats["WifiSignalMaxPct"] -or $p -gt [int]$Stats["WifiSignalMaxPct"]) {
            $Stats["WifiSignalMaxPct"] = $p
        }
    }
    if ($Snap.Bssid) {
        $b = [string]$Snap.Bssid
        $set = $Stats["WifiUniqueBssids"]
        if ($set.Contains($b) -or $set.Count -lt 256) {
            [void]$set.Add($b)
        } else {
            $Stats["WifiBssidsCappedAt"] = 256
        }
        $prev = [string]$Stats["WifiLastBssid"]
        if ($prev -and $prev -ne $b) {
            $Stats["WifiBssidChangeCycles"] = [int]$Stats["WifiBssidChangeCycles"] + 1
        }
        $Stats["WifiLastBssid"] = $b
    }
    $Stats["WifiLastSsid"] = [string]$Snap.Ssid
    $Stats["WifiLastSignalPct"] = $Snap.SignalPct
    $Stats["WifiLastRadio"] = [string]$Snap.RadioType
    $Stats["WifiLastChannel"] = [string]$Snap.Channel
    $Stats["WifiLastContext"] = $ContextTag
}
