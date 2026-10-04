# Updates from GitHub releases: the package (ZIP) is verified against the release's SHA256SUMS.txt and then
# installed like a fresh installation (with rollback on failure). CLOUDDRIVES_RELEASE_SOURCE may point to a
# local folder containing release.json and the assets (used by tests and offline installations).

function Get-CdManifestVersion {
    param([Parameter(Mandatory)][string]$Path)
    $text = [IO.File]::ReadAllText($Path)
    if ($text -match "ModuleVersion\s*=\s*'([0-9][0-9.]*)'") { return [version]$Matches[1] }
    $null
}

function Get-CdLatestRelease {
    # The newest published release as @{ Version; Tag; PackageUrl; PackageName; ChecksumUrl }, or $null.
    $info = Get-CdAppInfo
    $release = $null
    if ($env:CLOUDDRIVES_RELEASE_SOURCE) {
        $file = Join-Path $env:CLOUDDRIVES_RELEASE_SOURCE 'release.json'
        if (-not (Test-Path -LiteralPath $file)) { return $null }
        $release = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    else {
        Initialize-CdTls
        try {
            $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$($info.repository)/releases/latest" -UseBasicParsing -TimeoutSec 30 `
                -Headers @{ 'User-Agent' = "CloudDrives/$((Get-CdContext).Version)"; Accept = 'application/vnd.github+json' }
        }
        catch {
            $status = 0
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if ($status -eq 404) { return $null }
            throw (New-CdException -Code 'CD-5001' -Detail "release check: $($_.Exception.Message)" -InnerException $_.Exception)
        }
    }
    $tag = [string]$release.tag_name
    $version = $null
    if (-not [version]::TryParse($tag.TrimStart('v', 'V'), [ref]$version)) { return $null }
    $packageName = ([string]$info.packageName).Replace('{version}', $version.ToString())
    $package = @($release.assets) | Where-Object { $_.name -eq $packageName } | Select-Object -First 1
    $checksums = @($release.assets) | Where-Object { $_.name -eq $info.checksumFile } | Select-Object -First 1
    if (-not $package -or -not $checksums) { throw (New-CdException -Code 'CD-8005' -Detail "release $tag lacks $packageName or $($info.checksumFile)") }
    [pscustomobject]@{
        Version     = $version
        Tag         = $tag
        PackageName = $packageName
        PackageUrl  = [string]$package.browser_download_url
        ChecksumUrl = [string]$checksums.browser_download_url
    }
}

function Save-CdReleaseFile {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$OutFile)
    if ($Url -match '^https?://') { Invoke-CdDownload -Uri $Url -OutFile $OutFile }
    else { Copy-Item -LiteralPath $Url -Destination $OutFile -Force }
}

function Get-CdChecksumFromList {
    # Reads the hash of one file from a "sha256sum" style list ("<hash>  <file name>").
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$FileName)
    foreach ($line in ($Text -split "`n")) {
        if ($line -match "^([0-9a-fA-F]{64})\s+\*?$([regex]::Escape($FileName))\s*$") { return $Matches[1].ToLowerInvariant() }
    }
    $null
}

function Get-CdUpdateState {
    $current = [version](Get-CdContext).Version
    $latest = Get-CdLatestRelease
    [pscustomobject]@{
        Current   = $current
        Latest    = $(if ($latest) { $latest.Version } else { $null })
        Available = [bool]($latest -and $latest.Version -gt $current)
        Release   = $latest
    }
}

function Invoke-CdBackgroundUpdateCheck {
    # At most once a day after an autostart: notify about a newer release. It never installs on its own.
    try {
        $settings = Get-CdSettings
        $today = (Get-Date).ToString('yyyy-MM-dd')
        if ($settings.lastUpdateCheck -eq $today) { return }
        $settings.lastUpdateCheck = $today
        Save-CdSettings -Settings $settings
        $state = Get-CdUpdateState
        if ($state.Available -and $settings.notifications -ne 'off') {
            [void](Show-CdNotification -Title 'CloudDrives' -Message (Get-CdText 'update.notify' ([string]$state.Latest)))
        }
    }
    catch { Write-CdLog -Level DEBUG -Component 'Update' -Message "Background update check: $($_.Exception.Message)" }
}

function Install-CdUpdate {
    # Downloads, verifies and installs the newest release. Returns a result (also when already up to date).
    # $OnProgress gets the status text of each step.
    param([scriptblock]$OnProgress)
    Send-CdProgress -OnProgress $OnProgress -Text (Get-CdText 'update.checking')
    $state = Get-CdUpdateState
    if (-not $state.Release) { return (New-CdResult -Code 'CD-8004' -Success $false -Message (Get-CdText 'error.CD-8004.title')) }
    if (-not $state.Available) { return (New-CdResult -Message (Get-CdText 'update.upToDate' ([string]$state.Current))) }

    $release = $state.Release
    $work = Join-Path ([IO.Path]::GetTempPath()) ('clouddrives-update-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $work -Force)
    try {
        $zip = Join-Path $work $release.PackageName
        $sums = Join-Path $work 'SHA256SUMS.txt'
        Send-CdProgress -OnProgress $OnProgress -Text (Get-CdText 'progress.download' ([string]$release.Version))
        Save-CdReleaseFile -Url $release.PackageUrl -OutFile $zip
        Save-CdReleaseFile -Url $release.ChecksumUrl -OutFile $sums
        Send-CdProgress -OnProgress $OnProgress -Text (Get-CdText 'progress.verify')
        $expected = Get-CdChecksumFromList -Text ([IO.File]::ReadAllText($sums)) -FileName $release.PackageName
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not $expected -or $actual -ne $expected) { throw (New-CdException -Code 'CD-1006' -Detail "update package: expected $expected, got $actual") }

        $extracted = Join-Path $work 'package'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $extracted)
        $manifest = Join-Path $extracted 'src\CloudDrives.psd1'
        if (-not (Test-Path -LiteralPath $manifest) -or (Get-CdManifestVersion -Path $manifest) -ne $release.Version) {
            throw (New-CdException -Code 'CD-8005' -Detail 'package content does not match the release')
        }
        Send-CdProgress -OnProgress $OnProgress -Text (Get-CdText 'progress.install' ([string]$release.Version))
        $result = Install-CdApplication -SourceRoot $extracted -NoShortcuts
        Write-CdLog -Component 'Update' -Message "Updated from $($state.Current) to $($release.Version)."
        New-CdResult -Message (Get-CdText 'update.done' ([string]$release.Version)) -Data $result.Data
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
