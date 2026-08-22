$rawJson = lms ls --json | ConvertFrom-Json
$modelsConfig = [ordered]@{}

foreach ($item in $rawJson) {
    if ($item.type -and $item.type -ne "llm") { continue }

    $identifier = $item.modelKey
    if (-not $identifier) { $identifier = $item.path }
    if (-not $identifier) { continue }

    $context = 0
    if ($item.maxContextLength) { $context = [int]$item.maxContextLength }
    elseif ($item.max_context_length) { $context = [int]$item.max_context_length }
    elseif ($item.contextLength) { $context = [int]$item.contextLength }
    elseif ($item.context_length) { $context = [int]$item.context_length }

    $toolCall = [bool]($item.trainedForToolUse -or $item.tool_use)
    if (-not $toolCall) { continue }
    $isReasoning = [bool]($item.reasoning -or $identifier -match "thinking|reasoning")

    $cleanName = ($identifier -split '/')[-1] -replace '[-_]', ' '
    $displayName = (Get-Culture).TextInfo.ToTitleCase($cleanName)

    $modelEntry = [ordered]@{
        "name"      = $displayName
        "tool_call" = $toolCall
        "reasoning" = $isReasoning
    }

    if ($context -gt 0) {
        $outputLimit = if ($context -ge 131072) { 65536 } else { 32768 }
        
        $modelEntry["limit"] = [ordered]@{
            "context" = $context
            "output"  = $outputLimit
        }
    }

    $modelsConfig[$identifier] = $modelEntry
}

$jsonOutput = $modelsConfig | ConvertTo-Json -Depth 5
Write-Output $jsonOutput

# Optionally save directly to config file:
# $jsonOutput | Out-File -FilePath "opencode_models.json" -Encoding utf8

Pause