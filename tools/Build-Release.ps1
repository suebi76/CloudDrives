<#
.SYNOPSIS
    Builds the release assets: CloudDrives-<version>.zip, install.ps1 and SHA256SUMS.txt.
.DESCRIPTION
    The ZIP contains only what users need (see src\Resources\app.json, "packageItems"), never tests or tools.
    A test version carries a label (PrivateData.PSData.Prerelease in the manifest), so its version reads
    0.3.3-preview.1 and its package CloudDrives-0.3.3-preview.1.zip.
    -LocalSource additionally writes a release.json so the folder can serve as CLOUDDRIVES_RELEASE_SOURCE
    for offline installations and tests.
    -ExpectedVersion (the version a release tag names) stops the build when the manifest says otherwise.
#>
param(
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'out'),
    [string]$SourceRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$LocalSource,
    [string]$ExpectedVersion
)

$ErrorActionPreference = 'Stop'
$manifest = Import-PowerShellDataFile -Path (Join-Path $SourceRoot 'src\CloudDrives.psd1')
$version = [string]$manifest.ModuleVersion
$label = [string]$manifest.PrivateData.PSData.Prerelease
if ($label) { $version += "-$label" }
if ($ExpectedVersion -and $ExpectedVersion -ne $version) { throw "Version $ExpectedVersion does not match the module version $version." }
$app = [IO.File]::ReadAllText((Join-Path $SourceRoot 'src\Resources\app.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
$packageName = $app.packageName.Replace('{version}', $version)

if (-not (Test-Path -LiteralPath $OutDir)) { [void](New-Item -ItemType Directory -Path $OutDir -Force) }
$staging = Join-Path ([IO.Path]::GetTempPath()) ('clouddrives-build-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $staging -Force)
try {
    foreach ($item in $app.packageItems) {
        $source = Join-Path $SourceRoot $item
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $staging -Recurse -Force }
    }
    $zip = Join-Path $OutDir $packageName
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($staging, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
}
finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

$installer = Join-Path $OutDir 'install.ps1'
Copy-Item -LiteralPath (Join-Path $SourceRoot 'install.ps1') -Destination $installer -Force

$lines = foreach ($file in @($zip, $installer)) {
    '{0}  {1}' -f (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant(), (Split-Path -Leaf $file)
}
$sums = Join-Path $OutDir $app.checksumFile
[IO.File]::WriteAllText($sums, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))

if ($LocalSource) {
    $release = [ordered]@{
        tag_name   = "v$version"
        prerelease = [bool]$label
        assets     = @(
            [ordered]@{ name = $packageName; browser_download_url = $zip },
            [ordered]@{ name = $app.checksumFile; browser_download_url = $sums },
            [ordered]@{ name = 'install.ps1'; browser_download_url = $installer }
        )
    }
    [IO.File]::WriteAllText((Join-Path $OutDir 'release.json'), (ConvertTo-Json -InputObject $release -Depth 5), (New-Object Text.UTF8Encoding($false)))
}

Write-Host "  Release $version built in $OutDir"
Get-ChildItem -LiteralPath $OutDir -File | ForEach-Object { Write-Host ('    {0,-28} {1,10:N0} bytes' -f $_.Name, $_.Length) }
