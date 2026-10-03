# Guided assistants: first-time setup, adding and removing accounts.

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

function Start-CdAddAccountWizard {
    Clear-CdScreen
    Write-CdHeader -Subtitle (Get-CdText 'wizard.add.title')

    Write-CdStep -Text (Get-CdText 'wizard.add.providerQuestion')
    Write-CdInfo -Text ('[1] ' + (Get-CdText 'wizard.add.provider.onedrive'))
    Write-CdInfo -Text ('[2] ' + (Get-CdText 'wizard.add.provider.googlePersonal'))
    Write-CdInfo -Text ('[3] ' + (Get-CdText 'wizard.add.provider.googleWorkspace'))
    Write-CdInfo -Text ('[0] ' + (Get-CdText 'ui.cancel'))
    $choice = Read-CdChoice -Prompt (Get-CdText 'ui.choose') -Valid @('1', '2', '3', '0')
    switch ($choice) {
        '1' { $provider = 'onedrive'; $kind = 'personal'; $defaultLabel = Get-CdText 'wizard.add.defaultLabel.onedrive' }
        '2' { $provider = 'drive'; $kind = 'personal'; $defaultLabel = Get-CdText 'wizard.add.defaultLabel.googlePersonal' }
        '3' { $provider = 'drive'; $kind = 'workspace'; $defaultLabel = Get-CdText 'wizard.add.defaultLabel.googleWorkspace' }
        default { return }
    }
    $definition = Get-CdProvider -Id $provider

    $label = Read-CdText -Prompt (Get-CdText 'wizard.add.labelPrompt') -Default $defaultLabel
    if ([string]::IsNullOrWhiteSpace($label)) { $label = $defaultLabel }

    $clientId = $null
    $clientSecret = $null
    if ($provider -eq 'drive') {
        # rclone's shared Google client ID is being retired during 2026, so an own client ID is the default.
        Write-CdStep -Text (Get-CdText 'wizard.add.clientQuestion')
        Write-CdInfo -Text (Get-CdText 'wizard.add.client.explain') -Color DarkGray
        Write-CdInfo -Text ('[1] ' + (Get-CdText 'wizard.add.client.own'))
        Write-CdInfo -Text ('[2] ' + (Get-CdText 'wizard.add.client.default'))
        Write-CdInfo -Text ('[0] ' + (Get-CdText 'ui.cancel'))
        $clientChoice = Read-CdChoice -Prompt (Get-CdText 'ui.choose') -Valid @('1', '2', '0') -Default '1'
        if ($clientChoice -eq '0') { return }
        if ($clientChoice -eq '1') {
            # 1) reuse the client of another Google account, 2) take the downloaded client file, 3) ask.
            try {
                [void](Start-CdEngine)
                foreach ($known in @(Get-CdOwnGoogleClients)) {
                    if ($clientId) { break }
                    Write-CdInfo -Text (Get-CdText 'wizard.add.client.reuseFound' $known.AccountLabel, $known.ClientId)
                    if (Read-CdYesNo -Prompt (Get-CdText 'wizard.add.client.reuse') -Default $true) { $clientId = $known.ClientId; $clientSecret = $known.ClientSecret }
                }
            }
            catch { Write-CdLog -Level WARN -Component 'Wizard' -Message "Existing clients unavailable: $($_.Exception.Message)" }
            $clientFile = $null
            if (-not $clientId) {
                $clientFile = Find-CdGoogleClientFile
                if ($clientFile) {
                    Write-CdInfo -Text (Get-CdText 'wizard.add.client.fileFound' (Split-Path -Leaf $clientFile.Path), $clientFile.ClientId)
                    if (Read-CdYesNo -Prompt (Get-CdText 'wizard.add.client.fileUse') -Default $true) { $clientId = $clientFile.ClientId; $clientSecret = $clientFile.ClientSecret }
                    else { $clientFile = $null }
                }
            }
            if (-not $clientId) {
                Write-CdInfo -Text (Get-CdText 'wizard.add.client.ownHint' (Join-Path (Get-CdContext).AppRoot 'docs\GOOGLE-OAUTH.md')) -Color DarkGray
                if ($kind -eq 'workspace') { Write-CdInfo -Text (Get-CdText 'wizard.add.client.workspaceHint') -Color DarkGray }
            }
            while (-not $clientId) {
                $answer = Read-CdText -Prompt (Get-CdText 'wizard.add.client.idPrompt')
                if (-not $answer) { return }
                if (Test-CdGoogleClientId -ClientId $answer) { $clientId = $answer.Trim() }
                else { Write-CdInfo -Text (Get-CdText 'wizard.add.client.idInvalid') -Color Yellow }
            }
            while (-not $clientSecret) { $clientSecret = Read-CdSecretText -Prompt (Get-CdText 'wizard.add.client.secretPrompt') }
        }
        else {
            Write-CdInfo -Text (Get-CdText 'wizard.add.client.sharedWarning') -Color Yellow
        }
    }

    Write-CdStep -Text (Get-CdText 'wizard.add.loginStep' (Get-CdText $definition.NameKey))
    Write-CdInfo -Text (Get-CdText 'wizard.add.loginExplain')
    if ($kind -eq 'workspace') { Write-CdInfo -Text (Get-CdText 'wizard.add.workspaceHint') -Color DarkGray }
    $onAuthUrl = {
        param([string]$Url)
        Write-CdInfo -Text (Get-CdText 'wizard.add.browserOpening')
        Write-CdInfo -Text ('  ' + $Url) -Color Cyan
        try { Start-Process -FilePath $Url } catch { Write-CdInfo -Text (Get-CdText 'wizard.add.browserFailed') -Color Yellow }
        Write-CdInfo -Text (Get-CdText 'wizard.add.waiting') -Color DarkGray
    }
    try {
        $result = Add-CdAccount -Provider $provider -Label $label -Kind $kind -ClientId $clientId -ClientSecret $clientSecret -OnAuthUrl $onAuthUrl -ShouldCancel { Test-CdEscapePressed }
    }
    catch {
        Write-CdErrorInfo -Info (Get-CdErrorInfo $_)
        Wait-CdKeyPress
        return
    }
    $account = $result.Data.Account
    $about = $result.Data.About
    Write-Host ''
    Write-CdOk -Text $result.Message
    if ($clientFile -and (Test-Path -LiteralPath $clientFile.Path)) {
        # The downloaded file holds the client secret in plain text; CloudDrives keeps it encrypted now.
        Write-CdInfo -Text (Get-CdText 'wizard.add.client.fileDeleteHint' (Split-Path -Leaf $clientFile.Path)) -Color DarkGray
        if (Read-CdYesNo -Prompt (Get-CdText 'wizard.add.client.fileDelete') -Default $true) {
            Remove-Item -LiteralPath $clientFile.Path -Force
            Write-CdOk -Text (Get-CdText 'wizard.add.client.fileDeleted')
        }
    }
    if ($about -and $null -ne $about.used) {
        if ($about.total) { Write-CdInfo -Text (Get-CdText 'wizard.add.quota' (Format-CdSize $about.used), (Format-CdSize $about.total)) }
        else { Write-CdInfo -Text (Get-CdText 'wizard.add.quotaUsed' (Format-CdSize $about.used)) }
    }

    # The user decides per account: plain drive, plain drive plus encrypted vault, or vault only.
    Write-CdStep -Text (Get-CdText 'wizard.add.modeQuestion')
    Write-CdInfo -Text ('[1] ' + (Get-CdText 'wizard.add.mode.plain'))
    Write-CdInfo -Text ('[2] ' + (Get-CdText 'wizard.add.mode.both'))
    Write-CdInfo -Text ('[3] ' + (Get-CdText 'wizard.add.mode.vaultOnly'))
    $mode = Read-CdChoice -Prompt (Get-CdText 'ui.choose') -Valid @('1', '2', '3') -Default '1'

    $created = New-Object System.Collections.Generic.List[object]
    if ($mode -ne '3') {
        Write-CdStep -Text (Get-CdText 'wizard.add.letterStep')
        try {
            $letter = Read-CdDriveLetter -Preferred $definition.PreferredLetters
            $created.Add((New-CdDrive -AccountId $account.id -Letter $letter -Label $label))
        }
        catch { Write-CdErrorInfo -Info (Get-CdErrorInfo $_) }
    }
    if ($mode -ne '1') {
        $vaultDrive = Start-CdVaultWizard -Account $account
        if ($vaultDrive) { $created.Add($vaultDrive) }
    }
    Complete-CdNewDrives -Drives $created.ToArray()
}

function Complete-CdNewDrives {
    # Offers to connect freshly created drives right away.
    param([object[]]$Drives)
    if (@($Drives).Count -gt 0) {
        $letters = (@($Drives) | ForEach-Object { "$($_.letter):" }) -join ', '
        if (Read-CdYesNo -Prompt (Get-CdText 'wizard.add.connectNow' $letters) -Default $true) {
            Write-Host ''
            $results = Invoke-CdConnect -Selection @(@($Drives) | ForEach-Object { $_.id })
            foreach ($item in $results) { Write-CdResult -Result $item }
        }
    }
    Wait-CdKeyPress
}

function Read-CdDriveLetter {
    # Lets the user pick a free drive letter; the first free preferred letter is suggested.
    param([string[]]$Preferred = @())
    $free = @(Get-CdFreeDriveLetters)
    if ($free.Count -eq 0) { throw (New-CdException -Code 'CD-4005') }
    $suggested = $Preferred | Where-Object { $free -contains $_ } | Select-Object -First 1
    if (-not $suggested) { $suggested = $free[0] }
    Write-CdInfo -Text (Get-CdText 'wizard.add.freeLetters' (($free | ForEach-Object { "${_}:" }) -join ' ')) -Color DarkGray
    while ($true) {
        $answer = Read-CdText -Prompt (Get-CdText 'wizard.add.letterPrompt') -Default $suggested
        if ($answer) {
            $candidate = $answer.Trim().TrimEnd(':').ToUpperInvariant()
            if ($free -contains $candidate) { return $candidate }
            Write-CdInfo -Text (Get-CdText 'wizard.add.letterInvalid' $candidate) -Color Yellow
        }
    }
}

function Read-CdNewVaultPassword {
    # Asks twice for a self-chosen vault password; an empty input cancels.
    while ($true) {
        $first = Read-CdSecretText -Prompt (Get-CdText 'vault.passwordNew')
        if ([string]::IsNullOrEmpty($first)) { return $null }
        if ($first.Length -lt 12) {
            Write-CdInfo -Text (Get-CdText 'vault.passwordTooShort') -Color Yellow
            continue
        }
        $second = Read-CdSecretText -Prompt (Get-CdText 'vault.passwordRepeat')
        if ($first -ceq $second) { return $first }
        Write-CdInfo -Text (Get-CdText 'vault.passwordMismatch') -Color Yellow
    }
}

function Start-CdVaultWizard {
    # Creates a new vault or connects an existing one for an account. Returns the new drive or $null.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Account)
    Write-CdStep -Text (Get-CdText 'vault.title' $Account.label)
    Write-CdInfo -Text (Get-CdText 'vault.explain')

    $folder = $null
    while (-not $folder) {
        $answer = Read-CdText -Prompt (Get-CdText 'vault.folderPrompt') -Default (Get-CdText 'vault.defaultFolder')
        try { $folder = ConvertTo-CdVaultFolder -Folder $answer }
        catch { Write-CdInfo -Text (Get-CdText 'vault.folderInvalid') -Color Yellow }
    }
    try {
        [void](Start-CdEngine)
        $state = Get-CdVaultFolderState -AccountId $Account.id -Folder $folder
    }
    catch {
        Write-CdErrorInfo -Info (Get-CdErrorInfo $_)
        return $null
    }

    if ($state -eq 'existing') {
        Write-CdInfo -Text (Get-CdText 'vault.existingFound' $folder) -Color Yellow
        $password = Read-CdSecretText -Prompt (Get-CdText 'vault.passwordPrompt')
        $salt = Read-CdSecretText -Prompt (Get-CdText 'vault.saltPrompt')
    }
    else {
        Write-CdInfo -Text ('[1] ' + (Get-CdText 'vault.password.generate'))
        Write-CdInfo -Text ('[2] ' + (Get-CdText 'vault.password.own'))
        Write-CdInfo -Text ('[0] ' + (Get-CdText 'ui.cancel'))
        $choice = Read-CdChoice -Prompt (Get-CdText 'ui.choose') -Valid @('1', '2', '0') -Default '1'
        if ($choice -eq '0') { return $null }
        if ($choice -eq '1') { $password = New-CdVaultPassword }
        else { $password = Read-CdNewVaultPassword }
        $salt = New-CdVaultPassword
    }
    if ([string]::IsNullOrEmpty($password) -or [string]::IsNullOrEmpty($salt)) { return $null }

    $label = Read-CdText -Prompt (Get-CdText 'vault.labelPrompt') -Default (Get-CdText 'vault.defaultLabel' $Account.label)
    Write-CdStep -Text (Get-CdText 'vault.letterStep')
    try {
        $letter = Read-CdDriveLetter -Preferred $script:CdVaultPreferredLetters
        Write-CdInfo -Text (Get-CdText 'vault.creating') -Color DarkGray
        $result = Add-CdVaultDrive -AccountId $Account.id -Folder $folder -Letter $letter -Label $label -Password $password -Salt $salt
    }
    catch {
        Write-CdErrorInfo -Info (Get-CdErrorInfo $_)
        return $null
    }
    Write-CdOk -Text $result.Message
    if ($result.Data.State -eq 'new') { Show-CdRecoveryKit -Drive $result.Data.Drive -Account $Account -Password $password -Salt $salt }
    else { Write-CdInfo -Text (Get-CdText 'vault.existingConnected') }
    $result.Data.Drive
}

function Show-CdRecoveryKit {
    # Shows password and salt of a new vault until the user confirms they are stored safely.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password', Justification = 'The recovery kit is shown to the user on purpose.')]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Drive,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Account,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][string]$Salt
    )
    $text = Get-CdRecoveryKitText -Drive $Drive -Account $Account -Password $Password -Salt $Salt
    while ($true) {
        Write-Host ''
        Write-CdRule
        Write-CdInfo -Text $text -Color Yellow
        Write-CdRule
        Write-CdInfo -Text ('[1] ' + (Get-CdText 'vault.kit.noted'))
        Write-CdInfo -Text ('[2] ' + (Get-CdText 'vault.kit.saveFile'))
        $choice = Read-CdChoice -Prompt (Get-CdText 'ui.choose') -Valid @('1', '2')
        if ($choice -eq '2') {
            $path = Read-CdText -Prompt (Get-CdText 'vault.kit.pathPrompt') -Default (Get-CdRecoveryKitDefaultPath -Drive $Drive)
            if (-not $path) { continue }
            if ((Test-CdPathInCloudFolder -Path $path) -and -not (Read-CdYesNo -Prompt (Get-CdText 'vault.kit.cloudWarning') -Default $false)) { continue }
            try { Write-CdOk -Text (Get-CdText 'vault.kit.saved' (Save-CdRecoveryKit -Path $path -Text $text)) }
            catch {
                Write-CdErrorInfo -Info (Get-CdErrorInfo $_)
                continue
            }
        }
        if (Read-CdYesNo -Prompt (Get-CdText 'vault.kit.confirm') -Default $false) { return }
    }
}

function Select-CdAccountUi {
    # Lets the user pick one of the configured accounts; returns it or $null.
    $accounts = @((Get-CdSettings).accounts)
    if ($accounts.Count -eq 0) {
        Write-CdInfo -Text (Get-CdText 'manage.noAccounts') -Color Yellow
        return $null
    }
    $valid = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $accounts.Count; $i++) {
        $provider = Get-CdProvider -Id $accounts[$i].provider
        Write-CdInfo -Text ('[{0}] {1}  ({2})' -f ($i + 1), $accounts[$i].label, (Get-CdText $provider.NameKey))
        $valid.Add([string]($i + 1))
    }
    Write-CdInfo -Text ('[0] ' + (Get-CdText 'ui.cancel'))
    $valid.Add('0')
    $choice = Read-CdChoice -Prompt (Get-CdText 'ui.choose') -Valid $valid.ToArray()
    if ($choice -eq '0') { return $null }
    $accounts[[int]$choice - 1]
}

function Start-CdAddDriveWizard {
    Clear-CdScreen
    Write-CdHeader -Subtitle (Get-CdText 'manage.addTitle')
    Write-CdStep -Text (Get-CdText 'manage.chooseAccount')
    $account = Select-CdAccountUi
    if (-not $account) {
        Wait-CdKeyPress
        return
    }

    Write-CdStep -Text (Get-CdText 'manage.typeQuestion')
    Write-CdInfo -Text ('[1] ' + (Get-CdText 'manage.type.plain'))
    Write-CdInfo -Text ('[2] ' + (Get-CdText 'manage.type.vault'))
    Write-CdInfo -Text ('[0] ' + (Get-CdText 'ui.cancel'))
    $type = Read-CdChoice -Prompt (Get-CdText 'ui.choose') -Valid @('1', '2', '0')
    $drive = $null
    switch ($type) {
        '1' {
            $folder = Read-CdText -Prompt (Get-CdText 'manage.folderPrompt')
            $folder = ([string]$folder).Trim().Replace('\', '/').Trim('/')
            $defaultLabel = $account.label
            if ($folder) { $defaultLabel = '{0} - {1}' -f $account.label, ($folder -split '/')[-1] }
            $label = Read-CdText -Prompt (Get-CdText 'manage.labelPrompt') -Default $defaultLabel
            Write-CdStep -Text (Get-CdText 'wizard.add.letterStep')
            try {
                $provider = Get-CdProvider -Id $account.provider
                $letter = Read-CdDriveLetter -Preferred $provider.PreferredLetters
                $drive = New-CdDrive -AccountId $account.id -Letter $letter -Label $label -Path $folder
            }
            catch { Write-CdErrorInfo -Info (Get-CdErrorInfo $_) }
        }
        '2' { $drive = Start-CdVaultWizard -Account $account }
        default { return }
    }
    if ($drive) { Complete-CdNewDrives -Drives @($drive) }
    else { Wait-CdKeyPress }
}

function Start-CdRemoveDriveWizard {
    Clear-CdScreen
    Write-CdHeader -Subtitle (Get-CdText 'manage.remove')
    $drives = @((Get-CdSettings).drives)
    if ($drives.Count -eq 0) {
        Write-CdInfo -Text (Get-CdText 'status.noDrives')
        Wait-CdKeyPress
        return
    }
    Write-CdStep -Text (Get-CdText 'manage.chooseDrive')
    $valid = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $drives.Count; $i++) {
        $tag = ''
        if ($drives[$i].encrypted) { $tag = ' ' + (Get-CdText 'status.encryptedTag') }
        Write-CdInfo -Text ('[{0}] {1}:  {2}{3}' -f ($i + 1), $drives[$i].letter, $drives[$i].label, $tag)
        $valid.Add([string]($i + 1))
    }
    Write-CdInfo -Text ('[0] ' + (Get-CdText 'ui.cancel'))
    $valid.Add('0')
    $choice = Read-CdChoice -Prompt (Get-CdText 'ui.choose') -Valid $valid.ToArray()
    if ($choice -eq '0') { return }
    $drive = $drives[[int]$choice - 1]

    Write-CdInfo -Text (Get-CdText 'manage.removeExplain') -Color Yellow
    if ($drive.encrypted) { Write-CdInfo -Text (Get-CdText 'manage.removeExplainVault') -Color Yellow }
    if (-not (Read-CdYesNo -Prompt (Get-CdText 'manage.removeConfirm' "$($drive.letter):", $drive.label) -Default $false)) { return }
    try { Write-CdOk -Text (Remove-CdDrive -Id $drive.id).Message }
    catch { Write-CdErrorInfo -Info (Get-CdErrorInfo $_) }
    Wait-CdKeyPress
}

function Start-CdManageDrivesMenu {
    while ($true) {
        Clear-CdScreen
        Write-CdHeader -Subtitle (Get-CdText 'manage.title')
        $drives = @((Get-CdSettings).drives)
        if ($drives.Count -eq 0) { Write-CdInfo -Text (Get-CdText 'status.noDrives') }
        foreach ($drive in $drives) {
            $account = Get-CdAccount -Id $drive.account
            $tag = ''
            if ($drive.encrypted) { $tag = ' ' + (Get-CdText 'status.encryptedTag') }
            $where = [string]$account.label
            if ($drive.path) { $where = '{0} / {1}' -f $where, $drive.path }
            Write-CdInfo -Text ('{0}:  {1}{2}   ({3})' -f $drive.letter, $drive.label, $tag, $where)
        }
        Write-Host ''
        Write-CdInfo -Text ('[1] ' + (Get-CdText 'manage.add')) -Color White
        Write-CdInfo -Text ('[2] ' + (Get-CdText 'manage.remove')) -Color White
        Write-CdInfo -Text ('[0] ' + (Get-CdText 'manage.back')) -Color White
        switch (Read-CdChoice -Prompt (Get-CdText 'ui.choose') -Valid @('1', '2', '0')) {
            '1' { Start-CdAddDriveWizard }
            '2' { Start-CdRemoveDriveWizard }
            '0' { return }
        }
    }
}

function Start-CdRemoveAccountWizard {
    Clear-CdScreen
    Write-CdHeader -Subtitle (Get-CdText 'wizard.remove.title')
    $accounts = @((Get-CdSettings).accounts)
    if ($accounts.Count -eq 0) {
        Write-CdInfo -Text (Get-CdText 'wizard.remove.none')
        Wait-CdKeyPress
        return
    }
    $valid = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $accounts.Count; $i++) {
        $provider = Get-CdProvider -Id $accounts[$i].provider
        $letters = @((Get-CdSettings).drives | Where-Object { $_.account -eq $accounts[$i].id } | ForEach-Object { "$($_.letter):" }) -join ' '
        Write-CdInfo -Text ('[{0}] {1}  ({2}) {3}' -f ($i + 1), $accounts[$i].label, (Get-CdText $provider.NameKey), $letters)
        $valid.Add([string]($i + 1))
    }
    Write-CdInfo -Text ('[0] ' + (Get-CdText 'ui.cancel'))
    $valid.Add('0')
    $choice = Read-CdChoice -Prompt (Get-CdText 'ui.choose') -Valid $valid.ToArray()
    if ($choice -eq '0') { return }
    $account = $accounts[[int]$choice - 1]

    Write-CdInfo -Text (Get-CdText 'wizard.remove.explain') -Color Yellow
    if (-not (Read-CdYesNo -Prompt (Get-CdText 'wizard.remove.confirm' $account.label) -Default $false)) { return }
    try {
        $result = Remove-CdAccount -Id $account.id
        Write-CdOk -Text $result.Message
        Write-CdInfo -Text (Get-CdText 'wizard.remove.revokeHint' $result.Data.RevokeUrl) -Color DarkGray
    }
    catch { Write-CdErrorInfo -Info (Get-CdErrorInfo $_) }
    Wait-CdKeyPress
}
