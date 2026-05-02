#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Should {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true, Mandatory = $true)]
        $Actual,

        [switch]$Not,
        $Be,
        [switch]$BeTrue,
        [switch]$BeFalse,
        $BeGreaterThan,
        $Match,
        [switch]$Throw
    )
    process {
        if ($PSBoundParameters.ContainsKey("Be")) {
            if ($Not) { $Actual | Pester\Should Not Be $Be } else { $Actual | Pester\Should Be $Be }
            return
        }
        if ($BeTrue) {
            if ($Not) { $Actual | Pester\Should Not Be $true } else { $Actual | Pester\Should Be $true }
            return
        }
        if ($BeFalse) {
            if ($Not) { $Actual | Pester\Should Not Be $false } else { $Actual | Pester\Should Be $false }
            return
        }
        if ($PSBoundParameters.ContainsKey("BeGreaterThan")) {
            if ($Not) { $Actual | Pester\Should Not BeGreaterThan $BeGreaterThan } else { $Actual | Pester\Should BeGreaterThan $BeGreaterThan }
            return
        }
        if ($PSBoundParameters.ContainsKey("Match")) {
            if ($Not) { $Actual | Pester\Should Not Match $Match } else { $Actual | Pester\Should Match $Match }
            return
        }
        if ($Throw) {
            if ($Not) { $Actual | Pester\Should Not Throw } else { $Actual | Pester\Should Throw }
            return
        }
        throw "Unsupported compatibility assertion usage."
    }
}
