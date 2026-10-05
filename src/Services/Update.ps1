# Updates from GitHub releases: the package (ZIP) is verified against the release's SHA256SUMS.txt and then
# installed like a fresh installation (with rollback on failure). CLOUDDRIVES_RELEASE_SOURCE may point to a
# local folder containing release.json (one release or a list of them) and the assets (used by tests and offline
# installations).
#
# How new versions arrive is the setting "updates":
#   notify     (default) look every few hours and tell the user once per version; the symbol in the notification
#              area then installs it with one click
#   automatic  install it in the background as soon as no CloudDrives window is open
#   manual     never look on its own; "Nach Updates suchen" in the menu does
# With "testVersions" GitHub pre-releases count as well. Test versions carry a label (0.3.3-preview.1); in the
# module manifest it is PrivateData.PSData.Prerelease, as PowerShellGet keeps it.

$script:CdUpdatePeriod = [TimeSpan]::FromHours(6)
$script:CdWindowMarker = $null

function ConvertTo-CdVersion {
    # "0.3.3", "v0.3.3" or "0.3.3-preview.1" as @{ Number = [version]; Label = 'preview.1' }, otherwise $null.
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    if ($Text.Trim() -notmatch '^[vV]?(\d+(?:\.\d+){1,3})(?:-([0-9A-Za-z.-]+))?$') { return $null }
    [pscustomobject]@{ Number = [version]$Matches[1]; Label = [string]$Matches[2] }
}

function Compare-CdVersion {
    # -1, 0 or 1, ordered like semantic versions: a test version comes before its release (0.3.3-preview.2 < 0.3.3)
    # and numbers in labels count as numbers (preview.10 > preview.9). Text that is no version counts as the oldest.
    param([AllowNull()][AllowEmptyString()][string]$Left, [AllowNull()][AllowEmptyString()][string]$Right)
    $a = ConvertTo-CdVersion $Left
    $b = ConvertTo-CdVersion $Right
    if (-not $a -or -not $b) { return ([int][bool]$a) - ([int][bool]$b) }
    $byNumber = $a.Number.CompareTo($b.Number)
    if ($byNumber -ne 0) { return [Math]::Sign($byNumber) }
    if ($a.Label -ceq $b.Label) { return 0 }
    if (-not $a.Label) { return 1 }
    if (-not $b.Label) { return -1 }
    $x = $a.Label.Split('.')
    $y = $b.Label.Split('.')
    for ($i = 0; $i -lt [Math]::Min($x.Count, $y.Count); $i++) {
        $xNumber = $x[$i] -match '^\d+$'
        $yNumber = $y[$i] -match '^\d+$'
        if ($xNumber -and $yNumber) { $order = ([decimal]$x[$i]).CompareTo([decimal]$y[$i]) }
        elseif ($xNumber) { $order = -1 }
        elseif ($yNumber) { $order = 1 }
        else { $order = [string]::CompareOrdinal($x[$i], $y[$i]) }
        if ($order -ne 0) { return [Math]::Sign($order) }
    }
    [Math]::Sign($x.Count.CompareTo($y.Count))
}

function Get-CdManifestVersion {
    # The version a module manifest describes, a test version with its label ("0.3.3-preview.1"); $null without one.
    param([Parameter(Mandatory)][string]$Path)
    $text = [IO.File]::ReadAllText($Path)
    if ($text -notmatch "ModuleVersion\s*=\s*'([0-9][0-9.]*)'") { return $null }
    $version = $Matches[1]
    if ($text -match "Prerelease\s*=\s*'([0-9A-Za-z.-]+)'") { $version += '-' + $Matches[1] }
    $version
}

function Get-CdReleaseList {
    # The newest releases (test versions included) as GitHub describes them.
    $info = Get-CdAppInfo
    if ($env:CLOUDDRIVES_RELEASE_SOURCE) {
        $file = Join-Path $env:CLOUDDRIVES_RELEASE_SOURCE 'release.json'
        if (-not (Test-Path -LiteralPath $file)) { return }
        $releases = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    else {
        Initialize-CdTls
        try {
            $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$($info.repository)/releases?per_page=30" -UseBasicParsing -TimeoutSec 30 `
                -Headers @{ 'User-Agent' = "CloudDrives/$((Get-CdContext).Version)"; Accept = 'application/vnd.github+json' }
        }
        catch {
            $status = 0
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if ($status -eq 404) { return }
            throw (New-CdException -Code 'CD-5001' -Detail "release check: $($_.Exception.Message)" -InnerException $_.Exception)
        }
    }
    # Windows PowerShell hands a JSON list over as one object: one release at a time.
    foreach ($release in $releases) { $release }
}

function Select-CdRelease {
    # The newest release as @{ Version; Tag; PackageName; PackageUrl; ChecksumUrl; TestVersion }, or $null.
    # Drafts never count, test versions (pre-releases) only with -TestVersions.
    param([AllowEmptyCollection()][object[]]$Releases = @(), [switch]$TestVersions)
    $newest = $null
    $newestVersion = $null
    foreach ($release in @($Releases)) {
        if (-not $release -or $release.draft) { continue }
        $tag = [string]$release.tag_name
        $parsed = ConvertTo-CdVersion $tag
        if (-not $parsed) { continue }
        if (($release.prerelease -or $parsed.Label) -and -not $TestVersions) { continue }
        $version = $tag.TrimStart('v', 'V')
        if ($newest -and (Compare-CdVersion $version $newestVersion) -le 0) { continue }
        $newest = $release
        $newestVersion = $version
    }
    if (-not $newest) { return $null }
    $info = Get-CdAppInfo
    $packageName = ([string]$info.packageName).Replace('{version}', $newestVersion)
    $package = @($newest.assets) | Where-Object { $_.name -eq $packageName } | Select-Object -First 1
    $checksums = @($newest.assets) | Where-Object { $_.name -eq $info.checksumFile } | Select-Object -First 1
    if (-not $package -or -not $checksums) { throw (New-CdException -Code 'CD-8005' -Detail "release $($newest.tag_name) lacks $packageName or $($info.checksumFile)") }
    [pscustomobject]@{
        Version     = $newestVersion
        Tag         = [string]$newest.tag_name
        PackageName = $packageName
        PackageUrl  = [string]$package.browser_download_url
        ChecksumUrl = [string]$checksums.browser_download_url
        TestVersion = [bool]($newest.prerelease -or (ConvertTo-CdVersion $newestVersion).Label)
    }
}

function Get-CdLatestRelease {
    # The newest published release (see Select-CdRelease), or $null.
    param([switch]$TestVersions)
    Select-CdRelease -Releases @(Get-CdReleaseList) -TestVersions:$TestVersions
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
    # Looks on GitHub: the running version, the newest one (test versions as the setting says) and whether it is newer.
    # What it found is noted (state\update.json), so the menu and the symbol know it without looking again.
    $current = [string](Get-CdContext).Version
    $latest = Get-CdLatestRelease -TestVersions:([bool](Get-CdSettings).testVersions)
    $record = Read-CdUpdateCheck
    $record.checkedTicks = (Get-Date).ToUniversalTime().Ticks
    $record.latest = $(if ($latest) { $latest.Version } else { '' })
    Save-CdUpdateCheck -Record $record
    [pscustomobject]@{
        Current   = $current
        Latest    = $(if ($latest) { $latest.Version } else { $null })
        Available = [bool]($latest -and (Compare-CdVersion $latest.Version $current) -gt 0)
        Release   = $latest
    }
}

function Get-CdUpdateCheckFile {
    Join-Path (Get-CdContext).StateDir 'update.json'
}

function Read-CdUpdateCheck {
    # What the last look on GitHub found: checkedTicks (UTC), latest (the newest version then) and announced (the
    # version the user has been told about).
    $record = [ordered]@{ checkedTicks = [long]0; latest = ''; announced = '' }
    $file = Get-CdUpdateCheckFile
    if (-not (Test-Path -LiteralPath $file)) { return $record }
    try {
        $data = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($null -ne $data.checkedTicks) { $record.checkedTicks = [long]$data.checkedTicks }
        if ($null -ne $data.latest) { $record.latest = [string]$data.latest }
        if ($null -ne $data.announced) { $record.announced = [string]$data.announced }
    }
    catch { Write-CdLog -Level DEBUG -Component 'Update' -Message "Check record unreadable, starting fresh: $($_.Exception.Message)" }
    $record
}

function Save-CdUpdateCheck {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Record)
    Write-CdStateFile -Path (Get-CdUpdateCheckFile) -Text (ConvertTo-Json -InputObject $Record)
}

function Reset-CdUpdateCheck {
    # The way updates arrive or the test versions changed: forget what was found, so the next look comes soon.
    Save-CdUpdateCheck -Record ([ordered]@{ checkedTicks = [long]0; latest = ''; announced = '' })
}

function Get-CdPendingUpdate {
    # The newer version the last look on GitHub found, or $null - without looking again.
    if (-not (Test-CdInstalled)) { return $null }
    $latest = [string](Read-CdUpdateCheck).latest
    if ($latest -and (Compare-CdVersion $latest ([string](Get-CdContext).Version)) -gt 0) { return $latest }
    $null
}

function Test-CdUpdateCheckDue {
    # Whether CloudDrives should look on GitHub on its own: it is installed, the setting is not "manual" and the last
    # look was a few hours ago (or lies in the future because the clock was put back).
    param([System.Collections.IDictionary]$Record)
    if (-not (Test-CdInstalled) -or (Get-CdSettings).updates -eq 'manual') { return $false }
    if (-not $Record) { $Record = Read-CdUpdateCheck }
    $age = (Get-Date).ToUniversalTime() - [datetime]::new([long]$Record.checkedTicks, [DateTimeKind]::Utc)
    $age -ge $script:CdUpdatePeriod -or $age -lt [TimeSpan]::Zero
}

function Get-CdWindowMarkerName {
    "Local\CloudDrives-$((Get-CdContext).HomeId)-window"
}

function Register-CdWindow {
    # Marks this process as an open CloudDrives window (menu, wizard, diagnosis) until it ends. Automatic updates wait
    # for it: the window runs the program files an update replaces.
    if (-not $script:CdWindowMarker) { $script:CdWindowMarker = New-Object System.Threading.Mutex($false, (Get-CdWindowMarkerName)) }
}

function Test-CdWindowOpen {
    $marker = $null
    if ([System.Threading.Mutex]::TryOpenExisting((Get-CdWindowMarkerName), [ref]$marker)) {
        $marker.Dispose()
        return $true
    }
    $false
}

function Invoke-CdBackgroundUpdateCheck {
    # Runs hidden after the autostart and every few hours for the symbol in the notification area. Looks on GitHub when
    # it is time, then - as the setting says - tells the user once per version, or installs the new version as soon as
    # no CloudDrives window is open. Returns what happened: none, announced, waiting or installed.
    $lock = $null
    try {
        if (-not (Test-CdInstalled)) { return 'none' }
        $settings = Get-CdSettings
        if ($settings.updates -eq 'manual') { return 'none' }
        # Another CloudDrives process is looking or installing right now.
        $lock = Enter-CdLock -Name 'update' -TimeoutSec 0
        $record = Read-CdUpdateCheck
        if (Test-CdUpdateCheckDue -Record $record) {
            # Noted first: a look that fails waits for the next period, too.
            $record.checkedTicks = (Get-Date).ToUniversalTime().Ticks
            Save-CdUpdateCheck -Record $record
            [void](Get-CdUpdateState)
            $record = Read-CdUpdateCheck
        }
        $pending = Get-CdPendingUpdate
        if (-not $pending) { return 'none' }

        if ($settings.updates -eq 'automatic') {
            if (Test-CdWindowOpen) {
                Write-CdLog -Level DEBUG -Component 'Update' -Message "Version $pending waits until no CloudDrives window is open."
                return 'waiting'
            }
            Write-CdLog -Component 'Update' -Message "Installing version $pending automatically."
            try { $result = Install-CdUpdate }
            catch {
                # Forget the version: the next regular look tries again, instead of every few minutes.
                $record.latest = ''
                Save-CdUpdateCheck -Record $record
                throw
            }
            if (-not $result.Data) { return 'none' }
            if ($settings.notifications -eq 'all') { [void](Show-CdNotification -Title 'CloudDrives' -Message $result.Message) }
            return 'installed'
        }

        if ($record.announced -eq $pending) { return 'none' }
        $record.announced = $pending
        Save-CdUpdateCheck -Record $record
        if ($settings.notifications -ne 'off') {
            $text = Get-CdText 'update.notify' $pending
            if (Test-CdTrayRunning) { $text = Get-CdText 'update.notifyTray' $pending }
            [void](Show-CdNotification -Title 'CloudDrives' -Message $text)
        }
        'announced'
    }
    catch {
        # CD-9002: another CloudDrives process is on it.
        $level = 'INFO'
        if ((Get-CdErrorCode $_) -eq 'CD-9002') { $level = 'DEBUG' }
        Write-CdLog -Level $level -Component 'Update' -Message "Background update check: $($_.Exception.Message)"
        'none'
    }
    finally { Exit-CdLock -Mutex $lock }
}

function Install-CdUpdate {
    # Downloads, verifies and installs the newest release. Returns a result (also when already up to date).
    # $OnProgress gets the status text of each step.
    param([scriptblock]$OnProgress)
    # One update at a time: a background installation finishes first (this one then finds nothing newer).
    $lock = Enter-CdLock -Name 'update' -TimeoutSec 300
    try {
        Send-CdProgress -OnProgress $OnProgress -Text (Get-CdText 'update.checking')
        $state = Get-CdUpdateState
        if (-not $state.Release) { return (New-CdResult -Code 'CD-8004' -Success $false -Message (Get-CdText 'error.CD-8004.title')) }
        if (-not $state.Available) { return (New-CdResult -Message (Get-CdText 'update.upToDate' $state.Current)) }

        $release = $state.Release
        $work = Join-Path ([IO.Path]::GetTempPath()) ('clouddrives-update-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $work -Force)
        try {
            $zip = Join-Path $work $release.PackageName
            $sums = Join-Path $work 'SHA256SUMS.txt'
            Send-CdProgress -OnProgress $OnProgress -Text (Get-CdText 'progress.download' $release.Version)
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
            if (-not (Test-Path -LiteralPath $manifest) -or (Compare-CdVersion (Get-CdManifestVersion -Path $manifest) $release.Version) -ne 0) {
                throw (New-CdException -Code 'CD-8005' -Detail 'package content does not match the release')
            }
            Send-CdProgress -OnProgress $OnProgress -Text (Get-CdText 'progress.install' $release.Version)
            $result = Install-CdApplication -SourceRoot $extracted -NoShortcuts
            Write-CdLog -Component 'Update' -Message "Updated from $($state.Current) to $($release.Version)."
            New-CdResult -Message (Get-CdText 'update.done' $release.Version) -Data $result.Data
        }
        finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    finally { Exit-CdLock -Mutex $lock }
}
