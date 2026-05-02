function New-NetworkDiagGuiHooks {
    return @{
        RunStarting = [System.Collections.Generic.List[scriptblock]]::new()
        RunStarted = [System.Collections.Generic.List[scriptblock]]::new()
        CycleObserved = [System.Collections.Generic.List[scriptblock]]::new()
        RunFinished = [System.Collections.Generic.List[scriptblock]]::new()
        AnalysisReady = [System.Collections.Generic.List[scriptblock]]::new()
    }
}

function Register-NetworkDiagGuiHook {
    param(
        [hashtable]$Hooks,
        [string]$EventName,
        [scriptblock]$Handler
    )
    if (-not $Hooks.ContainsKey($EventName)) {
        throw "Unknown GUI hook event: $EventName"
    }
    if ($null -ne $Handler) {
        $Hooks[$EventName].Add($Handler)
    }
}

function Invoke-NetworkDiagGuiHook {
    param(
        [hashtable]$Hooks,
        [string]$EventName,
        [hashtable]$Payload = @{}
    )
    if (-not $Hooks.ContainsKey($EventName)) { return }
    foreach ($handler in @($Hooks[$EventName])) {
        try {
            & $handler $Payload
        } catch {
            # Hook failures should never break the launcher.
        }
    }
}
