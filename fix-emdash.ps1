#Requires -Version 5.1
<#
.SYNOPSIS
    Replaces every em dash (U+2014) with a plain hyphen-minus (U+002D)
    in every *.md file under the current directory, recursively.

.DESCRIPTION
    Works at the byte level, so file encoding (UTF-8, UTF-16, Latin-1) and
    line endings are preserved. An em dash is the 3-byte sequence
    E2 80 94; the replacement is the single byte 2D.

    Binary files, .git internals, dependency folders, and files ignored by
    .gitignore are skipped.

.PARAMETER DryRun
    $true  = report only, nothing is written (default).
    $false = rewrite the files in place.

.EXAMPLE
    pwsh ./fix-emdash.ps1
    pwsh ./fix-emdash.ps1 -Apply
#>
[CmdletBinding()]
param(
	[switch]$Apply
)

# --- Toggle dry run -------------------------------------------------------
# $true  = show what would change, write nothing
# $false = rewrite files in place
$DryRun = $true
# -------------------------------------------------------------------------

$Root = (Get-Location).Path

# only files with these extensions are processed
$Extensions = @('.md')

# $true  = skip files matched by .gitignore
# $false = process every matching file
$RespectGitignore = $true

$SkipDirs = @(
	'.git', '.hg', '.svn', 'node_modules', '.venv', 'venv',
	'vendor', 'dist', 'build', '.next', '.cache', '__pycache__'
)

# em dash = U+2014, UTF-8 bytes E2 80 94
$Pattern = [byte[]](0xE2, 0x80, 0x94)
$Replacement = [byte[]](0x2D)
$PatternLen = $Pattern.Length

function Test-TextFile {
	param([byte[]]$Bytes)
	# a NUL byte in the first 4 KB means binary
	$limit = [Math]::Min(4096, $Bytes.Length)
	for ($i = 0; $i -lt $limit; $i++) {
		if ($Bytes[$i] -eq 0) { return $false }
	}
	return $true
}

function Get-EmDashOffsets {
	param([byte[]]$Bytes, [int]$Len)
	$hits = New-Object 'System.Collections.Generic.List[int]'
	for ($i = 0; $i -le $Bytes.Length - $Len; $i++) {
		if ($Bytes[$i] -eq $Pattern[0] -and
			$Bytes[$i + 1] -eq $Pattern[1] -and
			$Bytes[$i + 2] -eq $Pattern[2]) {
			$hits.Add($i)
			$i += $Len - 1
		}
	}
	return $hits
}

function Convert-Bytes {
	param([byte[]]$Bytes, [System.Collections.Generic.List[int]]$Offsets)
	$out = New-Object 'System.IO.MemoryStream'
	$cursor = 0
	foreach ($off in $Offsets) {
		$out.Write($Bytes, $cursor, $off - $cursor)
		$out.Write($Replacement, 0, 1)
		$cursor = $off + $PatternLen
	}
	$out.Write($Bytes, $cursor, $Bytes.Length - $cursor)
	return $out.ToArray()
}

function Test-InGitRepo {
	& git -C $Root rev-parse --is-inside-work-tree *> $null
	return ($LASTEXITCODE -eq 0)
}

# one git call returns every tracked and untracked-but-not-ignored path,
# already relative to $Root and scoped to that subtree.
# -z output is NUL-separated, so stdout is read as raw bytes; PowerShell
# would otherwise split native output on newlines and mangle names.
function Get-GitPaths {
	param([switch]$Ignored)

	$gitArgs = @('-C', $Root, 'ls-files', '-z', '--cached', '--others', '--exclude-standard')
	if ($Ignored) { $gitArgs += '--ignored' }

	$psi = [System.Diagnostics.ProcessStartInfo]::new()
	$psi.FileName = 'git'
	foreach ($a in $gitArgs) { [void]$psi.ArgumentList.Add($a) }
	$psi.RedirectStandardOutput = $true
	$psi.RedirectStandardError = $true
	$psi.UseShellExecute = $false

	$proc = [System.Diagnostics.Process]::Start($psi)
	$raw = $proc.StandardOutput.ReadToEnd()
	[void]$proc.StandardError.ReadToEnd()
	$proc.WaitForExit()

	if ($proc.ExitCode -ne 0) { return @() }
	return @($raw -split "`0" | Where-Object { $_ -ne '' })
}

# filters a path relative to $Root: wanted extension, not in a skip dir
function Test-Wanted {
	param([string]$RelativePath)

	$name = $RelativePath.Substring($RelativePath.LastIndexOfAny([char[]]@('\', '/')) + 1)
	if ($Extensions -notcontains [System.IO.Path]::GetExtension($name).ToLowerInvariant()) {
		return $false
	}

	$parts = $RelativePath -split '[\\/]'
	foreach ($part in $parts[0..($parts.Count - 2)]) {
		if ($SkipDirs -contains $part) { return $false }
	}
	return $true
}

$mode = if ($DryRun -and -not $Apply) { 'DRY RUN' } else { 'APPLY' }
Write-Host "Em dash cleanup - mode: $mode - root: $Root" -ForegroundColor Cyan

$useGit = $RespectGitignore -and (Test-InGitRepo)

if ($useGit) {
	$files = @(Get-GitPaths | Where-Object { Test-Wanted -RelativePath $_ } |
		ForEach-Object { Get-Item -LiteralPath (Join-Path $Root $_) -Force -ErrorAction SilentlyContinue })
	$gitignored = @(Get-GitPaths -Ignored | Where-Object { Test-Wanted -RelativePath $_ }).Count
}
else {
	$files = @(Get-ChildItem -Path $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
		Where-Object { Test-Wanted -RelativePath $_.FullName.Substring($Root.Length).TrimStart('\', '/') })
	$gitignored = 0
}

$changed = 0
$totalHits = 0
$skipped = 0

foreach ($file in $files) {
	try {
		$bytes = [System.IO.File]::ReadAllBytes($file.FullName)
	}
 catch {
		Write-Warning "Cannot read: $($file.FullName) - $($_.Exception.Message)"
		$skipped++
		continue
	}

	if (-not (Test-TextFile -Bytes $bytes)) { $skipped++; continue }

	$hits = Get-EmDashOffsets -Bytes $bytes -Len $PatternLen
	if ($hits.Count -eq 0) { continue }

	$rel = $file.FullName.Substring($Root.Length).TrimStart('\', '/')
	$changed++
	$totalHits += $hits.Count
	Write-Host ("  {0,4}  {1}" -f $hits.Count, $rel) -ForegroundColor Yellow

	if ($DryRun -and -not $Apply) { continue }

	$newBytes = Convert-Bytes -Bytes $bytes -Offsets $hits
	[System.IO.File]::WriteAllBytes($file.FullName, $newBytes)
}

Write-Host ''
Write-Host "Files scanned : $($files.Count)" -ForegroundColor Cyan
Write-Host "Files changed : $changed" -ForegroundColor Cyan
Write-Host "Em dashes hit : $totalHits" -ForegroundColor Cyan
Write-Host "Skipped       : $skipped (binary or unreadable)" -ForegroundColor Cyan
Write-Host "Gitignored    : $gitignored" -ForegroundColor Cyan

if ($DryRun -and -not $Apply) {
	Write-Host ''
	Write-Host 'Dry run only. Set $DryRun = $false at the top of this script, or pass -Apply.' -ForegroundColor Cyan
}
