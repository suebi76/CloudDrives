<#
.SYNOPSIS
    Installs the pinned development tools (Pester, PSScriptAnalyzer) into a private folder.
.DESCRIPTION
    The modules are saved to %LOCALAPPDATA%\CloudDrives-dev\Modules (or $env:CLOUDDRIVES_DEVTOOLS)
    so that the system-wide module folders stay untouched. tools\Invoke-Build.ps1 uses this folder.
#>
param(
    [string]$Path = $(if ($env:CLOUDDRIVES_DEVTOOLS) { $env:CLOUDDRIVES_DEVTOOLS } else { Join-Path $env:LOCALAPPDATA 'CloudDrives-dev\Modules' })
)

$ErrorActionPreference = 'Stop'
$modules = @(
    @{ Name = 'Pester'; Version = '5.7.1' },
    @{ Name = 'PSScriptAnalyzer'; Version = '1.25.0' }
)

if (-not (Test-Path -LiteralPath $Path)) { [void](New-Item -ItemType Directory -Path $Path -Force) }
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

foreach ($module in $modules) {
    $target = Join-Path (Join-Path $Path $module.Name) $module.Version
    if (Test-Path -LiteralPath $target) {
        Write-Host "  $($module.Name) $($module.Version) already present."
        continue
    }
    Write-Host "  Saving $($module.Name) $($module.Version) ..."
    if (Get-Command -Name 'Save-PSResource' -ErrorAction SilentlyContinue) {
        Save-PSResource -Name $module.Name -Version $module.Version -Path $Path -Repository PSGallery -TrustRepository
    }
    else {
        Save-Module -Name $module.Name -RequiredVersion $module.Version -Path $Path -Repository PSGallery -Force
    }
}
Write-Host "  Development tools are in $Path"
