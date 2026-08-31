$targetExtensions = Get-Content -Path "$PSScriptRoot\extensions.txt" | 
ForEach-Object { $_.Trim() } | 
Where-Object { $_ -and -not $_.StartsWith("#") }

$installedExtensions = code --list-extensions

# Uninstall extensions not present in the file
$installedExtensions | Where-Object { $targetExtensions -notcontains $_ } | ForEach-Object {
    code --uninstall-extension $_
}

# Install missing extensions from the file
$targetExtensions | Where-Object { $installedExtensions -notcontains $_ } | ForEach-Object {
    code --install-extension $_
}
