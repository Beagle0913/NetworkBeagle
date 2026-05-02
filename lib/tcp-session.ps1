# lib/tcp-session.ps1
# Long-lived TCP session probe - background runspace that opens a TCP
# connection to a user-supplied host:port, enables SO_KEEPALIVE, and watches
# for FIN/RST via Socket.Poll. On disconnect it counts the reset, records
# the reason, and reconnects after a short backoff. Detects brief carrier-
# grade NAT resets and silent path drops that the cycle's short-lived TCP
# probes can miss.
#
# Public entry points:
#   Start-NetworkDiagTcpSessionProbe      -> handle hashtable
#   Stop-NetworkDiagTcpSessionProbe       -> tear down runspace
#   Read-NetworkDiagTcpSessionDelta       -> per-cycle delta vs caller-owned $Prev

function Start-NetworkDiagTcpSessionProbe {
    param(
        [Parameter(Mandatory = $true)][string]$TargetHost,
        [Parameter(Mandatory = $true)][int]$TargetPort,
        [int]$ConnectTimeoutMs = 8000,
        [int]$ReconnectBackoffSeconds = 5
    )
    if (-not $TargetHost) { throw "Start-NetworkDiagTcpSessionProbe: TargetHost is required." }
    if ($TargetPort -le 0 -or $TargetPort -gt 65535) { throw "Start-NetworkDiagTcpSessionProbe: TargetPort must be 1..65535." }
    if ($ConnectTimeoutMs -lt 500) { $ConnectTimeoutMs = 500 }
    if ($ReconnectBackoffSeconds -lt 1) { $ReconnectBackoffSeconds = 1 }

    $shared = [hashtable]::Synchronized(@{
        Stop                    = $false
        Started                 = $false
        TargetHost              = $TargetHost
        TargetPort              = [int]$TargetPort
        ConnectTimeoutMs        = [int]$ConnectTimeoutMs
        ReconnectBackoffSeconds = [int]$ReconnectBackoffSeconds
        IsConnected             = $false
        SessionConnectedAt      = $null
        ConnectAttempts         = 0
        ConnectFailures         = 0
        ResetCount              = 0
        LastResetReason         = ""
        LastResetAt             = $null
        TotalUptimeSeconds      = 0.0
        CurrentUptimeStart      = $null
        LastConnectMs           = -1
    })

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('State', $shared)

    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        $State.Started = $true
        while (-not $State.Stop) {
            $client = $null
            try {
                $client = New-Object System.Net.Sockets.TcpClient
                try { $client.NoDelay = $true } catch { }
                try {
                    $client.Client.SetSocketOption(
                        [System.Net.Sockets.SocketOptionLevel]::Socket,
                        [System.Net.Sockets.SocketOptionName]::KeepAlive, $true)
                } catch { }
                $State.ConnectAttempts = [int]$State.ConnectAttempts + 1
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $iar = $client.BeginConnect([string]$State.TargetHost, [int]$State.TargetPort, $null, $null)
                $wh = $iar.AsyncWaitHandle
                if (-not $wh.WaitOne([int]$State.ConnectTimeoutMs, $false)) {
                    throw "Connect timeout after $($State.ConnectTimeoutMs)ms"
                }
                $client.EndConnect($iar)
                $sw.Stop()
                $State.LastConnectMs = [int]$sw.ElapsedMilliseconds
                $State.IsConnected = $true
                $State.SessionConnectedAt = [datetime]::UtcNow
                $State.CurrentUptimeStart = [datetime]::UtcNow
                while (-not $State.Stop -and $client.Connected) {
                    Start-Sleep -Milliseconds 500
                    try {
                        $sock = $client.Client
                        if ($sock.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead)) {
                            $avail = 0
                            try { $avail = [int]$client.Available } catch { $avail = 0 }
                            if ($avail -le 0) {
                                $State.ResetCount = [int]$State.ResetCount + 1
                                $State.LastResetReason = "FIN_OR_RST"
                                $State.LastResetAt = [datetime]::UtcNow
                                break
                            } else {
                                # Drain unsolicited bytes (e.g. server hellos / closing handshake)
                                try {
                                    $tmp = New-Object byte[] 256
                                    [void]$client.GetStream().Read($tmp, 0, $tmp.Length)
                                } catch { }
                            }
                        }
                        if ($sock.Poll(0, [System.Net.Sockets.SelectMode]::SelectError)) {
                            $State.ResetCount = [int]$State.ResetCount + 1
                            $State.LastResetReason = "SOCKET_ERROR"
                            $State.LastResetAt = [datetime]::UtcNow
                            break
                        }
                    } catch {
                        $State.ResetCount = [int]$State.ResetCount + 1
                        $State.LastResetReason = "POLL_FAIL: $($_.Exception.Message)"
                        $State.LastResetAt = [datetime]::UtcNow
                        break
                    }
                }
            } catch {
                $State.ConnectFailures = [int]$State.ConnectFailures + 1
                $State.LastResetReason = "CONNECT_FAIL: $($_.Exception.Message)"
                $State.LastResetAt = [datetime]::UtcNow
            } finally {
                if ($State.IsConnected -and $null -ne $State.CurrentUptimeStart) {
                    try {
                        $up = ([datetime]::UtcNow - [datetime]$State.CurrentUptimeStart).TotalSeconds
                        $State.TotalUptimeSeconds = [double]$State.TotalUptimeSeconds + [double]$up
                    } catch { }
                }
                $State.IsConnected = $false
                $State.CurrentUptimeStart = $null
                if ($null -ne $client) { try { $client.Close() } catch { } }
            }
            if (-not $State.Stop) {
                $bo = [int]$State.ReconnectBackoffSeconds * 1000
                $waited = 0
                while ($waited -lt $bo -and -not $State.Stop) {
                    Start-Sleep -Milliseconds 200
                    $waited += 200
                }
            }
        }
    })

    $async = $ps.BeginInvoke()
    return @{
        Shared      = $shared
        Runspace    = $rs
        PowerShell  = $ps
        AsyncResult = $async
    }
}

function Stop-NetworkDiagTcpSessionProbe {
    param([hashtable]$Handle)
    if (-not $Handle) { return }
    try {
        $Handle.Shared.Stop = $true
        Start-Sleep -Milliseconds 350
        if ($Handle.PowerShell -and $Handle.AsyncResult) {
            try { [void]$Handle.PowerShell.EndInvoke($Handle.AsyncResult) } catch { }
            try { $Handle.PowerShell.Dispose() } catch { }
        }
        if ($Handle.Runspace) {
            try { $Handle.Runspace.Close() } catch { }
            try { $Handle.Runspace.Dispose() } catch { }
        }
    } catch { }
}

function New-NetworkDiagTcpSessionPrevState {
    return @{
        ResetCount      = 0
        ConnectAttempts = 0
        ConnectFailures = 0
    }
}

function Read-NetworkDiagTcpSessionDelta {
    param(
        [hashtable]$Handle,
        [hashtable]$Prev
    )
    $empty = @{
        Available             = $false
        Started               = $false
        IsConnected           = $false
        UpSeconds             = -1
        DeltaResets           = 0
        DeltaConnectAttempts  = 0
        DeltaConnectFailures  = 0
        LastResetReason       = ""
        LastConnectMs         = -1
        TotalResets           = 0
        TotalConnectAttempts  = 0
        TotalConnectFailures  = 0
    }
    if (-not $Handle -or -not $Handle.Shared) { return $empty }
    $s = $Handle.Shared
    if ($null -eq $Prev) { $Prev = New-NetworkDiagTcpSessionPrevState }
    $reset = [int]$s.ResetCount
    $att = [int]$s.ConnectAttempts
    $fail = [int]$s.ConnectFailures
    $dReset = [int]([math]::Max(0, $reset - [int]$Prev.ResetCount))
    $dAtt = [int]([math]::Max(0, $att - [int]$Prev.ConnectAttempts))
    $dFail = [int]([math]::Max(0, $fail - [int]$Prev.ConnectFailures))
    $Prev.ResetCount = $reset
    $Prev.ConnectAttempts = $att
    $Prev.ConnectFailures = $fail
    $upSec = -1
    if ($s.IsConnected -and $null -ne $s.CurrentUptimeStart) {
        try { $upSec = [int]([datetime]::UtcNow - [datetime]$s.CurrentUptimeStart).TotalSeconds } catch { $upSec = -1 }
    }
    return @{
        Available             = $true
        Started               = [bool]$s.Started
        IsConnected           = [bool]$s.IsConnected
        UpSeconds             = $upSec
        DeltaResets           = $dReset
        DeltaConnectAttempts  = $dAtt
        DeltaConnectFailures  = $dFail
        LastResetReason       = [string]$s.LastResetReason
        LastConnectMs         = [int]$s.LastConnectMs
        TotalResets           = $reset
        TotalConnectAttempts  = $att
        TotalConnectFailures  = $fail
    }
}
