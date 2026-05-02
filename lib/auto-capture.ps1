# lib/auto-capture.ps1
# Auto-capture trigger - on the first non-OK cycle (subject to a per-run cap)
# the entrypoint asks this module to spawn a runspace that runs pktmon (or
# netsh trace) for N seconds and writes the resulting .etl into the run
# folder. Both tools require admin; the helper exits gracefully when not
# elevated or when the binary is missing.
#
# Public entry points:
#   Test-NetworkDiagAutoCaptureSupported   -> bool (binary present?)
#   Start-NetworkDiagAutoCapture           -> handle hashtable
#   Stop-NetworkDiagAutoCapture            -> wait/teardown, returns shared state
#   Get-NetworkDiagAutoCaptureSnapshot     -> read-only state copy

function Test-NetworkDiagAutoCaptureSupported {
    param([string]$Method = "pktmon")
    $cmd = if ($Method -eq "netshtrace") { "netsh" } else { "pktmon" }
    return ($null -ne (Get-Command -Name $cmd -ErrorAction SilentlyContinue))
}

function Start-NetworkDiagAutoCapture {
    <#
    Spawns a runspace that:
      1. Issues `pktmon start` (or `netsh trace start`) writing to OutputFolder.
      2. Sleeps for $Seconds (or until $Stop is set).
      3. Issues the matching `stop` command.
    Returns a handle hashtable. Non-blocking. Caller polls $Handle.Shared.State
    or stops via Stop-NetworkDiagAutoCapture.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$OutputFolder,
        [string]$Method = "pktmon",
        [int]$Seconds = 30,
        [string]$Reason = "fault",
        [int]$MaxFileSizeMB = 512
    )
    if ($Seconds -lt 5) { $Seconds = 5 }
    if ($Seconds -gt 600) { $Seconds = 600 }
    if (-not (Test-Path -LiteralPath $OutputFolder)) {
        try { [void](New-Item -ItemType Directory -Path $OutputFolder -Force) } catch { }
    }
    $captureDir = Join-Path $OutputFolder "captures"
    if (-not (Test-Path -LiteralPath $captureDir)) {
        try { [void](New-Item -ItemType Directory -Path $captureDir -Force) } catch { }
    }
    $ts = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $safeReason = ($Reason -replace '[^A-Za-z0-9_-]', '_')
    if (-not $safeReason) { $safeReason = "fault" }
    $fileName = "capture_${ts}_${safeReason}.etl"
    $filePath = Join-Path $captureDir $fileName

    $shared = [hashtable]::Synchronized(@{
        Stop          = $false
        Method        = $Method
        Seconds       = [int]$Seconds
        Reason        = $Reason
        FilePath      = $filePath
        StartedAt     = $null
        EndedAt       = $null
        State         = "starting"
        StartExitCode = $null
        StopExitCode  = $null
        StartStderr   = ""
        StopStderr    = ""
        Notes         = ""
        MaxFileSizeMB = [int]$MaxFileSizeMB
    })

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('State', $shared)

    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        function Invoke-AcExternal {
            param([string]$File, [string[]]$ArgsList, [int]$TimeoutMs = 30000)
            $errFile = [System.IO.Path]::Combine($env:TEMP, ("ndcap_" + ([guid]::NewGuid().ToString("n")) + ".err"))
            try {
                $proc = Start-Process -FilePath $File -ArgumentList $ArgsList -Wait -PassThru -NoNewWindow -RedirectStandardError $errFile -RedirectStandardOutput ([System.IO.Path]::Combine($env:TEMP, ("ndcap_" + ([guid]::NewGuid().ToString("n")) + ".out")))
                $exit = if ($proc) { [int]$proc.ExitCode } else { -1 }
                $err = ""
                try { if (Test-Path -LiteralPath $errFile) { $err = [System.IO.File]::ReadAllText($errFile) } } catch { }
                return @{ ExitCode = $exit; Stderr = $err }
            } catch {
                return @{ ExitCode = -1; Stderr = [string]$_.Exception.Message }
            } finally {
                try { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue } catch { }
            }
        }

        try {
            $State.StartedAt = [datetime]::UtcNow
            $State.State = "starting"
            if ($State.Method -eq "netshtrace") {
                $sizeArg = "maxsize=$([int]$State.MaxFileSizeMB)"
                $args = @("trace", "start", "capture=yes", "report=disabled", "persistent=no",
                          "tracefile=$($State.FilePath)", $sizeArg, "overwrite=yes")
                $r = Invoke-AcExternal -File "netsh" -ArgsList $args
                $State.StartExitCode = [int]$r.ExitCode
                $State.StartStderr = [string]$r.Stderr
            } else {
                $args = @("start", "--capture", "--comp", "nics", "--type", "all",
                          "-f", $State.FilePath, "-s", [string]([int]$State.MaxFileSizeMB))
                $r = Invoke-AcExternal -File "pktmon" -ArgsList $args
                if ($r.ExitCode -ne 0) {
                    $args2 = @("start", "-c", "-f", $State.FilePath)
                    $r2 = Invoke-AcExternal -File "pktmon" -ArgsList $args2
                    $State.StartExitCode = [int]$r2.ExitCode
                    $State.StartStderr = [string]($r.Stderr + " | retry: " + $r2.Stderr)
                    $State.Notes = "fell_back_to_legacy_pktmon_syntax"
                } else {
                    $State.StartExitCode = [int]$r.ExitCode
                    $State.StartStderr = [string]$r.Stderr
                }
            }
            if ([int]$State.StartExitCode -ne 0) {
                $State.State = "start_failed"
                $State.EndedAt = [datetime]::UtcNow
                return
            }
            $State.State = "running"
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $deadlineMs = [int]$State.Seconds * 1000
            while (-not $State.Stop -and $sw.Elapsed.TotalMilliseconds -lt $deadlineMs) {
                Start-Sleep -Milliseconds 250
            }
            $State.State = "stopping"
            if ($State.Method -eq "netshtrace") {
                $r = Invoke-AcExternal -File "netsh" -ArgsList @("trace", "stop")
            } else {
                $r = Invoke-AcExternal -File "pktmon" -ArgsList @("stop")
            }
            $State.StopExitCode = [int]$r.ExitCode
            $State.StopStderr = [string]$r.Stderr
            $State.EndedAt = [datetime]::UtcNow
            $State.State = if ([int]$r.ExitCode -eq 0) { "done" } else { "stop_failed" }
        } catch {
            $State.State = "exception"
            $State.StartStderr = [string]$_.Exception.Message
            $State.EndedAt = [datetime]::UtcNow
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

function Stop-NetworkDiagAutoCapture {
    param([hashtable]$Handle, [int]$WaitMs = 8000)
    if (-not $Handle) { return $null }
    try {
        $Handle.Shared.Stop = $true
        $waited = 0
        $intermediate = @("starting", "running", "stopping")
        while ($waited -lt $WaitMs -and ([string]$Handle.Shared.State -in $intermediate)) {
            Start-Sleep -Milliseconds 250
            $waited += 250
        }
        if ($Handle.PowerShell -and $Handle.AsyncResult) {
            try { [void]$Handle.PowerShell.EndInvoke($Handle.AsyncResult) } catch { }
            try { $Handle.PowerShell.Dispose() } catch { }
        }
        if ($Handle.Runspace) {
            try { $Handle.Runspace.Close() } catch { }
            try { $Handle.Runspace.Dispose() } catch { }
        }
    } catch { }
    return $Handle.Shared
}

function Get-NetworkDiagAutoCaptureSnapshot {
    param([hashtable]$Handle)
    if (-not $Handle -or -not $Handle.Shared) {
        return @{
            Available     = $false
            State         = "none"
            FilePath      = ""
            StartExitCode = $null
            StopExitCode  = $null
        }
    }
    $s = $Handle.Shared
    return @{
        Available     = $true
        State         = [string]$s.State
        FilePath      = [string]$s.FilePath
        Method        = [string]$s.Method
        Seconds       = [int]$s.Seconds
        Reason        = [string]$s.Reason
        StartedAt     = $s.StartedAt
        EndedAt       = $s.EndedAt
        StartExitCode = $s.StartExitCode
        StopExitCode  = $s.StopExitCode
        Notes         = [string]$s.Notes
    }
}
