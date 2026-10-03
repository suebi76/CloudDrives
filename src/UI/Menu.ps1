# Interactive main menu.

function Invoke-CdConnectUi {
    param([string[]]$Selection = @('all'))
    Write-CdStep -Text (Get-CdText 'connect.running')
    $results = Invoke-CdConnect -Selection $Selection -AllowInstall -OnResult { param($Result) Write-CdResult -Result $Result }
    if (@($results).Count -eq 0) { Write-CdInfo -Text (Get-CdText 'status.noDrives') }
    Wait-CdKeyPress
}

function Invoke-CdDisconnectUi {
    Write-CdStep -Text (Get-CdText 'disconnect.running')
    $results = @(Invoke-CdDisconnect -OnResult { param($Result) Write-CdResult -Result $Result })
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
            Write-CdInfo -Text (Get-CdText 'disconnect.waiting') -Color DarkGray
            while ((Get-CdPendingUploadCount -Fs $fs) -gt 0) {
                if (Test-CdEscapePressed) { break }
                Start-Sleep -Seconds 2
            }
        }
        $result = Invoke-CdDisconnect -Selection @($drive.id) -Force:($choice -eq '2')
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
    if (-not $setup.HasAccounts) {
        Clear-CdScreen
        Write-CdHeader
        Write-CdInfo -Text (Get-CdText 'menu.welcome')
        if (Read-CdYesNo -Prompt (Get-CdText 'menu.welcomeAddAccount') -Default $true) { Start-CdAddAccountWizard }
    }

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
        Write-Host ''
        $menu = @(
            @('1', 'menu.connectAll', '2', 'menu.disconnectAll'),
            @('3', 'menu.addAccount', '4', 'menu.removeAccount'),
            @('5', 'menu.manageDrives', '6', 'menu.openLogs'),
            @('7', 'menu.refresh', '0', 'menu.exit')
        )
        foreach ($row in $menu) {
            $left = ('[{0}] {1}' -f $row[0], (Get-CdText $row[1])).PadRight(28)
            Write-CdInfo -Text ($left + ('[{0}] {1}' -f $row[2], (Get-CdText $row[3]))) -Color White
        }
        $choice = Read-CdChoice -Prompt (Get-CdText 'ui.choose') -Valid @('1', '2', '3', '4', '5', '6', '7', '0')
        try {
            switch ($choice) {
                '1' { Invoke-CdConnectUi }
                '2' { Invoke-CdDisconnectUi }
                '3' { Start-CdAddAccountWizard }
                '4' { Start-CdRemoveAccountWizard }
                '5' { Start-CdManageDrivesMenu }
                '6' { Start-Process -FilePath 'explorer.exe' -ArgumentList @((Get-CdContext).LogDir) }
                '7' { $script:CdQuotaCache = @{} }
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
