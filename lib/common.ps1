# lib/common.ps1
# Foundational helpers: admin detection, bounded external-process wrapper,
# path/folder resolution, abort + emergency writers, small predicates used
# across the rest of the diagnostic.
#
# All functions are PS 5.1 compatible and have no side effects at load time.

function Test-NetworkDiagIsAdmin {
    <#
    Returns $true if the current process is running elevated (member of the
    built-in Administrators role). Caches the result on $script:IsAdmin so
    repeat calls are O(1).
    #>
    if ($null -ne $script:IsAdmin) { return [bool]$script:IsAdmin }
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
        $script:IsAdmin = $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        $script:IsAdmin = $false
    }
    return [bool]$script:IsAdmin
}

function Start-NetworkDiagBoundedExternalProcess {
    <#
    Run a short external command with a hard timeout. Returns a hashtable:
      { Ok (bool), StdOut (string), StdErr (string), ExitCode (int), TimedOut (bool), Elapsed (double sec), Reason (string) }

    Chosen design: Start-Job + Wait-Job -Timeout. Slower startup than raw
    Process.Start() but cleanly cancellable and available on stock PS 5.1.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [ValidateRange(1, 3600)]
        [int]$TimeoutSeconds = 30
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $job = $null
    try {
        $job = Start-Job -ScriptBlock {
            param($fp, $al)
            $ErrorActionPreference = 'Stop'
            try {
                if ($al -and $al.Count -gt 0) {
                    $out = & $fp @al 2>&1
                } else {
                    $out = & $fp 2>&1
                }
                [pscustomobject]@{
                    Ok       = $true
                    StdOut   = ($out | Out-String)
                    StdErr   = ""
                    ExitCode = [int]$LASTEXITCODE
                }
            } catch {
                [pscustomobject]@{
                    Ok       = $false
                    StdOut   = ""
                    StdErr   = [string]$_.Exception.Message
                    ExitCode = -1
                }
            }
        } -ArgumentList $FilePath, $ArgumentList
        $finished = Wait-Job -Job $job -Timeout $TimeoutSeconds
        if (-not $finished) {
            try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch { }
            try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { }
            $sw.Stop()
            return @{
                Ok = $false; StdOut = ""; StdErr = "TIMEOUT after ${TimeoutSeconds}s";
                ExitCode = -1; TimedOut = $true; Elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 3); Reason = "Timeout"
            }
        }
        $result = Receive-Job -Job $job -ErrorAction SilentlyContinue
        try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { }
        $sw.Stop()
        if ($null -eq $result) {
            return @{
                Ok = $false; StdOut = ""; StdErr = "No output from job";
                ExitCode = -1; TimedOut = $false; Elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 3); Reason = "NoOutput"
            }
        }
        $reason = "Ok"
        $ok = [bool]$result.Ok
        $exitCode = [int]$result.ExitCode
        $stdErr = [string]$result.StdErr
        if (-not $ok) {
            $reason = "Exception"
            if ($stdErr -match '(?i)(not recognized as the name|cannot find path|was not found|No such file)') {
                $reason = "StartFailed"
            }
        } elseif ($exitCode -ne 0) {
            $ok = $false
            $reason = "NonZeroExit"
        }
        return @{
            Ok       = $ok
            StdOut   = [string]$result.StdOut
            StdErr   = $stdErr
            ExitCode = $exitCode
            TimedOut = $false
            Elapsed  = [math]::Round($sw.Elapsed.TotalSeconds, 3)
            Reason   = $reason
        }
    } catch {
        try { if ($null -ne $job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } } catch { }
        $sw.Stop()
        return @{
            Ok = $false; StdOut = ""; StdErr = [string]$_.Exception.Message;
            ExitCode = -1; TimedOut = $false; Elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 3); Reason = "Exception"
        }
    }
}

function Test-NetworkDiagFolderWritable {
    param([string]$Path)
    if (-not $Path) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
        }
        $probe = Join-Path $Path (".writeprobe_" + [Guid]::NewGuid().ToString("n") + ".tmp")
        $enc = New-Object System.Text.UTF8Encoding $false
        $sw = New-Object System.IO.StreamWriter($probe, $false, $enc)
        $sw.Write("ok")
        $sw.Flush()
        $sw.Dispose()
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

function Get-NormalizedPathKey {
    param([string]$p)
    if (-not $p) { return "" }
    try {
        return [System.IO.Path]::GetFullPath($p.Trim()).TrimEnd('\', '/').ToLowerInvariant()
    } catch {
        return $p.Trim().ToLowerInvariant()
    }
}

function Resolve-NetworkDiagOutputFolder {
    param([string]$UserSpecifiedFolder)
    $candidates = @()
    if ($UserSpecifiedFolder) {
        $candidates += @{ Path = $UserSpecifiedFolder.Trim(); Label = "UserSpecified" }
    }
    if ($PSScriptRoot) {
        $sr = $PSScriptRoot.Trim()
        if ($sr) {
            $candidates += @{ Path = $sr; Label = "ScriptRoot" }
        }
    }
    $candidates += @{ Path = (Join-Path ([Environment]::GetFolderPath("Desktop")) "NetworkTest"); Label = "DesktopNetworkTest" }
    $candidates += @{ Path = (Join-Path $env:TEMP "NetworkTest"); Label = "TempNetworkTest" }

    $seen = @{}
    $ordered = @()
    foreach ($c in $candidates) {
        if (-not $c.Path) { continue }
        $key = Get-NormalizedPathKey $c.Path
        if (-not $key) { continue }
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $ordered += @{ Path = $c.Path; Label = $c.Label }
    }

    foreach ($c in $ordered) {
        if (Test-NetworkDiagFolderWritable -Path $c.Path) {
            $full = [System.IO.Path]::GetFullPath($c.Path)
            return @{ Path = $full; Label = $c.Label }
        }
    }
    return $null
}

function Write-NetworkDiagAbortFile {
    param(
        [Parameter(Mandatory = $true)][string]$Reason,
        [string]$Details = "",
        [string[]]$OutputRoots = @()
    )
    $ts = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $body = @"
Reason: $Reason
Time: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

$Details
"@
    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $OutputRoots) {
        if ($r) { $roots.Add($r) }
    }
    if ($roots.Count -eq 0) {
        $roots.Add((Join-Path $env:TEMP "NetworkTest"))
        $roots.Add($env:TEMP)
    }
    foreach ($r in $roots) {
        try {
            New-Item -ItemType Directory -Path $r -Force -ErrorAction Stop | Out-Null
            $p = Join-Path $r "network_abort_$ts.txt"
            $enc = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllText($p, $body, $enc)
            return $p
        } catch {
            continue
        }
    }
    return $null
}

function Write-NetworkDiagEmergencyReport {
    param(
        [string]$Body,
        [string[]]$OutputRoots
    )
    $ts = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    foreach ($r in $OutputRoots) {
        if (-not $r) { continue }
        try {
            New-Item -ItemType Directory -Path $r -Force -ErrorAction Stop | Out-Null
            $p = Join-Path $r "network_report_emergency_$ts.txt"
            $enc = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllText($p, $Body, $enc)
            return $p
        } catch {
            continue
        }
    }
    return $null
}

function Get-NetworkDiagIpv6AddressTier {
    param([System.Net.IPAddress]$ip)
    $b = $ip.GetAddressBytes()
    if ($b.Length -ne 16) { return 3 }
    $b0 = [int]$b[0]
    $highNibble = ($b0 -shr 4) -band 0x0F
    if ($highNibble -eq 2) { return 0 }
    if ($b0 -eq 0xFC -or $b0 -eq 0xFD) { return 1 }
    if ($b0 -eq 0xFE -and (($b[1] -band 0xC0) -eq 0x80)) { return 2 }
    return 3
}

function ConvertTo-LinkMbps {
    param($LinkSpeed)
    if ($null -eq $LinkSpeed) { return $null }
    if ($LinkSpeed -is [double] -or $LinkSpeed -is [single] -or $LinkSpeed -is [long] -or $LinkSpeed -is [int]) {
        return [math]::Round([double]$LinkSpeed / 1e6, 1)
    }
    $s = [string]$LinkSpeed
    if ($s -match '(\d+(?:\.\d+)?)\s*Gbps') {
        return [math]::Round([double]$Matches[1] * 1000.0, 0)
    }
    if ($s -match '(\d+(?:\.\d+)?)\s*Mbps') {
        return [math]::Round([double]$Matches[1], 0)
    }
    try {
        return [math]::Round([double]$s / 1e6, 1)
    } catch {
        return $null
    }
}

function New-NetworkDiagStats {
    <#
    Construct the run-level statistics hashtable. Extracted from the
    entrypoint's monolithic init so stats shape is documented in one place.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$ExternalCount
    )
    $latencyExtAggs = [object[]]::new($ExternalCount)
    for ($ti = 0; $ti -lt $ExternalCount; $ti++) {
        $latencyExtAggs[$ti] = New-NetworkDiagLatencyAgg
    }
    $jitterExtPairs = [int[]]::new($ExternalCount)
    $jitterExtSum = [double[]]::new($ExternalCount)
    $extFailCycles = [int[]]::new($ExternalCount)
    return @{
        CyclesAttempted                 = 0
        CyclesCommitted                 = 0
        AllOK                           = 0
        ISP_Fault                       = 0
        Local_Fault                     = 0
        Anomaly                         = 0
        GatewayFails                    = 0
        ExternalFails                   = 0
        Incidents                       = [System.Collections.Generic.List[string]]::new()
        IncidentsTruncated              = $false
        LoopbackFail                    = 0
        AdapterNotUpCycles              = 0
        CyclesWithNicDeltas             = 0
        MaxRxErrDelta                   = 0
        MaxRxDiscDelta                  = 0
        MaxTxErrDelta                   = 0
        LinkSpeedChangeCycles           = 0
        LastEthMbps                     = $null
        IcmpDownTcpUpCycles             = 0
        IcmpUpTcpDownCycles             = 0
        VpnAdjustedOkCycles             = 0
        NormalGwIcmpAdjustedOkCycles    = 0
        NormalGwIcmpPolicyActivations   = 0
        NormalGwIcmpPolicyDeactivations = 0
        AnomalyVpnTunnelOnly            = 0
        LatencyGwAgg                    = (New-NetworkDiagLatencyAgg)
        LatencyLanGwAgg                 = (New-NetworkDiagLatencyAgg)
        LatencyExtAggs                  = $latencyExtAggs
        GwFailCycles                    = 0
        LanGwFailCycles                 = 0
        ExtFailCycles                   = $extFailCycles
        DnsFailCycles                   = 0
        JitterGwPairs                   = 0
        JitterGwSum                     = 0.0
        JitterExtPairs                  = $jitterExtPairs
        JitterExtSum                    = $jitterExtSum
        # New-feature counters (populated only when the corresponding module runs).
        ConfigAuditFindingCycles        = 0
        ConfigAuditLastCodes            = @()
        CableHintCycles                 = 0
        CableHintLastCodes              = @()
        MultiNicCrossCheckCycles        = 0
        PrimaryLinkSuspectCycles        = 0
        MultiNicAltExtOkCycles          = 0
        MultiNicStrictConfirmedCycles   = 0
        MultiNicLooseIndicativeCycles   = 0
        MultiNicInconclusiveCycles      = 0
        MultiNicSuspectReasonCounts     = @{}
        EpisodeCount                    = 0
        EpisodeSummaries                = [System.Collections.Generic.List[hashtable]]::new()
        WriterReopenEvents              = 0
        WriterReopenFailures            = 0
        DetailLogReopenEvents           = 0
        CycleOvershootCount             = 0
        WifiBssidsCappedAt              = 0
        IspEvidenceBundlePath           = ""
        TlsProbeCycles                  = 0
        TlsHandshakeFailCycles          = 0
        TcpUpTlsDownCycles              = 0
        WifiLastTimestamp               = ""
        # UDP probe (continuous game-like traffic) - populated only when enabled.
        UdpProbeEnabled                 = $false
        UdpProbeStarted                 = $false
        UdpTotalPacketsSent             = [long]0
        UdpTotalSendErrors              = [long]0
        UdpTotalRepliesRecv             = [long]0
        UdpFailCycles                   = 0
        UdpStallCycles                  = 0
        UdpMaxConsecSendErrors          = 0
        UdpInitErrorMsg                 = ""
        UdpLastErrorCode                = ""
        UdpProbeTarget                  = ""
        UdpProbeRateHz                  = 0
        # Long-lived TCP session probe - populated only when enabled.
        TcpSessionEnabled               = $false
        TcpSessionStarted               = $false
        TcpSessionTotalResets           = 0
        TcpSessionTotalConnectAttempts  = 0
        TcpSessionTotalConnectFailures  = 0
        TcpSessionResetCycles           = 0
        TcpSessionDisconnectedCycles    = 0
        TcpSessionLastResetReason       = ""
        TcpSessionLastResetAt           = $null
        TcpSessionTarget                = ""
        # Auto-capture (pktmon / netsh trace) - populated only when enabled.
        AutoCaptureEnabled              = $false
        AutoCaptureCount                = 0
        AutoCaptureMax                  = 0
        AutoCaptureMethod               = ""
        AutoCaptureSeconds              = 0
        AutoCaptureFiles                = [System.Collections.Generic.List[string]]::new()
        AutoCaptureLastState            = "none"
        AutoCaptureLastFile             = ""
        AutoCaptureSupported            = $false
        AutoCaptureSkippedNonAdmin      = $false
    }
}

function Add-NetworkDiagIncident {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Stats,
        [Parameter(Mandatory = $true)][string]$Line
    )
    $cap = $script:MaxIncidentsInMemory
    if ($null -eq $cap -or [int]$cap -le 0) { $cap = 500 }
    if ($Stats.Incidents.Count -lt $cap) {
        [void]$Stats.Incidents.Add($Line)
    } elseif (-not $Stats.IncidentsTruncated) {
        $Stats.IncidentsTruncated = $true
        [void]$Stats.Incidents.Add("(incident log truncated at $cap entries; further fault lines omitted)")
    }
}
