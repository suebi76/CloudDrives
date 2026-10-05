# Interactive main menu.

function Invoke-CdConnectUi {
    param([string[]]$Selection = @('all'))
    Write-CdStep -Text (Get-CdText 'connect.running')
    $results = @(Invoke-CdConnect -Selection $Selection -AllowInstall -OnResult { param($Result) Write-CdResult -Result $Result } `
            -OnProgress { param([string]$Status) Write-CdProgress -Text $Status })
    Complete-CdProgress
    if ($results.Count -eq 0) { Write-CdInfo -Text (Get-CdText 'status.noDrives') }

    # An expired or revoked sign-in can be renewed right here; afterwards the affected drives are retried.
    $expired = @($results | Where-Object {
            $entry = Get-CdErrorEntry -Code ([string]$_.Code)
            -not $_.Success -and $_.Data -and $_.Data.account -and $entry -and $entry.action -eq 'reconnect-account'
        } | ForEach-Object { [string]$_.Data.account } | Select-Object -Unique)
    foreach ($accountId in $expired) {
        $account = Get-CdAccount -Id $accountId
        if (-not $account) { continue }
        Write-Host ''
        Write-CdInfo -Text (Get-CdText 'relogin.offer' $account.label) -Color Yellow
        if (-not (Read-CdYesNo -Prompt (Get-CdText 'relogin.confirm') -Default $true)) { continue }
        $renewed = @(Start-CdReloginWizard -Account $account -Embedded) | Where-Object { $_ -is [bool] } | Select-Object -Last 1
        if (-not $renewed) { continue }
        $retry = @($results | Where-Object { -not $_.Success -and $_.Data -and $_.Data.account -eq $accountId } | ForEach-Object { [string]$_.Data.id })
        if ($retry.Count -gt 0) {
            [void](Invoke-CdConnect -Selection $retry -OnResult { param($Result) Write-CdResult -Result $Result } -OnProgress { param([string]$Status) Write-CdProgress -Text $Status })
            Complete-CdProgress
        }
    }
    Wait-CdKeyPress
}

function Invoke-CdDisconnectUi {
    Write-CdStep -Text (Get-CdText 'disconnect.running')
    $results = @(Invoke-CdDisconnect -OnResult { param($Result) Write-CdResult -Result $Result } -OnProgress { param([string]$Status) Write-CdProgress -Text $Status })
    Complete-CdProgress
    $blocked = @($results | Where-Object { $_.Code -eq 'CD-4006' })
    foreach ($item in $blocked) {
        $drive = $item.Data.Drive
        Write-CdInfo -Text (Get-CdText 'disconnect.pendingExplain') -Color Yellow
        Write-CdInfo -Text ('[1] ' + (Get-CdText 'disconnect.wait'))
        Write-CdInfo -Text ('[2] ' + (Get-CdText 'disconnect.force'))
        Write-CdInfo -Text ('[0] ' + (Get-CdText 'disconnect.keep'))
        $choice = Read-CdChoice -Prompt (Get-CdText 'ui.choose') -Valid @('1', '2', '0') -Default '1'
        if ($choice -eq '0') { continue }
        if ($choice -eq '1') {
            $mounted = Get-CdMountedDrives
            $fs = [string]$mounted["$($drive.letter):".ToUpperInvariant()].Fs
            Write-CdProgress -Text (Get-CdText 'disconnect.waiting')
            while ((Get-CdPendingUploadCount -Fs $fs) -gt 0) {
                if (Test-CdEscapePressed) { break }
                Start-Sleep -Seconds 2
                Write-CdProgress
            }
        }
        $result = Invoke-CdDisconnect -Selection @($drive.id) -Force:($choice -eq '2') -OnProgress { param([string]$Status) Write-CdProgress -Text $Status }
        foreach ($entry in @($result)) { Write-CdResult -Result $entry }
    }
    Wait-CdKeyPress
}

function Start-CdConsoleMenu {
    Initialize-CdConsole
    Set-CdPasswordPrompt -Prompt { Read-CdSecretText -Prompt (Get-CdText 'security.masterPasswordPrompt') }

    $setup = Get-CdSetupState
    if (-not $setup.Ready) {
        $ready = @(Start-CdSetupWizard) | Where-Object { $_ -is [bool] } | Select-Object -Last 1
        if (-not $ready) { return 2 }
        $setup = Get-CdSetupState
    }
    if (-not (Test-CdInstalled) -and -not (Get-CdSettings).installAsked) {
        # Installation comes first, so that autostart and Explorer icons refer to the installed copy.
        Clear-CdScreen
        Write-CdHeader
        $installed = $false
        try { $installed = [bool](@(Request-CdInstall) | Where-Object { $_ -is [bool] } | Select-Object -Last 1) }
        catch { Write-CdErrorInfo -Info (Get-CdErrorInfo $_) }
        if ($installed) {
            Restart-CdFromInstallDir
            return 0
        }
        Wait-CdKeyPress
    }
    if (-not $setup.HasAccounts) {
        Clear-CdScreen
        Write-CdHeader
        Write-CdInfo -Text (Get-CdText 'menu.welcome')
        if (Read-CdYesNo -Prompt (Get-CdText 'menu.welcomeAddAccount') -Default $true) { Start-CdAddAccountWizard }
    }
    elseif (-not (Get-CdSettings).autostartAsked -and @((Get-CdSettings).drives).Count -gt 0 -and -not (Get-CdAutostart).Enabled) {
        # Setups created before the autostart existed are asked once, too.
        Clear-CdScreen
        Write-CdHeader
        try { Request-CdAutostart }
        catch { Write-CdErrorInfo -Info (Get-CdErrorInfo $_) }
        Wait-CdKeyPress
    }

    try { if (Test-CdInstalled) { Update-CdShortcuts } } catch { Write-CdLog -Level DEBUG -Component 'Menu' -Message "Shortcuts: $($_.Exception.Message)" }
    # Drives renamed in Explorer keep their names in the menu as well.
    try { [void](Sync-CdDriveLabels) } catch { Write-CdLog -Level DEBUG -Component 'Menu' -Message "Explorer names: $($_.Exception.Message)" }
    # The status symbol belongs to CloudDrives (it may have been hidden earlier in this session).
    try { if ((Get-CdTray).Enabled) { [void](Start-CdTrayProcess -SrcRoot (Get-CdPreferredSrcRoot)) } }
    catch { Write-CdLog -Level DEBUG -Component 'Menu' -Message "Tray start: $($_.Exception.Message)" }

    while ($true) {
        Clear-CdScreen
        Write-CdHeader
        $engineText = Get-CdText 'menu.engineStopped'
        try {
            $status = Get-CdStatus
            if ($status.Engine -and $status.Engine.Healthy) { $engineText = Get-CdText 'menu.engineRunning' }
            Write-CdStatusTable -StatusList $status.Drives
        }
        catch { Write-CdErrorInfo -Info (Get-CdErrorInfo $_) }
        Write-CdRule
        Write-CdInfo -Text $engineText -Color DarkGray
        $valid = @('1', '2', '3', '4', '5', '6', '7', '8', '9', '0')
        $update = Get-CdPendingUpdate
        if ($update) {
            $key = 'menu.updateAvailable'
            if ((Get-CdSettings).updates -eq 'automatic') { $key = 'menu.updateWaiting' }
            Write-CdInfo -Text (Get-CdText $key $update) -Color Green
            $valid += 'U'
        }
        Write-Host ''
        $menu = @(
            @('1', 'menu.connectAll', '2', 'menu.disconnectAll'),
            @('3', 'menu.addAccount', '4', 'menu.manageAccounts'),
            @('5', 'menu.manageDrives', '6', 'menu.settings'),
            @('7', 'menu.diagnostics', '8', 'menu.refresh'),
            @('9', 'menu.about', '0', 'menu.exit')
        )
        foreach ($row in $menu) {
            $left = ('[{0}] {1}' -f $row[0], (Get-CdText $row[1])).PadRight(28)
            Write-CdInfo -Text ($left + ('[{0}] {1}' -f $row[2], (Get-CdText $row[3]))) -Color White
        }
        $choice = Read-CdChoice -Prompt (Get-CdText 'ui.choose') -Valid $valid
        try {
            switch ($choice) {
                'U' {
                    if (@(Start-CdUpdateUi -Confirmed) | Where-Object { $_ -is [bool] } | Select-Object -Last 1) {
                        Restart-CdFromInstallDir
                        return 0
                    }
                }
                '1' { Invoke-CdConnectUi }
                '2' { Invoke-CdDisconnectUi }
                '3' { Start-CdAddAccountWizard }
                '4' { Start-CdManageAccountsMenu }
                '5' { Start-CdManageDrivesMenu }
                '6' { if ((Start-CdSettingsMenu) -eq 'exit') { return 0 } }
                '7' { Start-CdDoctorUi }
                '8' { $script:CdQuotaCache = @{} }
                '9' {
                    Clear-CdScreen
                    Show-CdAbout
                    Wait-CdKeyPress
                }
                '0' { return 0 }
            }
        }
        catch {
            Write-CdErrorInfo -Info (Get-CdErrorInfo $_)
            Write-CdLog -Level ERROR -Component 'Menu' -Message $_.Exception.Message -Data @{ at = $_.ScriptStackTrace }
            Wait-CdKeyPress
        }
    }
}
