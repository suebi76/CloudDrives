# rclone dependency: locate, verify and install a pinned version (SHA256 verified).
# Resolution order: managed copy in <home>\deps\rclone\<version> -> rclone on PATH (if new enough) -> download -> winget.

$script:CdDependencies = $null

function Get-CdDependencyInfo {
    if (-not $script:CdDependencies) {
        $file = Join-Path (Get-CdContext).ResourcesDir 'dependencies.json'
        $script:CdDependencies = ConvertTo-CdHashtable ([IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json)
    }
    $script:CdDependencies
}

function Get-CdArchitecture {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    switch ($arch) {
        'ARM64' { 'arm64' }
        'x86' { '386' }
        default { 'amd64' }
    }
}

function Get-CdRcloneVersion {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $run = Invoke-CdProcess -FilePath $Path -ArgumentList @('version') -TimeoutSec 30
        if ($run.ExitCode -eq 0 -and $run.StdOut -match 'rclone v(\d+\.\d+\.\d+)') { return [version]$Matches[1] }
    }
    catch { Write-CdLog -Level WARN -Component 'Deps' -Message "rclone version check failed for '$Path': $($_.Exception.Message)" }
    $null
}

function Find-CdRclone {
    # Returns the best usable rclone as @{ Path; Version; Source } or $null.
    $deps = Get-CdDependencyInfo
    $minimum = [version]$deps.rclone.minimumVersion
    $managedRoot = Join-Path (Get-CdContext).DepsDir 'rclone'
    if (Test-Path -LiteralPath $managedRoot) {
        $candidates = foreach ($dir in Get-ChildItem -LiteralPath $managedRoot -Directory) {
            $exe = Join-Path $dir.FullName 'rclone.exe'
            $version = $null
            if ((Test-Path -LiteralPath $exe) -and [version]::TryParse($dir.Name, [ref]$version)) {
                [pscustomobject]@{ Path = $exe; Version = $version; Source = 'managed' }
            }
        }
        $best = @($candidates) | Where-Object { $_ -and $_.Version -ge $minimum } | Sort-Object -Property Version -Descending | Select-Object -First 1
        if ($best) { return $best }
    }
    $onPath = Get-Command -Name 'rclone.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) {
        $version = Get-CdRcloneVersion -Path $onPath.Source
        if ($version -and $version -ge $minimum) { return [pscustomobject]@{ Path = $onPath.Source; Version = $version; Source = 'path' } }
    }
    $null
}

function Get-CdRcloneChecksum {
    # Reads the official SHA256SUMS for a version that is not pinned in dependencies.json.
    param([Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Arch)
    $sums = Get-CdWebText -Uri "https://downloads.rclone.org/v$Version/SHA256SUMS"
    $fileName = "rclone-v$Version-windows-$Arch.zip"
    foreach ($line in ($sums -split "`n")) {
        if ($line -match "^([0-9a-fA-F]{64})\s+\*?$([regex]::Escape($fileName))\s*$") { return $Matches[1].ToLowerInvariant() }
    }
    throw (New-CdException -Code 'CD-1006' -Detail "no checksum for $fileName")
}

function Install-CdRclone {
    # Downloads rclone - by default the pinned version, checked against its SHA256 checksum in
    # dependencies.json - into the data folder (deps\rclone\<version>).
    param([string]$Version)
    $deps = Get-CdDependencyInfo
    if (-not $Version) { $Version = [string]$deps.rclone.version }
    $arch = Get-CdArchitecture
    $expected = $null
    if ($Version -eq [string]$deps.rclone.version) { $expected = [string]$deps.rclone.sha256[$arch] }

    Initialize-CdHome
    $work = Join-Path ([IO.Path]::GetTempPath()) ('clouddrives-rclone-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $work -Force)
    try {
        $zip = Join-Path $work 'rclone.zip'
        $failures = New-Object System.Collections.Generic.List[string]
        $downloaded = $false
        foreach ($template in @($deps.rclone.downloadUrls)) {
            $uri = $template.Replace('{version}', $Version).Replace('{arch}', $arch)
            try { Invoke-CdDownload -Uri $uri -OutFile $zip; $downloaded = $true; break }
            catch { $failures.Add($_.Exception.Message) }
        }
        if (-not $downloaded) {
            Write-CdLog -Level WARN -Component 'Deps' -Message 'Direct download failed, trying winget.'
            $viaWinget = Install-CdRcloneWithWinget
            if ($viaWinget) { return $viaWinget }
            throw (New-CdException -Code 'CD-1004' -Detail ($failures -join ' | '))
        }

        if (-not $expected) { $expected = Get-CdRcloneChecksum -Version $Version -Arch $arch }
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected.ToLowerInvariant()) {
            throw (New-CdException -Code 'CD-1006' -Detail "rclone $Version ${arch}: expected $expected, got $actual")
        }
        Write-CdLog -Component 'Deps' -Message "rclone $Version ($arch) checksum verified."

        $extractDir = Join-Path $work 'x'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $extractDir)
        $exe = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter 'rclone.exe' | Select-Object -First 1
        if (-not $exe) { throw (New-CdException -Code 'CD-1001' -Detail 'rclone.exe not found in archive') }

        $target = Join-Path (Join-Path (Get-CdContext).DepsDir 'rclone') $Version
        if (-not (Test-Path -LiteralPath $target)) { [void](New-Item -ItemType Directory -Path $target -Force) }
        $targetExe = Join-Path $target 'rclone.exe'
        Copy-Item -LiteralPath $exe.FullName -Destination $targetExe -Force

        $installed = Get-CdRcloneVersion -Path $targetExe
        if (-not $installed) { throw (New-CdException -Code 'CD-1001' -Detail 'self-test of the downloaded rclone failed') }
        Write-CdLog -Component 'Deps' -Message "rclone $installed installed to $target."
        [pscustomobject]@{ Path = $targetExe; Version = $installed; Source = 'managed' }
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-CdRcloneWithWinget {
    # The fallback when the download fails: rclone through winget, used when it has at least the minimum
    # version; $null otherwise.
    $winget = Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue
    if (-not $winget) { return $null }
    $deps = Get-CdDependencyInfo
    $run = Invoke-CdProcess -FilePath $winget.Source -ArgumentList @('install', '--id', $deps.rclone.wingetId, '--exact', '--source', 'winget', '--silent', '--disable-interactivity') -TimeoutSec 900
    Write-CdLog -Component 'Deps' -Message "winget rclone exit code $($run.ExitCode)"
    # winget links portable packages here; the current process PATH does not know it yet.
    $links = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Microsoft\WinGet\Links\rclone.exe'
    foreach ($candidate in @($links)) {
        if (Test-Path -LiteralPath $candidate) {
            $version = Get-CdRcloneVersion -Path $candidate
            if ($version -and $version -ge [version]$deps.rclone.minimumVersion) {
                return [pscustomobject]@{ Path = $candidate; Version = $version; Source = 'winget' }
            }
        }
    }
    $null
}

function Resolve-CdRclone {
    # Finds a usable rclone or installs the pinned version when allowed.
    param([switch]$AllowInstall)
    $found = Find-CdRclone
    if ($found) { return $found }
    if (-not $AllowInstall) { throw (New-CdException -Code 'CD-1001') }
    Install-CdRclone
}
