# The settings menu: autostart, watchdog, symbol in the notification area, notifications, how new versions arrive,
# test versions, looking for updates, installing and uninstalling.

function Start-CdSettingsMenu {
    # Returns 'exit' when CloudDrives must end (after uninstalling, or because the installed copy took over).
    while ($true) {
        Clear-CdScreen
        Write-CdHeader -Subtitle (Get-CdText 'settings.title')
        $settings = Get-CdSettings
        $autostart = Get-CdAutostart
        $autostartText = Get-CdText 'settings.off'
        if ($autostart.Enabled) { $autostartText = Get-CdText 'settings.on' }
        $watchdog = Get-CdWatchdog
        $watchdogText = Get-CdText 'settings.off'
        if ($watchdog.Enabled) { $watchdogText = Get-CdText 'settings.on' }
        $tray = Get-CdTray
        $trayText = Get-CdText 'settings.off'
        if ($tray.Enabled) { $trayText = Get-CdText 'settings.on' }
        $ctx = Get-CdContext
        if (Test-CdInstalled) { Write-CdInfo -Text (Get-CdText 'settings.version' $ctx.Version, $ctx.AppRoot) -Color DarkGray }
        else { Write-CdInfo -Text (Get-CdText 'settings.versionNotInstalled' $ctx.Version, $ctx.AppRoot) -Color DarkGray }
        Write-Host ''
        Write-CdInfo -Text ('[1] ' + (Get-CdText 'settings.autostart' $autostartText)) -Color White
        Write-CdInfo -Text ('[2] ' + (Get-CdText 'settings.watchdog' $watchdogText)) -Color White
        Write-CdInfo -Text ('[3] ' + (Get-CdText 'settings.tray' $trayText)) -Color White
        Write-CdInfo -Text ('[4] ' + (Get-CdText 'settings.notifications' (Get-CdText "settings.notifications.$($settings.notifications)"))) -Color White
        Write-CdInfo -Text ('[5] ' + (Get-CdText 'settings.updates' (Get-CdText "settings.updates.$($settings.updates)"))) -Color White
        Write-CdHint -Text (Get-CdText "settings.updatesHint.$($settings.updates)")
        $testText = Get-CdText 'settings.off'
        if ($settings.testVersions) { $testText = Get-CdText 'settings.on' }
        Write-CdInfo -Text ('[6] ' + (Get-CdText 'settings.testVersions' $testText)) -Color White
        Write-CdHint -Text (Get-CdText 'settings.testVersionsHint')
        Write-CdInfo -Text ('[7] ' + (Get-CdText 'settings.checkUpdates')) -Color White
        $valid = @('1', '2', '3', '4', '5', '6', '7', '8', '0')
        if (Test-CdInstalled) { Write-CdInfo -Text ('[8] ' + (Get-CdText 'settings.uninstall')) -Color White }
        else { Write-CdInfo -Text ('[8] ' + (Get-CdText 'settings.install')) -Color White }
        Write-CdInfo -Text ('[0] ' + (Get-CdText 'manage.back')) -Color White
        switch (Read-CdChoice -Prompt (Get-CdText 'ui.choose') -Valid $valid) {
            '2' {
                Write-CdInfo -Text (Get-CdText 'settings.watchdogExplain') -Color DarkGray
                try {
                    if ($watchdog.Enabled) { Write-CdResult -Result (Disable-CdWatchdog) }
                    else { Write-CdResult -Result (Enable-CdWatchdog) }
                }
                catch { Write-CdErrorInfo -Info (Get-CdErrorInfo $_) }
                Wait-CdKeyPress
            }
            '3' {
                try {
                    if ($tray.Enabled) { Write-CdResult -Result (Disable-CdTray) }
                    else { Write-CdResult -Result (Enable-CdTray) }
                }
                catch { Write-CdErrorInfo -Info (Get-CdErrorInfo $_) }
                Wait-CdKeyPress
            }
            '5' {
                $order = @('notify', 'automatic', 'manual')
                $settings.updates = $order[([array]::IndexOf($order, [string]$settings.updates) + 1) % $order.Count]
                Save-CdSettings -Settings $settings
                Reset-CdUpdateCheck
            }
            '6' {
                $settings.testVersions = -not $settings.testVersions
                Save-CdSettings -Settings $settings
                Reset-CdUpdateCheck
            }
            '7' {
                if (@(Start-CdUpdateUi) | Where-Object { $_ -is [bool] } | Select-Object -Last 1) {
                    Restart-CdFromInstallDir
                    return 'exit'
                }
            }
            '8' {
                if (Test-CdInstalled) {
                    if (Start-CdUninstallUi) { return 'exit' }
                }
                elseif (@(Request-CdInstall -Force) | Where-Object { $_ -is [bool] } | Select-Object -Last 1) {
                    Restart-CdFromInstallDir
                    return 'exit'
                }
                else { Wait-CdKeyPress }
            }
            '1' {
                try {
                    if ($autostart.Enabled) { Write-CdResult -Result (Disable-CdAutostart) }
                    else { Write-CdResult -Result (Enable-CdAutostart) }
                    $settings.autostartAsked = $true
                    Save-CdSettings -Settings $settings
                }
                catch { Write-CdErrorInfo -Info (Get-CdErrorInfo $_) }
                Wait-CdKeyPress
            }
            '4' {
                $order = @('errors', 'all', 'off')
                $next = $order[([array]::IndexOf($order, [string]$settings.notifications) + 1) % $order.Count]
                $settings.notifications = $next
                Save-CdSettings -Settings $settings
                if ($next -ne 'off') { [void](Show-CdNotification -Title 'CloudDrives' -Message (Get-CdText 'settings.notificationTest')) }
            }
            '0' { return }
        }
    }
}

function Start-CdUpdateUi {
    # Returns $true after an update was installed; the caller then restarts CloudDrives.
    # -Confirmed: the user chose to install already ([U] in the main menu), so it does not ask again.
    param([switch]$Confirmed)
    Write-Host ''
    Write-CdProgress -Text (Get-CdText 'update.checking')
    $updated = $false
    try {
        $state = Get-CdUpdateState
        if (-not $state.Latest) { Write-CdInfo -Text (Get-CdText 'error.CD-8004.title') }
        elseif (-not $state.Available) { Write-CdOk -Text (Get-CdText 'update.upToDate' ([string]$state.Current)) }
        elseif (-not (Test-CdInstalled)) { Write-CdInfo -Text (Get-CdText 'update.notInstalled' ([string]$state.Latest)) -Color Yellow }
        else {
            Write-CdInfo -Text (Get-CdText 'update.available' ([string]$state.Latest), ([string]$state.Current))
            if ($Confirmed -or (Read-CdYesNo -Prompt (Get-CdText 'update.confirm') -Default $true)) {
                $result = Install-CdUpdate -OnProgress { param([string]$Status) Write-CdProgress -Text $Status }
                Write-CdResult -Result $result
                $updated = [bool]($result.Success -and $result.Data)
            }
        }
    }
    catch { Write-CdErrorInfo -Info (Get-CdErrorInfo $_) }
    if (-not $updated) { Wait-CdKeyPress }
    $updated
}

function Start-CdUninstallUi {
    Write-CdInfo -Text (Get-CdText 'uninstall.explain') -Color Yellow
    if (-not (Read-CdYesNo -Prompt (Get-CdText 'uninstall.confirm') -Default $false)) { return $false }
    $removeData = Read-CdYesNo -Prompt (Get-CdText 'uninstall.removeData') -Default $false
    try {
        Write-CdResult -Result (Uninstall-CdApplication -RemoveData:$removeData)
        Write-CdInfo -Text (Get-CdText 'uninstall.winfspNote') -Color DarkGray
        Wait-CdKeyPress
        return $true
    }
    catch {
        Write-CdErrorInfo -Info (Get-CdErrorInfo $_)
        Wait-CdKeyPress
        return $false
    }
}
