# Define paths using environment variables for portability
$sourceFile = "$env:USERPROFILE\dotfiles\vscode\settings.json"
$targetFile = "$env:APPDATA\Code\User\settings.json"

# Ensure the parent target directory exists
$targetDir = Split-Path -Path $targetFile -Parent
if (-not (Test-Path -Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
}

# Remove existing target file or link to avoid conflicts
if (Test-Path -Path $targetFile) {
    Remove-Item -Path $targetFile -Force               
}

# Create the symbolic link
New-Item -ItemType SymbolicLink -Path $targetFile  -Value $sourceFile -Force