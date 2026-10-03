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
        Write-CdStep -Text (Get-CdText 'wizard.add.clientQuestion')
        Write-CdInfo -Text ('[1] ' + (Get-CdText 'wizard.add.client.default'))
        Write-CdInfo -Text ('[2] ' + (Get-CdText 'wizard.add.client.own'))
        $clientChoice = Read-CdChoice -Prompt (Get-CdText 'ui.choose') -Valid @('1', '2', '0') -Default '1'
        if ($clientChoice -eq '0') { return }
        if ($clientChoice -eq '2') {
            Write-CdInfo -Text (Get-CdText 'wizard.add.client.ownHint' (Join-Path (Get-CdContext).AppRoot 'docs\GOOGLE-OAUTH.md')) -Color DarkGray
            $clientId = Read-CdText -Prompt (Get-CdText 'wizard.add.client.idPrompt')
            if ($clientId) { $clientSecret = Read-CdSecretText -Prompt (Get-CdText 'wizard.add.client.secretPrompt') }
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
    if ($about -and $null -ne $about.used) {
        if ($about.total) { Write-CdInfo -Text (Get-CdText 'wizard.add.quota' (Format-CdSize $about.used), (Format-CdSize $about.total)) }
        else { Write-CdInfo -Text (Get-CdText 'wizard.add.quotaUsed' (Format-CdSize $about.used)) }
    }

    $suggested = Get-CdSuggestedDriveLetter -Preferred $definition.PreferredLetters
    $free = Get-CdFreeDriveLetters
    Write-CdStep -Text (Get-CdText 'wizard.add.letterStep')
    Write-CdInfo -Text (Get-CdText 'wizard.add.freeLetters' (($free | ForEach-Object { "${_}:" }) -join ' ')) -Color DarkGray
    $letter = $null
    while (-not $letter) {
        $answer = Read-CdText -Prompt (Get-CdText 'wizard.add.letterPrompt') -Default $suggested
        if ($answer) {
            $candidate = $answer.Trim().TrimEnd(':').ToUpperInvariant()
            if ($free -contains $candidate) { $letter = $candidate }
            else { Write-CdInfo -Text (Get-CdText 'wizard.add.letterInvalid' $candidate) -Color Yellow }
        }
    }

    try { $drive = New-CdDrive -AccountId $account.id -Letter $letter -Label $label }
    catch {
        Write-CdErrorInfo -Info (Get-CdErrorInfo $_)
        Wait-CdKeyPress
        return
    }

    if (Read-CdYesNo -Prompt (Get-CdText 'wizard.add.connectNow' "${letter}:") -Default $true) {
        Write-Host ''
        $results = Invoke-CdConnect -Selection @($drive.id)
        foreach ($item in $results) { Write-CdResult -Result $item }
    }
    Wait-CdKeyPress
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
