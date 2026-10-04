<#
.SYNOPSIS
    CloudDrives web installer.
.DESCRIPTION
    Run in PowerShell (no administrator rights needed):

        irm https://github.com/suebi76/CloudDrives/releases/latest/download/install.ps1 | iex

    It downloads the latest release, verifies its SHA256 checksum, installs CloudDrives to
    %LOCALAPPDATA%\Programs\CloudDrives (Start menu and desktop shortcut) and starts the setup.
    Optional environment variables:
      CLOUDDRIVES_RELEASE_SOURCE   local folder with release.json and assets (offline / tests)
      CLOUDDRIVES_INSTALL_NOSTART  "1" = do not start CloudDrives afterwards
#>
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $repository = 'suebi76/CloudDrives'
    $german = (Get-UICulture).TwoLetterISOLanguageName -eq 'de'
    function Say([string]$De, [string]$En, [ConsoleColor]$Color = [ConsoleColor]::Gray) {
        if ($german) { Write-Host "  $De" -ForegroundColor $Color } else { Write-Host "  $En" -ForegroundColor $Color }
    }

    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    Write-Host ''
    Write-Host '  CloudDrives' -ForegroundColor Cyan
    Say 'Installation wird vorbereitet ...' 'Preparing the installation ...'

    $source = $env:CLOUDDRIVES_RELEASE_SOURCE
    if ($source) {
        $release = [IO.File]::ReadAllText((Join-Path $source 'release.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    else {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/releases/latest" -UseBasicParsing `
            -Headers @{ 'User-Agent' = 'CloudDrives-Installer'; Accept = 'application/vnd.github+json' }
    }
    $version = ([string]$release.tag_name).TrimStart('v', 'V')
    $packageName = "CloudDrives-$version.zip"
    $package = @($release.assets) | Where-Object { $_.name -eq $packageName } | Select-Object -First 1
    $sums = @($release.assets) | Where-Object { $_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1
    if (-not $package -or -not $sums) { throw "Release $($release.tag_name) is incomplete." }

    $work = Join-Path ([IO.Path]::GetTempPath()) ('clouddrives-install-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $work -Force)
    try {
        $zip = Join-Path $work $packageName
        $sumFile = Join-Path $work 'SHA256SUMS.txt'
        foreach ($pair in @(@($package.browser_download_url, $zip), @($sums.browser_download_url, $sumFile))) {
            if ($pair[0] -match '^https?://') { Invoke-WebRequest -Uri $pair[0] -OutFile $pair[1] -UseBasicParsing -Headers @{ 'User-Agent' = 'CloudDrives-Installer' } }
            else { Copy-Item -LiteralPath $pair[0] -Destination $pair[1] -Force }
        }
        Say "Version $version heruntergeladen." "Version $version downloaded."

        $expected = $null
        foreach ($line in ([IO.File]::ReadAllText($sumFile) -split "`n")) {
            if ($line -match "^([0-9a-fA-F]{64})\s+\*?$([regex]::Escape($packageName))\s*$") { $expected = $Matches[1].ToLowerInvariant() }
        }
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not $expected -or $actual -ne $expected) { throw "Checksum mismatch for $packageName - installation aborted." }
        # Kept ASCII-only on purpose: "irm | iex" may decode the script with a non-UTF-8 code page.
        Say "Pr$([char]0x00FC)fsumme (SHA256) ist korrekt." 'Checksum (SHA256) verified.' Green

        $extracted = Join-Path $work 'package'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $extracted)

        # The package installs itself; Windows PowerShell 5.1 is always present. A PowerShell 7 module path
        # would make it load incompatible core modules, so the child process gets the default path.
        $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $modulePath = $env:PSModulePath
        try {
            $env:PSModulePath = $null
            & $powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $extracted 'src\CloudDrives.ps1') install --desktop
        }
        finally { $env:PSModulePath = $modulePath }
        if ($LASTEXITCODE -ne 0) { throw "Installation failed (exit code $LASTEXITCODE)." }
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }

    $installDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\CloudDrives'
    if ($env:CLOUDDRIVES_INSTALL_DIR) { $installDir = $env:CLOUDDRIVES_INSTALL_DIR }
    if ($env:CLOUDDRIVES_INSTALL_NOSTART -ne '1') {
        Say 'CloudDrives wird gestartet ...' 'Starting CloudDrives ...'
        Start-Process -FilePath (Join-Path $installDir 'CloudDrives.bat') -WorkingDirectory ([Environment]::GetFolderPath('UserProfile'))
    }
}
