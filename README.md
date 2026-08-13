# dotfiles

$env:ANTHROPIC_BASE_URL = "https://openrouter.ai/api"
$env:ANTHROPIC_AUTH_TOKEN = $env:OPENROUTER_API_KEY
$env:ANTHROPIC_API_KEY = ""
$env:CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = "1"

# Flagship reasoning model for heavy architecture & complex planning
$env:ANTHROPIC_DEFAULT_FABLE_MODEL = "openai/gpt-5.6-luna"
$env:ANTHROPIC_DEFAULT_OPUS_MODEL = "openai/gpt-5.6-luna"
# Fast, cost-efficient Flash model for primary execution, quick tasks, & subagents
$env:ANTHROPIC_DEFAULT_SONNET_MODEL = "deepseek/deepseek-v4-flash-0731"
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL = "deepseek/deepseek-v4-flash-0731"
$env:CLAUDE_CODE_SUBAGENT_MODEL = "deepseek/deepseek-v4-flash-0731"