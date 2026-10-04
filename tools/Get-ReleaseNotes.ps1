<#
.SYNOPSIS
    Prints the CHANGELOG section of a version (used as release notes by .github\workflows\release.yml).
#>
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$Path = (Join-Path (Split-Path -Parent $PSScriptRoot) 'CHANGELOG.md')
)

$ErrorActionPreference = 'Stop'
$lines = [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)
$start = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match "^## \[$([regex]::Escape($Version))\]") { $start = $i + 1; break }
}
if ($start -lt 0) { throw "CHANGELOG.md has no section for version $Version." }
$section = for ($i = $start; $i -lt $lines.Count -and $lines[$i] -notmatch '^## \['; $i++) { $lines[$i] }
(($section -join "`n").Trim()) + "`n"
