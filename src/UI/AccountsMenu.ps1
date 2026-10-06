# Managing accounts: the list, signing in again (also with another Google client ID) and removing an account.

function Select-CdAccountUi {
    # Lets the user pick one of the configured accounts (optionally of one provider); returns it or $null.
    param([string]$Provider)
    $accounts = @((Get-CdSettings).accounts | Where-Object { -not $Provider -or $_.provider -eq $Provider })
    if ($accounts.Count -eq 0) {
        if ($Provider -eq 'drive') { Write-CdInfo -Text (Get-CdText 'accounts.noGoogle') -Color Yellow }
        else { Write-CdInfo -Text (Get-CdText 'manage.noAccounts') -Color Yellow }
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

function Format-CdAccountLine {
    # "Google Pro  (Google Drive, eigene Client-ID)  name@example.com  K: V:"
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Account)
    $provider = Get-CdProvider -Id $Account.provider
    $kind = Get-CdText $provider.NameKey
    if ($Account.provider -eq 'webdav') { $kind = Get-CdText "provider.webdav.kind.$($Account.kind)" }
    if ($Account.provider -eq 'drive') {
        if ($Account.clientId -eq 'own') { $kind += ', ' + (Get-CdText 'accounts.clientOwn') }
        else { $kind += ', ' + (Get-CdText 'accounts.clientShared') }
    }
    $line = '{0}  ({1})' -f $Account.label, $kind
    if ($Account.identity -and $Account.identity.name) { $line += '  ' + $Account.identity.name }
    $letters = @((Get-CdSettings).drives | Where-Object { $_.account -eq $Account.id } | ForEach-Object { "$($_.letter):" }) -join ' '
    if ($letters) { $line += '  ' + $letters }
    $line
}

function Start-CdManageAccountsMenu {
    while ($true) {
        Clear-CdScreen
        Write-CdHeader -Subtitle (Get-CdText 'accounts.title')
        $accounts = @((Get-CdSettings).accounts)
        if ($accounts.Count -eq 0) { Write-CdInfo -Text (Get-CdText 'manage.noAccounts') }
        foreach ($account in $accounts) { Write-CdInfo -Text (Format-CdAccountLine -Account $account) }
        Write-Host ''
        Write-CdInfo -Text ('[1] ' + (Get-CdText 'accounts.relogin')) -Color White
        Write-CdInfo -Text ('[2] ' + (Get-CdText 'accounts.changeClient')) -Color White
        Write-CdInfo -Text ('[3] ' + (Get-CdText 'menu.removeAccount')) -Color White
        Write-CdInfo -Text ('[0] ' + (Get-CdText 'manage.back')) -Color White
        switch (Read-CdChoice -Prompt (Get-CdText 'ui.choose') -Valid @('1', '2', '3', '0')) {
            '1' { [void](Start-CdReloginWizard) }
            '2' { [void](Start-CdReloginWizard -ChangeClient) }
            '3' { Start-CdRemoveAccountWizard }
            '0' { return }
        }
    }
}

function Start-CdReloginWizard {
    # Signs an account in again without removing it - optionally with another Google client ID.
    # -Embedded continues on the current screen (e.g. right after a failed connect). Returns $true on success.
    param([System.Collections.IDictionary]$Account, [switch]$ChangeClient, [switch]$Embedded)
    if (-not $Embedded) {
        Clear-CdScreen
        $title = 'relogin.title'
        if ($ChangeClient) { $title = 'client.title' }
        Write-CdHeader -Subtitle (Get-CdText $title)
    }
    if (-not $Account) {
        $provider = $null
        if ($ChangeClient) {
            $provider = 'drive'
            Write-CdStep -Text (Get-CdText 'client.chooseAccount')
        }
        else { Write-CdStep -Text (Get-CdText 'relogin.chooseAccount') }
        $Account = Select-CdAccountUi -Provider $provider
        if (-not $Account) {
            # Only the "no accounts" message needs to stay readable; a cancelled choice returns at once.
            $available = @((Get-CdSettings).accounts | Where-Object { -not $provider -or $_.provider -eq $provider })
            if (-not $Embedded -and $available.Count -eq 0) { Wait-CdKeyPress }
            return $false
        }
    }
    $definition = Get-CdProvider -Id $Account.provider

    $client = $null
    if ($ChangeClient -and $Account.provider -ne 'drive') {
        Write-CdInfo -Text (Get-CdText 'client.onlyGoogle') -Color Yellow
        if (-not $Embedded) { Wait-CdKeyPress }
        return $false
    }
    if ($ChangeClient) {
        $current = $null
        try {
            [void](Start-CdEngine)
            $config = Invoke-CdRc -Command 'config/get' -Body @{ name = (Get-CdAccountRemoteName -AccountId $Account.id) }
            if ($config.client_id) { $current = [pscustomobject]@{ ClientId = [string]$config.client_id; ClientSecret = [string]$config.client_secret } }
        }
        catch { Write-CdLog -Level WARN -Component 'Wizard' -Message "Current client of '$($Account.id)' unavailable: $($_.Exception.Message)" }
        if ($current) { Write-CdInfo -Text (Get-CdText 'client.current' (Get-CdText 'client.currentOwn' $current.ClientId)) }
        else { Write-CdInfo -Text (Get-CdText 'client.current' (Get-CdText 'client.currentShared')) }
        Write-CdInfo -Text (Get-CdText 'client.explain') -Color DarkGray
        $client = Read-CdGoogleClient -Kind $Account.kind -Current $current
        if (-not $client) { return $false }
    }
    elseif ($Account.provider -eq 'drive' -and $Account.clientId -ne 'own') {
        Write-CdInfo -Text (Get-CdText 'relogin.sharedClientHint') -Color Yellow
    }

    Write-CdStep -Text (Get-CdText 'relogin.step' $Account.label)
    Write-CdInfo -Text (Get-CdText 'relogin.explain') -Color DarkGray
    if ($Account.identity -and $Account.identity.name) { Write-CdInfo -Text (Get-CdText 'relogin.useAccount' $Account.identity.name) -Color White }
    else { Write-CdInfo -Text (Get-CdText 'relogin.useSameAccount' $Account.label) -Color White }
    $mounted = Get-CdMountedDrives
    $letters = @((Get-CdSettings).drives | Where-Object { $_.account -eq $Account.id -and $mounted.ContainsKey("$($_.letter):".ToUpperInvariant()) } | ForEach-Object { "$($_.letter):" }) -join ', '
    if ($letters) { Write-CdInfo -Text (Get-CdText 'relogin.reconnectHint' $letters) -Color Yellow }
    if (-not (Read-CdYesNo -Prompt (Get-CdText 'relogin.confirm') -Default $true)) { return $false }

    $credential = $null
    if (Test-CdPasswordSignIn -Definition $definition) {
        $credential = Read-CdWebDavSignIn -Kind $Account.kind -Account $Account
        if (-not $credential) { return $false }
    }
    else {
        Write-CdStep -Text (Get-CdText 'wizard.add.loginStep' (Get-CdText $definition.NameKey))
        Write-CdInfo -Text (Get-CdText 'wizard.add.loginExplain')
        if ($Account.kind -eq 'workspace') { Write-CdInfo -Text (Get-CdText 'wizard.add.workspaceHint') -Color DarkGray }
    }
    $confirmIdentity = {
        param($Identity, $Owner)
        Complete-CdProgress
        Write-Host ''
        Read-CdYesNo -Prompt (Get-CdText 'relogin.confirmIdentity' $Identity.Name, $Owner.label) -Default $true
    }
    try {
        $result = Update-CdAccountLogin -AccountId $Account.id -ClientId $client.ClientId -ClientSecret $client.ClientSecret `
            -OnAuthUrl { param([string]$Url) Show-CdAuthUrl -Url $Url } -ShouldCancel { Test-CdEscapePressed } -ConfirmIdentity $confirmIdentity `
            -OnProgress { param([string]$Status) Write-CdProgress -Text $Status } -WebDavLogin $credential
    }
    catch {
        Complete-CdProgress
        Write-CdErrorInfo -Info (Get-CdErrorInfo $_)
        if (-not $Embedded) { Wait-CdKeyPress }
        return $false
    }
    Complete-CdProgress
    Write-Host ''
    Write-CdOk -Text $result.Message
    if ($result.Data.Identity.Name) { Write-CdInfo -Text (Get-CdText 'relogin.signedInAs' $result.Data.Identity.Name) }
    foreach ($item in @($result.Data.Drives)) { Write-CdResult -Result $item }
    Remove-CdClientFileUi -Client $client
    if (-not $Embedded) { Wait-CdKeyPress }
    $true
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
        if ($result.Data.RevokeUrl) { Write-CdInfo -Text (Get-CdText 'wizard.remove.revokeHint' $result.Data.RevokeUrl) -Color DarkGray }
        else { Write-CdInfo -Text (Get-CdText 'wizard.remove.passwordDeleted') -Color DarkGray }
    }
    catch { Write-CdErrorInfo -Info (Get-CdErrorInfo $_) }
    Wait-CdKeyPress
}
