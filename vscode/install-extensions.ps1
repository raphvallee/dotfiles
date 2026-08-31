Get-Content -Path "$PSScriptRoot\extensions.txt" | ForEach-Object {
    $extension = $_.Trim()
    if ($extension -and -not $extension.StartsWith("#")) {
        code --install-extension $extension
    }
}