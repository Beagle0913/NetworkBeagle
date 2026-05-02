# lib/udp-probe.ps1
# Continuous UDP probe - background runspace that pumps small datagrams to a
# user-supplied host:port at a configurable rate so the cycle loop can detect
# transient blackholes / TX-stalls / firewall flips that periodic ping cycles
# miss. Game traffic is mostly send-and-pray UDP, so this catches the same
# class of failures.
#
# Public entry points:
#   Start-NetworkDiagUdpProbe       -> handle hashtable
#   Stop-NetworkDiagUdpProbe        -> tear down runspace
#   Read-NetworkDiagUdpProbeDelta   -> per-cycle delta vs caller-owned $Prev

function Start-NetworkDiagUdpProbe {
    <#
    Spawns a runspace with a synchronized state hashtable. Loop:
      * Open a System.Net.Sockets.UdpClient (Connect to TargetHost/TargetPort).
      * Send PayloadBytes of random data at RateHz.
      * Count successful sends, send errors, last error message, consecutive
        send errors, max consecutive send errors. Optional ExpectReply mode
        polls Available between sends and counts datagrams received.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TargetHost,
        [Parameter(Mandatory = $true)][int]$TargetPort,
        [int]$RateHz = 30,
        [int]$PayloadBytes = 64,
        [switch]$ExpectReply
    )
    if (-not $TargetHost) { throw "Start-NetworkDiagUdpProbe: TargetHost is required." }
    if ($TargetPort -le 0 -or $TargetPort -gt 65535) { throw "Start-NetworkDiagUdpProbe: TargetPort must be 1..65535." }
    if ($RateHz -lt 1) { $RateHz = 1 }
    if ($RateHz -gt 1000) { $RateHz = 1000 }
    if ($PayloadBytes -lt 1) { $PayloadBytes = 1 }
    if ($PayloadBytes -gt 1400) { $PayloadBytes = 1400 }

    $shared = [hashtable]::Synchronized(@{
        Stop                = $false
        Started             = $false
        StartedAt           = $null
        TargetHost          = $TargetHost
        TargetPort          = [int]$TargetPort
        RateHz              = [int]$RateHz
        PayloadBytes        = [int]$PayloadBytes
        ExpectReply         = [bool]$ExpectReply
        PacketsSent         = [long]0
        SendErrors          = [long]0
        RepliesRecv         = [long]0
        LastErrorCode       = ""
        LastErrorAt         = $null
        LastSendOk          = $true
        LastSendAt          = $null
        ConsecSendErrors    = 0
        MaxConsecSendErrors = 0
        FirstErrorAt        = $null
        InitErrorMsg        = ""
    })

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('State', $shared)

    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        $client = $null
        try {
            $client = New-Object System.Net.Sockets.UdpClient
            try { $client.Client.SendTimeout = 1000 } catch { }
            $payload = New-Object byte[] ([int]$State.PayloadBytes)
            $rng = New-Object System.Random
            $rng.NextBytes($payload)
            try {
                $client.Connect([string]$State.TargetHost, [int]$State.TargetPort)
            } catch {
                $State.InitErrorMsg = [string]$_.Exception.Message
            }
            $State.Started = $true
            $State.StartedAt = [datetime]::UtcNow
            $intervalMs = [int][math]::Max(1, [math]::Round(1000.0 / [double]$State.RateHz))
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not $State.Stop) {
                $loopStartMs = $sw.Elapsed.TotalMilliseconds
                try {
                    [void]$client.Send($payload, $payload.Length)
                    $State.PacketsSent = [long]$State.PacketsSent + [long]1
                    $State.LastSendOk = $true
                    $State.LastSendAt = [datetime]::UtcNow
                    $State.ConsecSendErrors = 0
                } catch {
                    $State.SendErrors = [long]$State.SendErrors + [long]1
                    $State.LastErrorCode = [string]$_.Exception.Message
                    $State.LastErrorAt = [datetime]::UtcNow
                    $State.LastSendOk = $false
                    $State.ConsecSendErrors = [int]$State.ConsecSendErrors + 1
                    if ([int]$State.ConsecSendErrors -gt [int]$State.MaxConsecSendErrors) {
                        $State.MaxConsecSendErrors = [int]$State.ConsecSendErrors
                    }
                    if ($null -eq $State.FirstErrorAt) {
                        $State.FirstErrorAt = [datetime]::UtcNow
                    }
                }
                if ($State.ExpectReply -and $client -and $client.Available -gt 0) {
                    try {
                        $remote = $null
                        [void]$client.Receive([ref]$remote)
                        $State.RepliesRecv = [long]$State.RepliesRecv + [long]1
                    } catch { }
                }
                $elapsed = $sw.Elapsed.TotalMilliseconds - $loopStartMs
                $sleepMs = [int][math]::Max(0, $intervalMs - $elapsed)
                if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs }
            }
        } catch {
            try { $State.InitErrorMsg = [string]$_.Exception.Message } catch { }
        } finally {
            if ($null -ne $client) { try { $client.Close() } catch { } }
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

function Stop-NetworkDiagUdpProbe {
    param([hashtable]$Handle)
    if (-not $Handle) { return }
    try {
        $Handle.Shared.Stop = $true
        Start-Sleep -Milliseconds 250
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

function New-NetworkDiagUdpPrevState {
    return @{
        PacketsSent = [long]0
        SendErrors  = [long]0
        RepliesRecv = [long]0
    }
}

function Read-NetworkDiagUdpProbeDelta {
    <#
    Returns a per-cycle delta hashtable and mutates $Prev to the new
    high-water marks. Caller keeps $Prev across cycles.
    #>
    param(
        [hashtable]$Handle,
        [hashtable]$Prev
    )
    $empty = @{
        Available           = $false
        Started             = $false
        DeltaPacketsSent    = 0
        DeltaSendErrors     = 0
        DeltaRepliesRecv    = 0
        ConsecSendErrors    = 0
        MaxConsecSendErrors = 0
        LastErrorCode       = ""
        InitErrorMsg        = ""
        TotalPacketsSent    = [long]0
        TotalSendErrors     = [long]0
        TotalRepliesRecv    = [long]0
    }
    if (-not $Handle -or -not $Handle.Shared) { return $empty }
    $s = $Handle.Shared
    if ($null -eq $Prev) { $Prev = New-NetworkDiagUdpPrevState }
    $sent = [long]$s.PacketsSent
    $err = [long]$s.SendErrors
    $recv = [long]$s.RepliesRecv
    $dSent = [long]([math]::Max([long]0, $sent - [long]$Prev.PacketsSent))
    $dErr = [long]([math]::Max([long]0, $err - [long]$Prev.SendErrors))
    $dRecv = [long]([math]::Max([long]0, $recv - [long]$Prev.RepliesRecv))
    $Prev.PacketsSent = $sent
    $Prev.SendErrors = $err
    $Prev.RepliesRecv = $recv
    return @{
        Available           = $true
        Started             = [bool]$s.Started
        DeltaPacketsSent    = [int][math]::Min([int]::MaxValue, [long]$dSent)
        DeltaSendErrors     = [int][math]::Min([int]::MaxValue, [long]$dErr)
        DeltaRepliesRecv    = [int][math]::Min([int]::MaxValue, [long]$dRecv)
        ConsecSendErrors    = [int]$s.ConsecSendErrors
        MaxConsecSendErrors = [int]$s.MaxConsecSendErrors
        LastErrorCode       = [string]$s.LastErrorCode
        InitErrorMsg        = [string]$s.InitErrorMsg
        TotalPacketsSent    = $sent
        TotalSendErrors     = $err
        TotalRepliesRecv    = $recv
    }
}
