<#
.SYNOPSIS
    Normalises encodings and line endings of all source files.
.DESCRIPTION
    install.ps1            ASCII without BOM, CRLF (it is executed via "irm | iex")
    *.ps1 *.psm1 *.psd1    UTF-8 with BOM, CRLF (Windows PowerShell 5.1 needs the BOM for non-ASCII text)
    *.bat *.cmd            ASCII, CRLF (cmd.exe reads batch files in the OEM code page)
    *.cs *.json *.md       UTF-8 without BOM, CRLF
    *.yml *.yaml *.toml    UTF-8 without BOM, LF
    Every file ends with exactly one line break.
.PARAMETER Check
    Only report files that do not comply (exit code 1); nothing is changed.
#>
param([switch]$Check)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$rules = @(
    # The web installer runs via "irm | iex", which may not honour a BOM or UTF-8: ASCII only.
    @{ Pattern = '^install\.ps1$'; Bom = $false; Eol = "`r`n"; AsciiOnly = $true },
    @{ Pattern = '\.(ps1|psm1|psd1)$'; Bom = $true; Eol = "`r`n"; AsciiOnly = $false },
    @{ Pattern = '\.(bat|cmd)$'; Bom = $false; Eol = "`r`n"; AsciiOnly = $true },
    @{ Pattern = '\.(cs|json|md)$'; Bom = $false; Eol = "`r`n"; AsciiOnly = $false },
    @{ Pattern = '\.(yml|yaml|toml)$'; Bom = $false; Eol = "`n"; AsciiOnly = $false }
)
$excluded = '\\(\.git|\.claude|\.vscode|TestResults|build|out)\\'

# Only files that belong to the repository (tracked or not ignored) - never local files such as
# downloaded client secrets or recovery kits that happen to lie in the working folder.
$files = $null
if (Get-Command -Name 'git' -ErrorAction SilentlyContinue) {
    $list = & git -C $root -c core.quotepath=off ls-files --cached --others --exclude-standard 2>$null
    if ($LASTEXITCODE -eq 0 -and $list) {
        $files = @($list | ForEach-Object { Get-Item -LiteralPath (Join-Path $root $_) -Force -ErrorAction SilentlyContinue } | Where-Object { $_ })
    }
}
if (-not $files) { $files = Get-ChildItem -LiteralPath $root -Recurse -File -Force }

$problems = New-Object System.Collections.Generic.List[string]
foreach ($file in $files) {
    if ($file.FullName -match $excluded) { continue }
    $rule = $rules | Where-Object { $file.Name -match $_.Pattern } | Select-Object -First 1
    if (-not $rule) { continue }

    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $offset = 3 }
    $text = [Text.Encoding]::UTF8.GetString($bytes, $offset, $bytes.Length - $offset)
    $relative = $file.FullName.Substring($root.Length + 1)

    if ($rule.AsciiOnly -and $text -match '[^\x00-\x7F]') {
        $problems.Add("$relative contains non-ASCII characters")
        continue
    }

    $normalized = ($text -replace "`r`n", "`n") -replace "`r", "`n"
    $normalized = $normalized.TrimEnd("`n") + "`n"
    if ($rule.Eol -eq "`r`n") { $normalized = $normalized -replace "`n", "`r`n" }

    $encoding = New-Object Text.UTF8Encoding($rule.Bom)
    $expected = [byte[]]($encoding.GetPreamble() + $encoding.GetBytes($normalized))
    if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$bytes, $expected)) {
        $problems.Add($relative)
        if (-not $Check) { [IO.File]::WriteAllBytes($file.FullName, $expected) }
    }
}

if ($Check) {
    if ($problems.Count -gt 0) {
        $problems | ForEach-Object { Write-Host "  not normalised: $_" -ForegroundColor Yellow }
        exit 1
    }
    Write-Host '  All source files are normalised.' -ForegroundColor Green
    exit 0
}
$problems | ForEach-Object { Write-Host "  normalised: $_" }
