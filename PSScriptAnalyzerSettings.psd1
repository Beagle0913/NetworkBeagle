@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @(
        # Existing script style favors approved verbs only in some places.
        'PSUseApprovedVerbs'
    )
    Rules = @{
        PSUseConsistentIndentation = @{
            Enable = $true
            Kind = 'space'
            IndentationSize = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }
        PSUseConsistentWhitespace = @{
            Enable = $true
            CheckOpenBrace = $true
            CheckOpenParen = $true
            CheckOperator = $true
            CheckSeparator = $true
        }
    }
}
