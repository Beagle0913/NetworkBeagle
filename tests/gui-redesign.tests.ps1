#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot "gui\core\state.ps1")
. (Join-Path $projectRoot "gui\core\profiles.ps1")
. (Join-Path $projectRoot "gui\core\validation.ps1")
. (Join-Path $projectRoot "gui\core\run-service.ps1")

Describe "Goal-first redesign helpers" {
    It "contains expected goal profiles" {
        $base = New-NetworkDiagGuiDefaultState
        $goals = Get-NetworkDiagGuiGoalProfiles -BaseState $base
        @($goals.Keys) -contains "quick" | Should Be $true
        @($goals.Keys) -contains "wifi" | Should Be $true
        @($goals.Keys) -contains "dns" | Should Be $true
        @($goals.Keys) -contains "isp" | Should Be $true
        @($goals.Keys) -contains "vpn" | Should Be $true
        @($goals.Keys) -contains "custom" | Should Be $true
    }

    It "writes schema envelope and reads v2 document" {
        $state = Merge-NetworkDiagGuiState -Overrides @{ DurationMinutes = 12 }
        $tmp = Join-Path $env:TEMP ("gui_state_test_" + [guid]::NewGuid().ToString("N") + ".json")
        Write-NetworkDiagGuiStateDocument -Path $tmp -State $state
        $loaded = Read-NetworkDiagGuiStateDocument -Path $tmp
        $loaded.DurationMinutes | Should Be 12
    }

    It "migrates legacy state document without schemaVersion" {
        $legacy = @{ DurationMinutes = 9; DnsProbeName = "example.com" }
        $loaded = ConvertFrom-NetworkDiagGuiStateDocument -Loaded $legacy
        $loaded.DurationMinutes | Should Be 9
        $loaded.DnsProbeName | Should Be "example.com"
    }

    It "returns actionable DNS validation issue with fixes" {
        $limits = Get-NetworkDiagGuiLimitations
        $state = Merge-NetworkDiagGuiState -Overrides @{
            DnsProbeName = ""
            SkipDnsProbe = $false
        }
        $result = Test-NetworkDiagGuiState -State $state -Limits $limits
        @($result.Issues | Where-Object { $_.Id -eq "DnsNameRequired" }).Count | Should Be 1
        $issue = @($result.Issues | Where-Object { $_.Id -eq "DnsNameRequired" })[0]
        @($issue.Fixes).Count | Should BeGreaterThan 0
    }

    It "exposes expanded run state machine transitions" {
        $map = Get-NetworkDiagGuiRunTransitionMap
        @($map.Idle) -contains "LaunchingElevated" | Should Be $true
        @($map.Running) -contains "Cancelled" | Should Be $true
        @($map.Stopping) -contains "Completed" | Should Be $true
    }

    It "resolves CLI script path from repo root context" {
        $tmpRoot = Join-Path $env:TEMP ("nb_repo_" + [guid]::NewGuid().ToString("N"))
        [void](New-Item -ItemType Directory -Path $tmpRoot -Force)
        $scriptPath = Join-Path $tmpRoot "network-stability-test.ps1"
        [System.IO.File]::WriteAllText($scriptPath, "# test", (New-Object System.Text.UTF8Encoding $false))
        $oldRepoRoot = if (Test-Path variable:script:NetworkDiagGuiRepoRoot) { [string]$script:NetworkDiagGuiRepoRoot } else { $null }
        try {
            $script:NetworkDiagGuiRepoRoot = $tmpRoot
            Get-NetworkDiagGuiScriptPath | Should Be $scriptPath
            $launch = New-NetworkDiagGuiLaunchCommand -RunnerPath (Join-Path $tmpRoot "invoke-networkdiag.ps1")
            $launch.WorkingDirectory | Should Be $tmpRoot
        } finally {
            if ($null -eq $oldRepoRoot) {
                Remove-Variable -Scope Script -Name NetworkDiagGuiRepoRoot -ErrorAction SilentlyContinue
            } else {
                $script:NetworkDiagGuiRepoRoot = $oldRepoRoot
            }
            Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
