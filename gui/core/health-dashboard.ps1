function New-NetworkDiagGuiLiveHealthState {
    return @{
        TrendWindow = 20
        CycleCount = 0
        OkCount = 0
        IspFaultCount = 0
        LocalFaultCount = 0
        AnomalyCount = 0
        LastVerdict = "n/a"
        DnsStatus = "n/a"
        GatewayStatus = "n/a"
        ExternalStatus = "n/a"
        TcpTlsStatus = "n/a"
        Severity = "n/a"
        DnsTrend = [System.Collections.Generic.List[int]]::new()
        GatewayTrend = [System.Collections.Generic.List[int]]::new()
        ExternalTrend = [System.Collections.Generic.List[int]]::new()
        TcpTrend = [System.Collections.Generic.List[int]]::new()
        LastUpdate = "n/a"
    }
}

function Get-NetworkDiagGuiStatusBrush {
    param([string]$Status)
    $s = [string]$Status
    if ($s -match "^(OK|PASS)") { return "DarkGreen" }
    if ($s -match "^(DEGRADED|WARN|WARNING|MIXED)") { return "DarkGoldenrod" }
    if ($s -match "^(n/a|N/A|WAITING)") { return "DimGray" }
    return "DarkRed"
}

function Add-NetworkDiagGuiTrendPoint {
    param(
        [System.Collections.Generic.List[int]]$Series,
        [int]$Value,
        [int]$Window
    )
    $Series.Add($Value)
    while ($Series.Count -gt $Window) {
        $Series.RemoveAt(0)
    }
}

function ConvertTo-NetworkDiagGuiTrendScore {
    param([string]$Status)
    $s = [string]$Status
    if ($s -match "^(OK|PASS)") { return 1 }
    if ($s -match "^(n/a|N/A|WAITING)$") { return -1 }
    return 0
}

function Get-NetworkDiagGuiTrendPercentText {
    param([System.Collections.Generic.List[int]]$Series)
    $valid = @($Series | Where-Object { $_ -ge 0 })
    if ($valid.Count -eq 0) { return "n/a" }
    $pass = @($valid | Where-Object { $_ -eq 1 }).Count
    $pct = [math]::Round((100.0 * $pass / $valid.Count), 0)
    return "$pct%"
}

function Get-NetworkDiagGuiSeverity {
    param([hashtable]$Health)
    if ($Health.LastVerdict -and $Health.LastVerdict -ne "n/a" -and $Health.LastVerdict -ne "OK") { return "CRITICAL" }
    foreach ($v in @($Health.DnsStatus, $Health.GatewayStatus, $Health.ExternalStatus, $Health.TcpTlsStatus)) {
        if ([string]$v -match "FAIL") { return "CRITICAL" }
    }
    foreach ($v in @($Health.DnsStatus, $Health.GatewayStatus, $Health.ExternalStatus, $Health.TcpTlsStatus)) {
        if ([string]$v -match "DEGRADED") { return "WARN" }
    }
    if ([int]$Health.IspFaultCount -gt 0 -or [int]$Health.LocalFaultCount -gt 0 -or [int]$Health.AnomalyCount -gt 0) { return "WARN" }
    if ([int]$Health.CycleCount -gt 0) { return "OK" }
    return "n/a"
}

function Reset-NetworkDiagGuiLiveHealth {
    $script:App.Health = New-NetworkDiagGuiLiveHealthState
    $controls = $script:App.Ui.Controls
    $window = $script:App.Ui.Window
    $window.Dispatcher.Invoke([Action]{
        $controls.HealthRunVerdict.Text = "Verdict: n/a"
        $controls.HealthRunVerdict.Foreground = "DimGray"
        $controls.HealthDns.Text = "DNS: n/a"
        $controls.HealthDns.Foreground = "DimGray"
        $controls.HealthGateway.Text = "Gateway: n/a"
        $controls.HealthGateway.Foreground = "DimGray"
        $controls.HealthExternal.Text = "External: n/a"
        $controls.HealthExternal.Foreground = "DimGray"
        $controls.HealthTcp.Text = "TCP/TLS: n/a"
        $controls.HealthTcp.Foreground = "DimGray"
        $controls.HealthCycles.Text = "Cycles: 0"
        $controls.HealthLastUpdate.Text = "Last update: n/a"
        $controls.HealthSeverity.Text = "Severity: n/a"
        $controls.HealthSeverity.Foreground = "DimGray"
        $controls.HealthTrend.Text = "Trend(20): DNS=n/a GW=n/a EXT=n/a TCP=n/a"
        $controls.HealthTrend.Foreground = "DimGray"
    })
}

function Update-NetworkDiagGuiHealthUi {
    $h = $script:App.Health
    $controls = $script:App.Ui.Controls
    $window = $script:App.Ui.Window
    $dnsTrend = Get-NetworkDiagGuiTrendPercentText -Series $h.DnsTrend
    $gwTrend = Get-NetworkDiagGuiTrendPercentText -Series $h.GatewayTrend
    $extTrend = Get-NetworkDiagGuiTrendPercentText -Series $h.ExternalTrend
    $tcpTrend = Get-NetworkDiagGuiTrendPercentText -Series $h.TcpTrend
    $h.Severity = Get-NetworkDiagGuiSeverity -Health $h
    $window.Dispatcher.Invoke([Action]{
        $controls.HealthRunVerdict.Text = "Verdict: $($h.LastVerdict)"
        $controls.HealthRunVerdict.Foreground = Get-NetworkDiagGuiStatusBrush -Status $h.LastVerdict
        $controls.HealthDns.Text = "DNS: $($h.DnsStatus)"
        $controls.HealthDns.Foreground = Get-NetworkDiagGuiStatusBrush -Status $h.DnsStatus
        $controls.HealthGateway.Text = "Gateway: $($h.GatewayStatus)"
        $controls.HealthGateway.Foreground = Get-NetworkDiagGuiStatusBrush -Status $h.GatewayStatus
        $controls.HealthExternal.Text = "External: $($h.ExternalStatus)"
        $controls.HealthExternal.Foreground = Get-NetworkDiagGuiStatusBrush -Status $h.ExternalStatus
        $controls.HealthTcp.Text = "TCP/TLS: $($h.TcpTlsStatus)"
        $controls.HealthTcp.Foreground = Get-NetworkDiagGuiStatusBrush -Status $h.TcpTlsStatus
        $controls.HealthCycles.Text = "Cycles: $($h.CycleCount) | OK=$($h.OkCount) ISP=$($h.IspFaultCount) Local=$($h.LocalFaultCount) Anomaly=$($h.AnomalyCount)"
        $controls.HealthLastUpdate.Text = "Last update: $($h.LastUpdate)"
        $controls.HealthSeverity.Text = "Severity: $($h.Severity)"
        $controls.HealthSeverity.Foreground = Get-NetworkDiagGuiStatusBrush -Status $h.Severity
        $controls.HealthTrend.Text = "Trend($($h.TrendWindow)): DNS=$dnsTrend GW=$gwTrend EXT=$extTrend TCP=$tcpTrend"
        $controls.HealthTrend.Foreground = "SlateGray"
    })
}

function Update-NetworkDiagGuiHealthFromLine {
    param([string]$Line)
    if (-not $Line) { return }
    $text = [string]$Line
    $h = $script:App.Health

    $hasCycle = $false
    if ($text -match "Verdict=([A-Z_]+)") {
        $verdict = $Matches[1]
        $hasCycle = $true
        $h.CycleCount = [int]$h.CycleCount + 1
        $h.LastVerdict = $verdict
        if ($verdict -eq "OK") {
            $h.OkCount = [int]$h.OkCount + 1
        } elseif ($verdict -match "ISP") {
            $h.IspFaultCount = [int]$h.IspFaultCount + 1
        } elseif ($verdict -match "LOCAL") {
            $h.LocalFaultCount = [int]$h.LocalFaultCount + 1
        } else {
            $h.AnomalyCount = [int]$h.AnomalyCount + 1
        }
    }

    if ($text -match "DNS=DNS:([\-0-9]+)ms") {
        $dns = [int]$Matches[1]
        $h.DnsStatus = if ($dns -ge 0) { "OK (${dns}ms)" } else { "FAIL" }
    } elseif ($text -match "DNS=(na|NA)") {
        $h.DnsStatus = "n/a"
    }

    if ($text -match "\bGW=([\-0-9]+)ms\b") {
        $gw = [int]$Matches[1]
        $h.GatewayStatus = if ($gw -ge 0) { "OK (${gw}ms)" } else { "FAIL" }
    } elseif ($text -match "\bGW=(na|NA)\b") {
        $h.GatewayStatus = "n/a"
    }

    if ($text -match "EXT=(.+?)\s+DNS=") {
        $extSegment = $Matches[1]
        if ($extSegment -match ":-1ms|:na|:NA") {
            $h.ExternalStatus = "DEGRADED"
        } else {
            $h.ExternalStatus = "OK"
        }
    }

    if ($text -match "TCP_CF_ms=([\-0-9a-zA-Z]+)\s+TCP_GG_ms=([\-0-9a-zA-Z]+)") {
        $cf = $Matches[1]
        $gg = $Matches[2]
        if ($cf -eq "na" -or $gg -eq "na") {
            $h.TcpTlsStatus = "n/a"
        } elseif ([int]$cf -ge 0 -and [int]$gg -ge 0) {
            $h.TcpTlsStatus = "OK"
        } else {
            $h.TcpTlsStatus = "FAIL"
        }
    }

    if ($text -match "TLS_.*=-1") {
        $h.TcpTlsStatus = "DEGRADED"
    }

    if ($hasCycle) {
        Add-NetworkDiagGuiTrendPoint -Series $h.DnsTrend -Value (ConvertTo-NetworkDiagGuiTrendScore -Status $h.DnsStatus) -Window ([int]$h.TrendWindow)
        Add-NetworkDiagGuiTrendPoint -Series $h.GatewayTrend -Value (ConvertTo-NetworkDiagGuiTrendScore -Status $h.GatewayStatus) -Window ([int]$h.TrendWindow)
        Add-NetworkDiagGuiTrendPoint -Series $h.ExternalTrend -Value (ConvertTo-NetworkDiagGuiTrendScore -Status $h.ExternalStatus) -Window ([int]$h.TrendWindow)
        Add-NetworkDiagGuiTrendPoint -Series $h.TcpTrend -Value (ConvertTo-NetworkDiagGuiTrendScore -Status $h.TcpTlsStatus) -Window ([int]$h.TrendWindow)
    }

    $h.LastUpdate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Invoke-NetworkDiagGuiHook -Hooks $script:App.Hooks -EventName "CycleObserved" -Payload @{ Line = $text; Health = $h }
    Update-NetworkDiagGuiHealthUi
}
