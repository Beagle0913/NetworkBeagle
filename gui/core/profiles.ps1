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

function Save-NetworkDiagGuiConfig {
    param([hashtable]$State)
    $cfgPath = Join-Path $env:TEMP ("networkdiag_gui_state_" + [guid]::NewGuid().ToString("N") + ".json")
    $json = $State | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($cfgPath, $json, (New-Object System.Text.UTF8Encoding $false))
    return $cfgPath
}
