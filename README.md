# dotfiles

## Claude Code

### Skills

- Caveman

``` powershell
claude plugin marketplace add JuliusBrussee/caveman
claude plugin install caveman@caveman
```

### Environment Variables

The following environment variables are required to route traffic through OpenRouter.

Note: Set your OPENROUTER_API_KEY before running Claude CLI commands.

#### Powershell Setup

``` powershell
$env:OPENROUTER_API_KEY = "THE API KEY"
$env:ANTHROPIC_AUTH_TOKEN = $env:OPENROUTER_API_KEY
```

#### Bash / Zsh Setup

``` shell
export OPENROUTER_API_KEY="your_openrouter_api_key_here"
export ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY"
```

## OpenCode

### Oh My OpenAgent

``` powershell
bunx oh-my-openagent install
```
