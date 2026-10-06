# Managing drives: adding one (also as an encrypted vault, with its recovery kit), renaming and removing.

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

function Read-CdDriveName {
    # Name shown in Explorer. A single letter is almost always a mistyped drive letter, so it is rejected.
    param([Parameter(Mandatory)][string]$Default)
    while ($true) {
        $answer = Read-CdText -Prompt (Get-CdText 'manage.labelPrompt') -Default $Default
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        if ($answer.Trim().TrimEnd(':').Length -gt 1) { return $answer.Trim() }
        Write-CdInfo -Text (Get-CdText 'manage.labelTooShort') -Color Yellow
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

    Write-CdStep -Text (Get-CdText 'vault.letterStep')
    try {
        $letter = Read-CdDriveLetter -Preferred $script:CdVaultPreferredLetters
        $label = Read-CdDriveName -Default (Get-CdText 'vault.defaultLabel' $Account.label)
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
            $default = Get-CdRecoveryKitDefaultPath -Drive $Drive
            $path = Read-CdText -Prompt (Get-CdText 'vault.kit.pathPrompt') -Default $default
            if (-not $path) { continue }
            # A bare file name would otherwise land in the program folder.
            if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path (Split-Path -Parent $default) $path }
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

function Select-CdDriveUi {
    # Lets the user pick one of the configured drives; returns it or $null.
    param([Parameter(Mandatory)][string]$PromptKey)
    $drives = @((Get-CdSettings).drives)
    if ($drives.Count -eq 0) {
        Write-CdInfo -Text (Get-CdText 'status.noDrives')
        return $null
    }
    Write-CdStep -Text (Get-CdText $PromptKey)
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
    if ($choice -eq '0') { return $null }
    $drives[[int]$choice - 1]
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
            Write-CdStep -Text (Get-CdText 'wizard.add.letterStep')
            try {
                $provider = Get-CdProvider -Id $account.provider
                $letter = Read-CdDriveLetter -Preferred $provider.PreferredLetters
                $label = Read-CdDriveName -Default $defaultLabel
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

function Start-CdRenameDriveWizard {
    Clear-CdScreen
    Write-CdHeader -Subtitle (Get-CdText 'manage.rename')
    $drive = Select-CdDriveUi -PromptKey 'manage.chooseDriveRename'
    if ($drive) {
        $label = Read-CdDriveName -Default $drive.label
        try { Write-CdResult -Result (Rename-CdDrive -Id $drive.id -Label $label) }
        catch { Write-CdErrorInfo -Info (Get-CdErrorInfo $_) }
    }
    Wait-CdKeyPress
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
        Write-CdInfo -Text ('[2] ' + (Get-CdText 'manage.rename')) -Color White
        Write-CdInfo -Text ('[3] ' + (Get-CdText 'manage.remove')) -Color White
        Write-CdInfo -Text ('[0] ' + (Get-CdText 'manage.back')) -Color White
        switch (Read-CdChoice -Prompt (Get-CdText 'ui.choose') -Valid @('1', '2', '3', '0')) {
            '1' { Start-CdAddDriveWizard }
            '2' { Start-CdRenameDriveWizard }
            '3' { Start-CdRemoveDriveWizard }
            '0' { return }
        }
    }
}
