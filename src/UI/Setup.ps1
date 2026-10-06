# Questions of the first start: checking rclone and WinFsp (setup), installing CloudDrives into the program folder
# and connecting the drives at every Windows start.

function Start-CdSetupWizard {
    # Installs/verifies rclone and WinFsp and prepares the encrypted configuration. Returns $true when ready.
    Clear-CdScreen
    Write-CdHeader -Subtitle (Get-CdText 'setup.title')
    Write-CdInfo -Text (Get-CdText 'setup.intro')

    Write-CdStep -Text (Get-CdText 'setup.rclone.step')
    $rclone = Find-CdRclone
    if ($rclone) { Write-CdOk -Text (Get-CdText 'setup.rclone.ok' ([string]$rclone.Version)) }
    else {
        Write-CdInfo -Text (Get-CdText 'setup.rclone.installing')
        try {
            $rclone = Install-CdRclone
            Write-CdOk -Text (Get-CdText 'setup.rclone.ok' ([string]$rclone.Version))
        }
        catch {
            Write-CdErrorInfo -Info (Get-CdErrorInfo $_)
            Wait-CdKeyPress
            return $false
        }
    }

    Write-CdStep -Text (Get-CdText 'setup.winfsp.step')
    if (Test-CdWinFsp) { Write-CdOk -Text (Get-CdText 'setup.winfsp.ok' ([string](Get-CdWinFsp).Version)) }
    else {
        Write-CdInfo -Text (Get-CdText 'setup.winfsp.explain')
        if (-not (Read-CdYesNo -Prompt (Get-CdText 'setup.winfsp.confirm') -Default $true)) {
            Write-CdInfo -Text (Get-CdText 'setup.winfsp.declined') -Color Yellow
            Wait-CdKeyPress
            return $false
        }
        Write-CdInfo -Text (Get-CdText 'setup.winfsp.installing')
        try {
            $winfsp = Install-CdWinFsp
            Write-CdOk -Text (Get-CdText 'setup.winfsp.ok' ([string]$winfsp.Version))
        }
        catch {
            Write-CdErrorInfo -Info (Get-CdErrorInfo $_)
            Wait-CdKeyPress
            return $false
        }
    }

    Write-CdStep -Text (Get-CdText 'setup.secure.step')
    try {
        Initialize-CdHome
        Initialize-CdRcloneConfig -RclonePath $rclone.Path -ConfigPassword (Get-CdConfigPassword)
        Write-CdOk -Text (Get-CdText 'setup.secure.ok')
    }
    catch {
        Write-CdErrorInfo -Info (Get-CdErrorInfo $_)
        Wait-CdKeyPress
        return $false
    }
    Write-Host ''
    Write-CdOk -Text (Get-CdText 'setup.done')
    $true
}

function Request-CdAutostart {
    # Asks once whether drives should be connected automatically at Windows sign-in.
    $settings = Get-CdSettings
    if ($settings.autostartAsked -or @($settings.drives).Count -eq 0) { return }
    if ((Get-CdAutostart).Enabled) { return }
    Write-CdStep -Text (Get-CdText 'autostart.question')
    Write-CdInfo -Text (Get-CdText 'autostart.explain') -Color DarkGray
    if (Read-CdYesNo -Prompt (Get-CdText 'autostart.confirm') -Default $true) {
        try { Write-CdResult -Result (Enable-CdAutostart) }
        catch { Write-CdErrorInfo -Info (Get-CdErrorInfo $_) }
        # Reconnecting after standby or a crash and the status symbol belong to "automatically connected".
        try { Write-CdResult -Result (Enable-CdWatchdog) }
        catch { Write-CdErrorInfo -Info (Get-CdErrorInfo $_) }
        try { Write-CdResult -Result (Enable-CdTray) }
        catch { Write-CdErrorInfo -Info (Get-CdErrorInfo $_) }
    }
    else { Write-CdInfo -Text (Get-CdText 'autostart.later') -Color DarkGray }
    $settings.autostartAsked = $true
    Save-CdSettings -Settings $settings
}

function Request-CdInstall {
    # Offers - once, or on demand - to install the running copy into the program folder.
    # Returns $true after a successful installation; the caller then hands over to the installed copy.
    param([switch]$Force)
    $settings = Get-CdSettings
    if ((Test-CdInstalled) -or ($settings.installAsked -and -not $Force)) { return $false }
    Write-CdStep -Text (Get-CdText 'install.question')
    Write-CdInfo -Text (Get-CdText 'install.explain' (Get-CdInstallDir)) -Color DarkGray
    $installed = $false
    if (Read-CdYesNo -Prompt (Get-CdText 'install.confirm') -Default $true) {
        $desktop = Read-CdYesNo -Prompt (Get-CdText 'install.desktop') -Default $true
        try {
            Write-CdResult -Result (Install-CdApplication -Desktop:$desktop)
            Write-CdInfo -Text (Get-CdText 'install.startHint') -Color Green
            $installed = $true
        }
        catch { Write-CdErrorInfo -Info (Get-CdErrorInfo $_) }
    }
    else { Write-CdInfo -Text (Get-CdText 'install.later') -Color DarkGray }
    $settings.installAsked = $true
    Save-CdSettings -Settings $settings
    $installed
}

function Restart-CdFromInstallDir {
    # Opens the installed copy in a new window; the caller ends this one afterwards.
    Write-CdInfo -Text (Get-CdText 'app.restarting') -Color Green
    Wait-CdKeyPress
    try { Start-CdInstalledApplication }
    catch {
        Write-CdErrorInfo -Info (Get-CdErrorInfo $_)
        Wait-CdKeyPress
    }
}
