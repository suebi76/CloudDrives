# WinFsp dependency: the Windows file system driver rclone needs for drive letters.
# Installing it requires administrator rights once (UAC prompt); everything else runs as the user.

function Get-CdWinFsp {
    # Returns @{ InstallDir; Version; LauncherStatus } or $null when WinFsp is not installed.
    $installDir = $null
    foreach ($key in @('HKLM:\SOFTWARE\WOW6432Node\WinFsp', 'HKLM:\SOFTWARE\WinFsp')) {
        $props = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($props -and $props.InstallDir) { $installDir = [string]$props.InstallDir; break }
    }
    if (-not $installDir) { return $null }

    $dllName = 'winfsp-x64.dll'
    switch (Get-CdArchitecture) {
        'arm64' { $dllName = 'winfsp-a64.dll' }
        '386' { $dllName = 'winfsp-x86.dll' }
    }
    $dll = Join-Path $installDir "bin\$dllName"
    if (-not (Test-Path -LiteralPath $dll)) { return $null }

    $info = (Get-Item -LiteralPath $dll).VersionInfo
    $service = Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue
    $launcher = 'Missing'
    if ($service) { $launcher = [string]$service.Status }
    [pscustomobject]@{
        InstallDir     = $installDir
        Version        = New-Object Version($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart)
        Dll            = $dll
        LauncherStatus = $launcher
    }
}

function Test-CdWinFsp {
    $winfsp = Get-CdWinFsp
    if (-not $winfsp) { return $false }
    $winfsp.Version -ge [version](Get-CdDependencyInfo).winfsp.minimumVersion
}

function Install-CdWinFsp {
    # Installs WinFsp via winget, falling back to the verified MSI from GitHub. Shows one UAC prompt.
    $deps = Get-CdDependencyInfo
    $winget = Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue
    if ($winget) {
        Write-CdLog -Component 'Deps' -Message 'Installing WinFsp with winget.'
        $run = Invoke-CdProcess -FilePath $winget.Source -ArgumentList @('install', '--id', $deps.winfsp.wingetId, '--exact', '--source', 'winget', '--silent', '--disable-interactivity') -TimeoutSec 1200
        Write-CdLog -Component 'Deps' -Message "winget WinFsp exit code $($run.ExitCode)"
        if (Test-CdWinFsp) { return (Get-CdWinFsp) }
    }

    Write-CdLog -Component 'Deps' -Message 'Installing WinFsp from the verified MSI.'
    $work = Join-Path ([IO.Path]::GetTempPath()) ('clouddrives-winfsp-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $work -Force)
    try {
        $msi = Join-Path $work 'winfsp.msi'
        Invoke-CdDownload -Uri $deps.winfsp.msiUrl -OutFile $msi
        if (-not (Test-CdFileHash -Path $msi -Sha256 $deps.winfsp.sha256)) {
            throw (New-CdException -Code 'CD-1006' -Detail 'WinFsp MSI checksum mismatch')
        }
        $signature = Get-AuthenticodeSignature -FilePath $msi
        if ($signature.Status -ne 'Valid') {
            throw (New-CdException -Code 'CD-1006' -Detail "WinFsp MSI signature status: $($signature.Status)")
        }
        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$msi`"", '/qb', '/norestart') -Verb RunAs -Wait -PassThru
        Write-CdLog -Component 'Deps' -Message "msiexec WinFsp exit code $($process.ExitCode)"
    }
    catch [System.InvalidOperationException] {
        throw (New-CdException -Code 'CD-1007' -Detail $_.Exception.Message -InnerException $_.Exception)
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-CdWinFsp)) { throw (New-CdException -Code 'CD-1002') }
    Get-CdWinFsp
}
