# Installation into %LOCALAPPDATA%\Programs\CloudDrives (no administrator rights), shortcuts and uninstall.
# CLOUDDRIVES_INSTALL_DIR and CLOUDDRIVES_SHORTCUT_DIR override the locations (used by tests).

$script:CdAppInfo = $null

function Get-CdAppInfo {
    if (-not $script:CdAppInfo) {
        $file = Join-Path (Get-CdContext).ResourcesDir 'app.json'
        $script:CdAppInfo = ConvertTo-CdHashtable ([IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json)
    }
    $script:CdAppInfo
}

function Get-CdInstallDir {
    if ($env:CLOUDDRIVES_INSTALL_DIR) { return [IO.Path]::GetFullPath($env:CLOUDDRIVES_INSTALL_DIR).TrimEnd('\') }
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\CloudDrives'
}

function Test-CdInstalled {
    # True when this copy of CloudDrives runs from the install directory.
    [string]::Equals((Get-CdContext).AppRoot.TrimEnd('\'), (Get-CdInstallDir), [StringComparison]::OrdinalIgnoreCase)
}

function Get-CdShortcutPaths {
    $startMenu = [Environment]::GetFolderPath('Programs')
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ($env:CLOUDDRIVES_SHORTCUT_DIR) {
        $startMenu = Join-Path $env:CLOUDDRIVES_SHORTCUT_DIR 'StartMenu'
        $desktop = Join-Path $env:CLOUDDRIVES_SHORTCUT_DIR 'Desktop'
    }
    [pscustomobject]@{
        StartMenu = Join-Path $startMenu 'CloudDrives.lnk'
        Desktop   = Join-Path $desktop 'CloudDrives.lnk'
    }
}

function New-CdShortcut {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target,
        [string]$WorkingDirectory,
        [string]$Icon,
        [string]$Description
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($Path)
    $link.TargetPath = $Target
    if ($WorkingDirectory) { $link.WorkingDirectory = $WorkingDirectory }
    if ($Icon) { $link.IconLocation = "$Icon,0" }
    if ($Description) { $link.Description = $Description }
    $link.Save()
}

function Get-CdNeutralDirectory {
    # Working directory for everything CloudDrives starts: never the program folder, because Windows locks
    # the working directory of a process and an update could then not replace the folder.
    [Environment]::GetFolderPath('UserProfile')
}

function Install-CdShortcuts {
    param([Parameter(Mandatory)][string]$AppRoot, [switch]$Desktop)
    $paths = Get-CdShortcutPaths
    $targets = @($paths.StartMenu)
    if ($Desktop) { $targets += $paths.Desktop }
    foreach ($path in $targets) {
        New-CdShortcut -Path $path -Target (Join-Path $AppRoot 'CloudDrives.bat') -WorkingDirectory (Get-CdNeutralDirectory) `
            -Icon (Join-Path $AppRoot 'src\Resources\icons\clouddrives.ico') -Description (Get-CdText 'install.shortcutDescription')
    }
    $targets
}

function Start-CdInstalledApplication {
    # Opens the installed CloudDrives in a new window (after an installation or update); the caller then ends.
    $bat = Join-Path (Get-CdInstallDir) 'CloudDrives.bat'
    if (-not (Test-Path -LiteralPath $bat)) { throw (New-CdException -Code 'CD-8001' -Detail "no CloudDrives application in '$(Get-CdInstallDir)'") }
    $parameters = @{ FilePath = $bat; WorkingDirectory = (Get-CdNeutralDirectory) }
    $ctx = Get-CdContext
    if (-not $ctx.IsDefaultHome) { $parameters.ArgumentList = ConvertTo-CdArgumentString -ArgumentList @("--home=$($ctx.Home)") }
    Start-Process @parameters
}

function Move-CdDirectory {
    # Renames a folder. Virus scanners and the search indexer may hold files for a moment, so retry briefly.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Destination)
    for ($attempt = 1; ; $attempt++) {
        try { [IO.Directory]::Move($Path, $Destination); return }
        catch {
            if ($attempt -ge 5) { throw }
            Start-Sleep -Milliseconds (200 * $attempt)
        }
    }
}

function Remove-CdShortcuts {
    $paths = Get-CdShortcutPaths
    foreach ($path in @($paths.StartMenu, $paths.Desktop)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}

function Copy-CdApplicationFiles {
    # Copies the package items (see Resources\app.json) from one application root to another folder.
    param([Parameter(Mandatory)][string]$SourceRoot, [Parameter(Mandatory)][string]$Destination)
    if (-not (Test-Path -LiteralPath $Destination)) { [void](New-Item -ItemType Directory -Path $Destination -Force) }
    foreach ($item in @((Get-CdAppInfo).packageItems)) {
        $source = Join-Path $SourceRoot $item
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $Destination -Recurse -Force }
    }
}

function Install-CdApplication {
    # Installs (or replaces) CloudDrives in the install directory and creates the shortcuts.
    param(
        [string]$SourceRoot,
        [switch]$Desktop,
        [switch]$NoShortcuts
    )
    if (-not $SourceRoot) { $SourceRoot = (Get-CdContext).AppRoot }
    $source = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    $target = Get-CdInstallDir
    if (-not (Test-Path -LiteralPath (Join-Path $source 'src\CloudDrives.psd1')) -or -not (Test-Path -LiteralPath (Join-Path $source 'CloudDrives.bat'))) {
        throw (New-CdException -Code 'CD-8001' -Detail "no CloudDrives application in '$source'")
    }
    if ([string]::Equals($source, $target, [StringComparison]::OrdinalIgnoreCase)) {
        throw (New-CdException -Code 'CD-8002' -Detail $target)
    }

    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $staging = "$target.new-$suffix"
    $backup = $null
    try {
        Copy-CdApplicationFiles -SourceRoot $source -Destination $staging
        if (Test-Path -LiteralPath $target) {
            $backup = "$target.old-$suffix"
            Move-CdDirectory -Path $target -Destination $backup
        }
        Move-CdDirectory -Path $staging -Destination $target
    }
    catch {
        # Roll back: the previous version stays in place.
        if ($backup -and -not (Test-Path -LiteralPath $target) -and (Test-Path -LiteralPath $backup)) { Move-CdDirectory -Path $backup -Destination $target }
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        throw (New-CdException -Code 'CD-8003' -Detail $_.Exception.Message -InnerException $_.Exception)
    }
    if ($backup) {
        try { Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction Stop }
        catch { Write-CdLog -Level WARN -Component 'Install' -Message "Old version could not be removed yet: $backup" }
    }

    $shortcuts = @()
    if (-not $NoShortcuts) { $shortcuts = Install-CdShortcuts -AppRoot $target -Desktop:$Desktop }

    # Autostart and Explorer icons must point to the installed copy from now on.
    if ((Get-CdAutostart).Enabled) { [void](Enable-CdAutostart -SrcRoot (Join-Path $target 'src')) }
    foreach ($drive in @((Get-CdSettings).drives)) { Set-CdDriveLabel -Drive $drive -AppRoot $target }

    $version = [string](Get-CdManifestVersion -Path (Join-Path $target 'src\CloudDrives.psd1'))
    Write-CdLog -Component 'Install' -Message "CloudDrives $version installed to $target."
    New-CdResult -Message (Get-CdText 'install.done' $version, $target) -Data ([pscustomobject]@{ InstallDir = $target; Version = $version; Shortcuts = $shortcuts })
}

function Uninstall-CdApplication {
    # Removes CloudDrives from this PC. Cloud data is never touched; local sign-ins only with -RemoveData.
    param([switch]$RemoveData)
    $ctx = Get-CdContext
    try { [void](Invoke-CdDisconnect -Force) } catch { Write-CdLog -Level WARN -Component 'Install' -Message "Disconnect: $($_.Exception.Message)" }
    try { Stop-CdEngine } catch { Write-CdLog -Level WARN -Component 'Install' -Message "Engine stop: $($_.Exception.Message)" }
    [void](Disable-CdAutostart)
    foreach ($drive in @((Get-CdSettings).drives)) { Remove-CdDriveLabel -Drive $drive }
    Remove-CdShortcuts

    if ($RemoveData) {
        foreach ($name in @('config', 'rc')) { Remove-CdSecret -Name $name }
        if (Test-Path -LiteralPath $ctx.Home) { Remove-Item -LiteralPath $ctx.Home -Recurse -Force -ErrorAction SilentlyContinue }
    }

    $installDir = Get-CdInstallDir
    if (Test-Path -LiteralPath $installDir) {
        if (Test-CdInstalled) {
            # The running scripts live in this folder: delete it a few seconds after this process has ended.
            $command = '/d /c ping 127.0.0.1 -n 5 >nul & rmdir /s /q "{0}"' -f $installDir
            [void](Start-CdDetachedProcess -FilePath (Join-Path $env:WINDIR 'System32\cmd.exe') -RawArguments $command -WorkingDirectory $env:TEMP)
        }
        else {
            Remove-Item -LiteralPath $installDir -Recurse -Force
        }
    }
    Write-CdLog -Component 'Install' -Message "CloudDrives uninstalled (data removed: $([bool]$RemoveData))."
    New-CdResult -Message (Get-CdText 'uninstall.done')
}
