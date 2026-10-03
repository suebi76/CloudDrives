# Shared setup for all Pester tests: imports the module and provides an isolated CloudDrives home,
# so tests never touch the real %LOCALAPPDATA%\CloudDrives or real secrets.

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:SrcRoot = Join-Path $script:RepoRoot 'src'

function New-CdTestHome {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('clouddrives-test-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $env:CLOUDDRIVES_HOME = $dir
    $dir
}

function Remove-CdTestHome {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:\CLOUDDRIVES_HOME -ErrorAction SilentlyContinue
}

function Import-CdModuleForTest {
    Import-Module (Join-Path $script:SrcRoot 'CloudDrives.psd1') -Force
}
