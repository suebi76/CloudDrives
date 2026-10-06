# Adding an account: provider and name, sign-in in the browser (OAuth) or with address, user name and password
# (WebDAV), an own Google client ID, and the first drives of the new account.

function Show-CdAuthUrl {
    # Opens the provider's sign-in page in the browser and also shows the link (if the browser stays closed).
    param([Parameter(Mandatory)][string]$Url)
    Complete-CdProgress
    Write-CdInfo -Text (Get-CdText 'wizard.add.browserOpening')
    Write-CdInfo -Text ('  ' + $Url) -Color Cyan
    try { Start-Process -FilePath $Url } catch { Write-CdInfo -Text (Get-CdText 'wizard.add.browserFailed') -Color Yellow }
    Write-CdInfo -Text (Get-CdText 'wizard.add.cancelHint') -Color DarkGray
}

function Read-CdGoogleClient {
    # Asks for an own Google OAuth client: 1) the client of another configured account, 2) a downloaded
    # client file, 3) manual entry. -Current excludes the client an account already uses (same ID and secret).
    # Returns @{ ClientId; ClientSecret; File } or $null when cancelled.
    param([string]$Kind, [object]$Current)
    $currentId = $null
    $currentSecret = $null
    if ($Current) {
        $currentId = [string]$Current.ClientId
        $currentSecret = [string]$Current.ClientSecret
    }
    try {
        [void](Start-CdEngine)
        foreach ($known in @(Get-CdOwnGoogleClients)) {
            if ($known.ClientId -eq $currentId -and $known.ClientSecret -eq $currentSecret) { continue }
            Write-CdInfo -Text (Get-CdText 'wizard.add.client.reuseFound' $known.AccountLabel, $known.ClientId)
            if (Read-CdYesNo -Prompt (Get-CdText 'wizard.add.client.reuse') -Default $true) {
                return [pscustomobject]@{ ClientId = $known.ClientId; ClientSecret = $known.ClientSecret; File = $null }
            }
        }
    }
    catch { Write-CdLog -Level WARN -Component 'Wizard' -Message "Existing clients unavailable: $($_.Exception.Message)" }
    $file = Find-CdGoogleClientFile
    if ($file -and -not ($file.ClientId -eq $currentId -and $file.ClientSecret -eq $currentSecret)) {
        Write-CdInfo -Text (Get-CdText 'wizard.add.client.fileFound' (Split-Path -Leaf $file.Path), $file.ClientId)
        if (Read-CdYesNo -Prompt (Get-CdText 'wizard.add.client.fileUse') -Default $true) {
            return [pscustomobject]@{ ClientId = $file.ClientId; ClientSecret = $file.ClientSecret; File = $file }
        }
    }
    Write-CdInfo -Text (Get-CdText 'wizard.add.client.ownHint' (Join-Path (Get-CdContext).AppRoot 'docs\GOOGLE-OAUTH.md')) -Color DarkGray
    if ($Kind -eq 'workspace') { Write-CdInfo -Text (Get-CdText 'wizard.add.client.workspaceHint') -Color DarkGray }
    $clientId = $null
    while (-not $clientId) {
        $answer = Read-CdText -Prompt (Get-CdText 'wizard.add.client.idPrompt')
        if (-not $answer) { return $null }
        if (Test-CdGoogleClientId -ClientId $answer) { $clientId = $answer.Trim() }
        else { Write-CdInfo -Text (Get-CdText 'wizard.add.client.idInvalid') -Color Yellow }
    }
    $secret = $null
    while (-not $secret) { $secret = Read-CdSecretText -Prompt (Get-CdText 'wizard.add.client.secretPrompt') }
    [pscustomobject]@{ ClientId = $clientId; ClientSecret = $secret; File = $null }
}

function Remove-CdClientFileUi {
    # The downloaded client file holds the secret in plain text; CloudDrives keeps it encrypted now.
    param([object]$Client)
    if (-not $Client -or -not $Client.File -or -not (Test-Path -LiteralPath $Client.File.Path)) { return }
    Write-CdInfo -Text (Get-CdText 'wizard.add.client.fileDeleteHint' (Split-Path -Leaf $Client.File.Path)) -Color DarkGray
    if (Read-CdYesNo -Prompt (Get-CdText 'wizard.add.client.fileDelete') -Default $true) {
        Remove-Item -LiteralPath $Client.File.Path -Force
        Write-CdOk -Text (Get-CdText 'wizard.add.client.fileDeleted')
    }
}

function Start-CdAddAccountWizard {
    Clear-CdScreen
    Write-CdHeader -Subtitle (Get-CdText 'wizard.add.title')

    Write-CdStep -Text (Get-CdText 'wizard.add.providerQuestion')
    Write-CdInfo -Text ('[1] ' + (Get-CdText 'wizard.add.provider.onedrive'))
    Write-CdInfo -Text ('[2] ' + (Get-CdText 'wizard.add.provider.googlePersonal'))
    Write-CdInfo -Text ('[3] ' + (Get-CdText 'wizard.add.provider.googleWorkspace'))
    Write-CdInfo -Text ('[4] ' + (Get-CdText 'wizard.add.provider.nextcloud'))
    Write-CdInfo -Text ('[5] ' + (Get-CdText 'wizard.add.provider.iserv'))
    Write-CdInfo -Text ('[6] ' + (Get-CdText 'wizard.add.provider.webdav'))
    Write-CdInfo -Text ('[0] ' + (Get-CdText 'ui.cancel'))
    $choice = Read-CdChoice -Prompt (Get-CdText 'ui.choose') -Valid @('1', '2', '3', '4', '5', '6', '0')
    switch ($choice) {
        '1' { $provider = 'onedrive'; $kind = 'personal'; $defaultLabel = Get-CdText 'wizard.add.defaultLabel.onedrive' }
        '2' { $provider = 'drive'; $kind = 'personal'; $defaultLabel = Get-CdText 'wizard.add.defaultLabel.googlePersonal' }
        '3' { $provider = 'drive'; $kind = 'workspace'; $defaultLabel = Get-CdText 'wizard.add.defaultLabel.googleWorkspace' }
        '4' { $provider = 'webdav'; $kind = 'nextcloud'; $defaultLabel = Get-CdText 'wizard.add.defaultLabel.nextcloud' }
        '5' { $provider = 'webdav'; $kind = 'iserv'; $defaultLabel = Get-CdText 'wizard.add.defaultLabel.iserv' }
        '6' { $provider = 'webdav'; $kind = 'other'; $defaultLabel = Get-CdText 'wizard.add.defaultLabel.webdav' }
        default { return }
    }
    $definition = Get-CdProvider -Id $provider

    $label = Read-CdText -Prompt (Get-CdText 'wizard.add.labelPrompt') -Default $defaultLabel
    if ([string]::IsNullOrWhiteSpace($label)) { $label = $defaultLabel }

    $client = $null
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
            $client = Read-CdGoogleClient -Kind $kind
            if (-not $client) { return }
        }
        else {
            Write-CdInfo -Text (Get-CdText 'wizard.add.client.sharedWarning') -Color Yellow
        }
    }

    $credential = $null
    if (Test-CdPasswordSignIn -Definition $definition) {
        $credential = Read-CdWebDavSignIn -Kind $kind
        if (-not $credential) { return }
    }
    else {
        Write-CdStep -Text (Get-CdText 'wizard.add.loginStep' (Get-CdText $definition.NameKey))
        Write-CdInfo -Text (Get-CdText 'wizard.add.loginExplain')
        if ($kind -eq 'workspace') { Write-CdInfo -Text (Get-CdText 'wizard.add.workspaceHint') -Color DarkGray }
    }
    try {
        $result = Add-CdAccount -Provider $provider -Label $label -Kind $kind -ClientId $client.ClientId -ClientSecret $client.ClientSecret `
            -OnAuthUrl { param([string]$Url) Show-CdAuthUrl -Url $Url } -ShouldCancel { Test-CdEscapePressed } `
            -OnProgress { param([string]$Status) Write-CdProgress -Text $Status } -WebDavLogin $credential
    }
    catch {
        Complete-CdProgress
        Write-CdErrorInfo -Info (Get-CdErrorInfo $_)
        Wait-CdKeyPress
        return
    }
    Complete-CdProgress
    $account = $result.Data.Account
    $about = $result.Data.About
    Write-Host ''
    Write-CdOk -Text $result.Message
    if ($result.Data.Identity -and $result.Data.Identity.Name) { Write-CdInfo -Text (Get-CdText 'relogin.signedInAs' $result.Data.Identity.Name) }
    Remove-CdClientFileUi -Client $client
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

function Read-CdWebDavSignIn {
    # The sign-in of a WebDAV account: Nextcloud signs in in the browser and hands over an app password, IServ and
    # other servers take the address, the user name and the password. With -Account (signing in again) address and
    # user stay and only the password is asked for. Returns a credential, or $null when cancelled or failed (the
    # error has been shown).
    param([Parameter(Mandatory)][ValidateSet('nextcloud', 'iserv', 'other')][string]$Kind, [System.Collections.IDictionary]$Account)
    $current = $null
    if ($Account) {
        try {
            [void](Start-CdEngine)
            $current = Get-CdWebDavAccountInfo -AccountId $Account.id
        }
        catch { Write-CdLog -Level WARN -Component 'Wizard' -Message "WebDAV address of '$($Account.id)' unknown: $($_.Exception.Message)" }
    }
    try {
        if ($Kind -eq 'nextcloud') {
            $davUrl = ''
            if ($current -and $current.Server) {
                $server = $current.Server
                $davUrl = $current.Url
            }
            else {
                Write-CdStep -Text (Get-CdText 'webdav.nextcloud.step')
                Write-CdInfo -Text (Get-CdText 'webdav.nextcloud.addressHint') -Color DarkGray
                $answer = Read-CdText -Prompt (Get-CdText 'webdav.nextcloud.addressPrompt')
                if ([string]::IsNullOrWhiteSpace($answer)) { return $null }
                $address = ConvertTo-CdWebDavAddress -Kind 'nextcloud' -Address $answer
                $server = $address.Server
                $davUrl = $address.Url
            }
            Write-CdStep -Text (Get-CdText 'wizard.add.loginStep' (Get-CdText 'provider.webdav.kind.nextcloud'))
            # The browser sign-in first; a Nextcloud that refuses it for programs gets an app password instead.
            $nextcloudBrowser = @{ Opened = $false }
            try {
                return (Invoke-CdNextcloudLogin -Server $server -ShouldCancel { Test-CdEscapePressed } `
                        -OnAuthUrl { param([string]$Url) $nextcloudBrowser.Opened = $true; Write-CdInfo -Text (Get-CdText 'webdav.nextcloud.explain'); Show-CdAuthUrl -Url $Url } `
                        -OnProgress { param([string]$Status) Write-CdProgress -Text $Status })
            }
            catch {
                if ((Get-CdErrorCode $_) -ne 'CD-3014' -or $nextcloudBrowser.Opened) { throw }
                Write-CdLog -Component 'Wizard' -Message "Nextcloud refuses the browser sign-in: $((Get-CdErrorInfo $_).Detail)"
            }
            Write-CdInfo -Text (Get-CdText 'webdav.nextcloud.noBrowserLogin') -Color Yellow
            $security = $server + '/settings/user/security'
            Write-CdInfo -Text ('  ' + $security) -Color Cyan
            if (Read-CdYesNo -Prompt (Get-CdText 'webdav.nextcloud.openSecurity') -Default $true) {
                try { Start-Process -FilePath $security } catch { Write-CdInfo -Text (Get-CdText 'wizard.add.browserFailed') -Color Yellow }
            }
            $defaultUser = ''
            if ($current) { $defaultUser = $current.User }
            $user = Read-CdText -Prompt (Get-CdText 'webdav.nextcloud.userPrompt') -Default $defaultUser
            if ([string]::IsNullOrWhiteSpace($user)) { return $null }
            Write-CdInfo -Text (Get-CdText 'webdav.passwordNote') -Color DarkGray
            $password = Read-CdSecureText -Prompt (Get-CdText 'webdav.nextcloud.passwordPrompt')
            if (-not $password -or $password.Length -eq 0) { return $null }
            return (New-CdNextcloudCredential -Server $server -Url $davUrl -User $user.Trim() -Password $password)
        }
        if ($current -and $current.Url -and $current.User) {
            $url = $current.Url
            $user = $current.User
            Write-CdInfo -Text (Get-CdText 'webdav.reloginUser' ('{0} @ {1}' -f $user, $current.HostName)) -Color White
        }
        else {
            Write-CdStep -Text (Get-CdText "webdav.$Kind.step")
            Write-CdInfo -Text (Get-CdText "webdav.$Kind.addressHint") -Color DarkGray
            $answer = Read-CdText -Prompt (Get-CdText "webdav.$Kind.addressPrompt")
            if ([string]::IsNullOrWhiteSpace($answer)) { return $null }
            $url = (ConvertTo-CdWebDavAddress -Kind $Kind -Address $answer).Url
            Write-CdInfo -Text (Get-CdText 'webdav.address' $url) -Color DarkGray
            $user = Read-CdText -Prompt (Get-CdText "webdav.$Kind.userPrompt")
            if ([string]::IsNullOrWhiteSpace($user)) { return $null }
        }
        Write-CdInfo -Text (Get-CdText 'webdav.passwordNote') -Color DarkGray
        $password = Read-CdSecureText -Prompt (Get-CdText "webdav.$Kind.passwordPrompt")
        if (-not $password -or $password.Length -eq 0) { return $null }
        New-CdWebDavCredential -Url $url -Kind $Kind -User $user.Trim() -Password $password
    }
    catch {
        Complete-CdProgress
        Write-CdErrorInfo -Info (Get-CdErrorInfo $_)
        Wait-CdKeyPress
        $null
    }
}

function Complete-CdNewDrives {
    # Offers to connect freshly created drives right away and - once - to set up the autostart.
    param([object[]]$Drives)
    if (@($Drives).Count -gt 0) {
        $letters = (@($Drives) | ForEach-Object { "$($_.letter):" }) -join ', '
        if (Read-CdYesNo -Prompt (Get-CdText 'wizard.add.connectNow' $letters) -Default $true) {
            Write-Host ''
            try { $results = Invoke-CdConnect -Selection @(@($Drives) | ForEach-Object { $_.id }) -OnProgress { param([string]$Status) Write-CdProgress -Text $Status } }
            finally { Complete-CdProgress }
            foreach ($item in $results) { Write-CdResult -Result $item }
        }
        Request-CdAutostart
    }
    Wait-CdKeyPress
}
