#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ((Get-Module Pester).Version.Major -lt 5) { . (Join-Path $PSScriptRoot "pester5-compat.ps1") }

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot "gui\core\state.ps1")
. (Join-Path $projectRoot "gui\core\profiles.ps1")
. (Join-Path $projectRoot "gui\core\validation.ps1")
. (Join-Path $projectRoot "gui\core\run-service.ps1")

Describe "Goal-first redesign helpers" {
    It "contains expected goal profiles" {
        $base = New-NetworkDiagGuiDefaultState
        $goals = Get-NetworkDiagGuiGoalProfiles -BaseState $base
        @($goals.Keys) -contains "quick" | Should -Be $true
        @($goals.Keys) -contains "wifi" | Should -Be $true
        @($goals.Keys) -contains "dns" | Should -Be $true
        @($goals.Keys) -contains "isp" | Should -Be $true
        @($goals.Keys) -contains "vpn" | Should -Be $true
        @($goals.Keys) -contains "custom" | Should -Be $true
    }

    It "writes schema envelope and reads v2 document" {
        $state = Merge-NetworkDiagGuiState -Overrides @{ DurationMinutes = 12 }
        $tmp = Join-Path $env:TEMP ("gui_state_test_" + [guid]::NewGuid().ToString("N") + ".json")
        Write-NetworkDiagGuiStateDocument -Path $tmp -State $state
        $loaded = Read-NetworkDiagGuiStateDocument -Path $tmp
        $loaded.DurationMinutes | Should -Be 12
    }

    It "migrates legacy state document without schemaVersion" {
        $legacy = @{ DurationMinutes = 9; DnsProbeName = "example.com" }
        $loaded = ConvertFrom-NetworkDiagGuiStateDocument -Loaded $legacy
        $loaded.DurationMinutes | Should -Be 9
        $loaded.DnsProbeName | Should -Be "example.com"
    }

    It "returns actionable DNS validation issue with fixes" {
        $limits = Get-NetworkDiagGuiLimitations
        $state = Merge-NetworkDiagGuiState -Overrides @{
            DnsProbeName = ""
            SkipDnsProbe = $false
        }
        $result = Test-NetworkDiagGuiState -State $state -Limits $limits
        @($result.Issues | Where-Object { $_.Id -eq "DnsNameRequired" }).Count | Should -Be 1
        $issue = @($result.Issues | Where-Object { $_.Id -eq "DnsNameRequired" })[0]
        @($issue.Fixes).Count | Should -BeGreaterThan 0
    }

    It "exposes expanded run state machine transitions" {
        $map = Get-NetworkDiagGuiRunTransitionMap
        @($map.Idle) -contains "LaunchingElevated" | Should -Be $true
        @($map.Running) -contains "Cancelled" | Should -Be $true
        @($map.Stopping) -contains "Completed" | Should -Be $true
    }

    It "resolves CLI script path from repo root context" {
        $tmpRoot = Join-Path $env:TEMP ("nb_repo_" + [guid]::NewGuid().ToString("N"))
        [void](New-Item -ItemType Directory -Path $tmpRoot -Force)
        $scriptPath = Join-Path $tmpRoot "network-stability-test.ps1"
        [System.IO.File]::WriteAllText($scriptPath, "# test", (New-Object System.Text.UTF8Encoding $false))
        $oldRepoRoot = if (Test-Path variable:script:NetworkDiagGuiRepoRoot) { [string]$script:NetworkDiagGuiRepoRoot } else { $null }
        try {
            $script:NetworkDiagGuiRepoRoot = $tmpRoot
            Get-NetworkDiagGuiScriptPath | Should -Be $scriptPath
            $launch = New-NetworkDiagGuiLaunchCommand -RunnerPath (Join-Path $tmpRoot "invoke-networkdiag.ps1")
            $launch.WorkingDirectory | Should -Be $tmpRoot
        } finally {
            if ($null -eq $oldRepoRoot) {
                Remove-Variable -Scope Script -Name NetworkDiagGuiRepoRoot -ErrorAction SilentlyContinue
            } else {
                $script:NetworkDiagGuiRepoRoot = $oldRepoRoot
            }
            Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "builds run metadata with key launcher context" {
        $state = Merge-NetworkDiagGuiState -Overrides @{
            DurationMinutes = 10
            IntervalSeconds = 2
            ProbeAddressFamily = "IPv4"
            MonitoringMode = "ShortRun"
            OutputRoot = "C:\Temp\out"
        }
        $paths = @{
            LauncherRunRoot = "C:\Temp\launcher\run_1"
            LogsFolder = "C:\Temp\launcher\run_1\logs"
            ScriptOutputRoot = "C:\Temp\launcher\run_1\script-output-root"
        }
        $script:App = @{
            Context = @{ IsAdminGui = $false }
            Ui = @{ Controls = @{ CurrentGoalText = @{ Text = "Goal: Quick internet sanity check" } } }
        }
        $meta = New-NetworkDiagGuiRunMetadata -State $state -Paths $paths -PreferAdmin:$true
        $meta.startMode | Should -Be "prefer_admin"
        $meta.durationMinutes | Should -Be 10
        $meta.logsFolder | Should -Be "C:\Temp\launcher\run_1\logs"
    }

    It "defines advanced key groups with expected sections" {
        $groups = Get-NetworkDiagGuiAdvancedKeyGroups
        @($groups.Keys) -contains "Timing" | Should -Be $true
        @($groups.Keys) -contains "Switches" | Should -Be $true
        @($groups.Keys) -contains "Udp" | Should -Be $true
        @($groups.Keys) -contains "LongTcp" | Should -Be $true
        @($groups.Keys) -contains "Capture" | Should -Be $true
    }

    It "applies advanced bundle overrides without changing setup-owned keys" {
        $base = New-NetworkDiagGuiDefaultState
        $bundles = Get-NetworkDiagGuiAdvancedBundles -BaseState $base
        $bundle = [hashtable]$bundles["Micro-loss hunting (UDP)"]
        $candidate = @{}
        foreach ($k in $base.Keys) { $candidate[$k] = $base[$k] }
        foreach ($k in $bundle.Keys) { $candidate[$k] = $bundle[$k] }
        $merged = Merge-NetworkDiagGuiState -Overrides $candidate
        $merged.EnableUdpProbe | Should -Be $true
        $merged.UdpProbeRateHz | Should -Be 30
        $merged.DurationMinutes | Should -Be $base.DurationMinutes
        $merged.MonitoringMode | Should -Be $base.MonitoringMode
    }

    It "round-trips advanced snippet projection via JSON" {
        $state = Merge-NetworkDiagGuiState -Overrides @{
            EnableUdpProbe = $true
            UdpProbeTarget = "8.8.8.8:443"
            AutoCaptureOnFault = $true
            AutoCaptureSeconds = 15
        }
        $projected = Project-NetworkDiagGuiStateToAdvancedKeys -State $state
        $json = $projected | ConvertTo-Json -Depth 6
        $back = ConvertTo-NetworkDiagHashtable -InputObject ($json | ConvertFrom-Json)
        $allow = @{}
        foreach ($k in (Get-NetworkDiagGuiAdvancedKeyAllowlist)) { $allow[$k] = $true }
        @($back.Keys | Where-Object { -not $allow.ContainsKey($_) }).Count | Should -Be 0
        $back.EnableUdpProbe | Should -Be $true
        $back.AutoCaptureOnFault | Should -Be $true
    }
}
