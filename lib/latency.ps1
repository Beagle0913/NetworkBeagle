# lib/latency.ps1
# Bounded-memory latency aggregator + p95 reservoir sampling. Used for both
# gateway and each external ICMP target so the report's LATENCY section can
# render exact min/avg/max plus an approximate p95 even for very long runs.

function Get-NetworkDiagP95FromList {
    param([System.Collections.Generic.List[double]]$Samples)
    if ($null -eq $Samples -or $Samples.Count -eq 0) { return $null }
    $n = $Samples.Count
    $arr = [double[]]::new($n)
    $Samples.CopyTo($arr)
    [array]::Sort($arr)
    $idx = [int][math]::Min($n - 1, [math]::Max(0, [math]::Ceiling(0.95 * $n) - 1))
    return $arr[$idx]
}

function New-NetworkDiagLatencyAgg {
    param([int]$ReservoirCap = 4096)
    return @{
        Min         = $null
        Max         = $null
        Sum         = 0.0
        SampleCount = 0
        TotalSeen   = 0
        Cap         = [math]::Max(16, $ReservoirCap)
        Reservoir   = [System.Collections.Generic.List[double]]::new()
    }
}

function Add-NetworkDiagLatencySample {
    param(
        [hashtable]$Agg,
        [double]$Value
    )
    if ($null -eq $Agg) { return }
    if ($null -eq $Agg.Min -or $Value -lt [double]$Agg.Min) { $Agg.Min = $Value }
    if ($null -eq $Agg.Max -or $Value -gt [double]$Agg.Max) { $Agg.Max = $Value }
    $Agg.Sum += $Value
    $Agg.SampleCount = [int]$Agg.SampleCount + 1
    $cap = [int]$Agg.Cap
    $r = $Agg.Reservoir
    $Agg.TotalSeen = [int]$Agg.TotalSeen + 1
    $t = [int]$Agg.TotalSeen
    if ($r.Count -lt $cap) {
        [void]$r.Add($Value)
    } else {
        $j = Get-Random -Minimum 0 -Maximum $t
        if ($j -lt $cap) { $r[$j] = $Value }
    }
}

function Format-NetworkDiagLatencySeriesLine {
    param(
        [string]$Label,
        [hashtable]$Agg,
        [int]$FailC,
        [int]$Committed,
        [int]$JitterPairs,
        [double]$JitterSum
    )
    if ($Committed -eq 0) { return "  ${Label}: n/a (no committed cycles)" }
    $lossPct = [math]::Round($FailC / $Committed * 100, 1)
    $cnt = if ($null -eq $Agg) { 0 } else { [int]$Agg.SampleCount }
    if ($cnt -le 0) {
        $msLine = "min/avg/max/p95: n/a (no successful samples)"
    } else {
        $min = [math]::Round([double]$Agg.Min, 1)
        $max = [math]::Round([double]$Agg.Max, 1)
        $avg = [math]::Round([double]$Agg.Sum / [double]$cnt, 1)
        $p95v = Get-NetworkDiagP95FromList $Agg.Reservoir
        $p95s = if ($null -ne $p95v) { [math]::Round([double]$p95v, 1) } else { "n/a" }
        $p95Note = if ($Agg.TotalSeen -gt $Agg.Reservoir.Count) { " (p95 from reservoir; $($Agg.TotalSeen) successes)" } else { "" }
        $msLine = "min/avg/max/p95: $min / $avg / $max / $p95s ms$p95Note"
    }
    $jit = if ($JitterPairs -lt 0) {
        ""
    } elseif ($JitterPairs -gt 0) {
        $mj = [math]::Round($JitterSum / $JitterPairs, 2)
        " | IPDV mean: $mj ms over $JitterPairs consecutive-success pair(s) (gaps skipped when ICMP failed)"
    } else { " | IPDV: n/a (no consecutive success pairs)" }
    return "  ${Label}: cycle-loss $lossPct% ($FailC/$Committed fail cycles); $msLine$jit"
}
