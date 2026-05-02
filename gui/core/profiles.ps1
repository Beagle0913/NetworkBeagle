function Get-NetworkDiagGuiPresets {
    param([hashtable]$BaseState)
    $quick = @{}
    foreach ($k in $BaseState.Keys) { $quick[$k] = $BaseState[$k] }
    $quick.MonitoringMode = "ShortRun"
    $quick.DurationMinutes = 20
    $quick.IntervalSeconds = 3
    $quick.DetailLog = $true
    $quick.BurstOnFault = $true

    $long = @{}
    foreach ($k in $BaseState.Keys) { $long[$k] = $BaseState[$k] }
    $long.MonitoringMode = "LongRun"
    $long.DurationMinutes = 480
    $long.IntervalSeconds = 5
    $long.DetailLog = $true
    $long.BurstOnFault = $true
    $long.BurstCycles = 10

    $isp = @{}
    foreach ($k in $BaseState.Keys) { $isp[$k] = $BaseState[$k] }
    $isp.MonitoringMode = "LongRun"
    $isp.DurationMinutes = 240
    $isp.DetailLog = $true
    $isp.IspEvidenceZip = $true
    $isp.SkipIspEvidencePacket = $false
    $isp.EnableTlsProbe = $true
    $isp.SkipJsonSummary = $false
    $isp.BurstOnFault = $true

    return [ordered]@{
        "Quick Smoke (20m)" = $quick
        "Long Soak (8h)" = $long
        "ISP Escalation (4h)" = $isp
    }
}

function Get-NetworkDiagGuiGoalProfiles {
    param([hashtable]$BaseState)

    $quick = @{}
    foreach ($k in $BaseState.Keys) { $quick[$k] = $BaseState[$k] }
    $quick.DurationMinutes = 5
    $quick.IntervalSeconds = 3
    $quick.MonitoringMode = "ShortRun"
    $quick.BurstOnFault = $false
    $quick.EnableTlsProbe = $false
    $quick.SkipJsonSummary = $false
    $quick.DetailLog = $false

    $wifi = @{}
    foreach ($k in $BaseState.Keys) { $wifi[$k] = $BaseState[$k] }
    $wifi.DurationMinutes = 30
    $wifi.IntervalSeconds = 3
    $wifi.MonitoringMode = "ShortRun"
    $wifi.BurstOnFault = $true
    $wifi.SkipWifiSignal = $false
    $wifi.RoutingRefreshIntervalCycles = 30
    $wifi.EnableTlsProbe = $true

    $dns = @{}
    foreach ($k in $BaseState.Keys) { $dns[$k] = $BaseState[$k] }
    $dns.DurationMinutes = 15
    $dns.IntervalSeconds = 3
    $dns.MonitoringMode = "ShortRun"
    $dns.SkipDnsProbe = $false
    $dns.DnsProbeName = "cloudflare.com"
    $dns.EnableTlsProbe = $false
    $dns.DetailLog = $true

    $isp = @{}
    foreach ($k in $BaseState.Keys) { $isp[$k] = $BaseState[$k] }
    $isp.DurationMinutes = 120
    $isp.IntervalSeconds = 5
    $isp.MonitoringMode = "LongRun"
    $isp.BurstOnFault = $true
    $isp.BurstCycles = 10
    $isp.EnableTlsProbe = $true
    $isp.SkipIspEvidencePacket = $false
    $isp.IspEvidenceZip = $true
    $isp.DetailLog = $true

    $vpn = @{}
    foreach ($k in $BaseState.Keys) { $vpn[$k] = $BaseState[$k] }
    $vpn.DurationMinutes = 45
    $vpn.IntervalSeconds = 4
    $vpn.MonitoringMode = "LongRun"
    $vpn.PathMtuProbeTarget = "1.1.1.1"
    $vpn.RoutingRefreshIntervalCycles = 20
    $vpn.EnableTlsProbe = $true
    $vpn.DetailLog = $true

    return [ordered]@{
        quick = @{
            Name = "Quick internet sanity check"
            ProfileState = $quick
            Notes = "2-5 minutes, checks DNS, gateway, and external connectivity."
            AdminRecommended = $false
        }
        wifi = @{
            Name = "Wi-Fi / router instability"
            ProfileState = $wifi
            Notes = "Longer run with burst-on-fault and route refresh."
            AdminRecommended = $true
        }
        dns = @{
            Name = "DNS problems"
            ProfileState = $dns
            Notes = "DNS-focused checks and timing visibility."
            AdminRecommended = $false
        }
        isp = @{
            Name = "ISP / packet loss investigation"
            ProfileState = $isp
            Notes = "Long-run external monitoring for support evidence."
            AdminRecommended = $true
        }
        vpn = @{
            Name = "VPN / MTU / routing issue"
            ProfileState = $vpn
            Notes = "Path MTU + route-refresh focused profile."
            AdminRecommended = $true
        }
        custom = @{
            Name = "Custom expert run"
            ProfileState = $BaseState
            Notes = "Keep current settings and tune in Advanced."
            AdminRecommended = $false
        }
    }
}

function Apply-NetworkDiagGuiGoalPreset {
    param(
        [Parameter(Mandatory = $true)][string]$GoalId,
        [Parameter(Mandatory = $true)][hashtable]$Controls,
        [Parameter(Mandatory = $true)][hashtable]$GoalProfiles
    )
    if (-not $GoalProfiles.Contains($GoalId)) {
        throw "Unknown goal preset: $GoalId"
    }
    $profile = $GoalProfiles[$GoalId]
    $state = Merge-NetworkDiagGuiState -Overrides $profile.ProfileState
    Set-NetworkDiagGuiControlState -Controls $Controls -State $state
    return $profile
}

function Save-NetworkDiagGuiConfig {
    param([hashtable]$State)
    $cfgPath = Join-Path $env:TEMP ("networkdiag_gui_state_" + [guid]::NewGuid().ToString("N") + ".json")
    Write-NetworkDiagGuiStateDocument -Path $cfgPath -State $State
    return $cfgPath
}
