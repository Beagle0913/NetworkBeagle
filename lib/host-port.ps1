# lib/host-port.ps1
# Shared host and host:port validation/parsing helpers used by both
# GUI validation and CLI runtime argument parsing.

function Test-NetworkDiagHostTokenShared {
    param([string]$Value)
    if (-not $Value) { return $false }
    $token = $Value.Trim()
    if (-not $token) { return $false }

    $ip = $null
    if ([System.Net.IPAddress]::TryParse($token, [ref]$ip)) {
        return $true
    }

    $kind = [System.Uri]::CheckHostName($token)
    return ($kind -eq [System.UriHostNameType]::Dns)
}

function Test-NetworkDiagHostPortTokenShared {
    param([string]$Value)
    if (-not $Value) { return $false }
    $token = $Value.Trim()
    if (-not $token) { return $false }
    try {
        [void](Split-NetworkDiagHostPortShared -Raw $token)
        return $true
    } catch {
        return $false
    }
}

function Split-NetworkDiagHostPortShared {
    param(
        [Parameter(Mandatory = $true)][string]$Raw,
        [int]$DefaultPort = 0
    )

    $s = [string]$Raw.Trim()
    if (-not $s) { throw "empty host:port" }
    if ($s.StartsWith("[")) {
        $end = $s.IndexOf("]")
        if ($end -lt 2) { throw "malformed bracketed IPv6 literal: $Raw" }
        $h = $s.Substring(1, $end - 1)
        if (-not $h) { throw "empty host in '$Raw'" }
        $rest = $s.Substring($end + 1)
        $p = 0
        if ($rest.StartsWith(":")) {
            if (-not [int]::TryParse($rest.Substring(1), [ref]$p)) { throw "invalid port in '$Raw'" }
        } else {
            $p = [int]$DefaultPort
        }
        if ($p -lt 1 -or $p -gt 65535) { throw "port out of range in '$Raw' (must be 1..65535)" }
        return @{ Host = $h; Port = [int]$p }
    }
    $idx = $s.LastIndexOf(":")
    if ($idx -lt 0) {
        $p = [int]$DefaultPort
        if ($p -le 0) { throw "no port in '$Raw' and no default" }
        if ($p -lt 1 -or $p -gt 65535) { throw "default port out of range ($p); must be 1..65535" }
        return @{ Host = $s; Port = [int]$p }
    }
    $h = $s.Substring(0, $idx)
    if (-not $h) { throw "empty host in '$Raw'" }
    $portStr = $s.Substring($idx + 1)
    $p = 0
    if (-not [int]::TryParse($portStr, [ref]$p)) {
        throw "invalid port in '$Raw'"
    }
    if ($p -lt 1 -or $p -gt 65535) { throw "port out of range in '$Raw' (must be 1..65535)" }
    return @{ Host = $h; Port = [int]$p }
}
