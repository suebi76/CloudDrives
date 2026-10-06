# Cloud accounts: adding (the sign-in itself is in AccountSignIn.ps1), signing in again, who is signed in, storage
# quota, removal. rclone stores the resulting (revocable) token or the obscured password in the encrypted rclone.conf.

$script:CdQuotaCache = @{}

function Remove-CdRemoteIfPresent {
    # Deletes an rclone remote when the configuration has it. Only a clean-up: a failure is logged, not thrown.
    param([Parameter(Mandatory)][string]$Name)
    try {
        if ((Get-CdRemoteNames) -contains $Name) { Remove-CdRemote -Name $Name }
    }
    catch { Write-CdLog -Level WARN -Component 'Accounts' -Message "Could not remove remote '$Name': $($_.Exception.Message)" }
}

function Get-CdRemoteAbout {
    # Storage usage of a remote (total/used/free in bytes; total may be missing for unlimited storage).
    param([Parameter(Mandatory)][string]$RemoteName, [int]$CacheSec = 300, [int]$TimeoutSec = 60)
    $now = Get-Date
    $cached = $script:CdQuotaCache[$RemoteName]
    if ($cached -and $null -ne $cached.Value -and ($now - $cached.Time).TotalSeconds -lt $CacheSec) { return $cached.Value }
    $about = Invoke-CdRc -Command 'operations/about' -Body @{ fs = "${RemoteName}:" } -TimeoutSec $TimeoutSec
    $script:CdQuotaCache[$RemoteName] = @{ Time = $now; Value = $about }
    $about
}

function Get-CdAccountQuota {
    # Quota for status displays: short timeout, and failures are remembered for two minutes so a slow or
    # throttled provider never blocks the menu.
    param([Parameter(Mandatory)][string]$AccountId)
    $remote = Get-CdAccountRemoteName -AccountId $AccountId
    $cached = $script:CdQuotaCache[$remote]
    if ($cached) {
        $age = ((Get-Date) - $cached.Time).TotalSeconds
        if ($null -ne $cached.Value -and $age -lt 300) { return $cached.Value }
        if ($null -eq $cached.Value -and $age -lt 120) { return $null }
    }
    try { return (Get-CdRemoteAbout -RemoteName $remote -CacheSec 0 -TimeoutSec 10) }
    catch {
        Write-CdLog -Level WARN -Component 'Accounts' -Message "Quota of '$AccountId' unavailable: $($_.Exception.Message)"
        $script:CdQuotaCache[$remote] = @{ Time = Get-Date; Value = $null }
        return $null
    }
}

function ConvertFrom-CdOAuthToken {
    # The access token from rclone's "token" value (a JSON blob), or $null.
    param([AllowNull()][AllowEmptyString()][string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }
    try { return [string]($Token | ConvertFrom-Json).access_token }
    catch { return $null }
}

function Get-CdRemoteIdentity {
    # Who is signed in on a remote: @{ Id; Name } with a stable account ID and a display name, or $null.
    # A request through rclone comes first: it renews an expired access token and stores it in the config.
    param(
        [Parameter(Mandatory)][string]$RemoteName,
        [Parameter(Mandatory)][string]$Provider,
        [int]$TimeoutSec = 20
    )
    $definition = Get-CdProvider -Id $Provider
    if (-not $definition -or -not $definition.ContainsKey('GetIdentity')) { return $null }
    $signedIn = $true
    try { [void](Get-CdRemoteAbout -RemoteName $RemoteName -CacheSec 60 -TimeoutSec $TimeoutSec) }
    catch {
        $signedIn = $false
        Write-CdLog -Level DEBUG -Component 'Accounts' -Message "'$RemoteName' is not usable right now: $((Get-CdErrorInfo $_).Code)"
    }
    $config = Invoke-CdRc -Command 'config/get' -Body @{ name = $RemoteName }
    $accessToken = $null
    if ($signedIn) { $accessToken = ConvertFrom-CdOAuthToken -Token ([string]$config.token) }
    & $definition.GetIdentity ([pscustomobject]@{ Config = $config; AccessToken = $accessToken })
}

function Update-CdAccountIdentities {
    # Remembers who is signed in on accounts that do not know it yet (accounts added before this check
    # existed), so that a later sign-in can be compared with it - even when that sign-in has expired.
    param([AllowEmptyCollection()][string[]]$AccountIds = @())
    $settings = Get-CdSettings
    $changed = $false
    foreach ($account in @($settings.accounts | Where-Object { $AccountIds -contains $_.id -and -not ($_.identity -and $_.identity.id) })) {
        try {
            $identity = Get-CdRemoteIdentity -RemoteName (Get-CdAccountRemoteName -AccountId $account.id) -Provider $account.provider -TimeoutSec 10
            if ($identity) {
                $account.identity = [ordered]@{ id = $identity.Id; name = $identity.Name }
                $changed = $true
            }
        }
        catch { Write-CdLog -Level DEBUG -Component 'Accounts' -Message "Identity of '$($account.id)' unavailable: $((Get-CdErrorInfo $_).Code)" }
    }
    if ($changed) {
        Save-CdSettings -Settings $settings
        Write-CdLog -Component 'Accounts' -Message 'Stored the signed-in identity of existing accounts.'
    }
}

function Update-CdAccountLogin {
    # Signs an existing account in again - after an expired or revoked sign-in, or with another OAuth client -
    # without removing it. The browser sign-in runs on a temporary remote; the account's remote only changes
    # once the new sign-in works and belongs to the same cloud account, so a cancelled or wrong sign-in changes
    # nothing. Mounted drives of the account are reconnected afterwards to use the new sign-in right away.
    param(
        [Parameter(Mandatory)][string]$AccountId,
        [string]$ClientId,
        [string]$ClientSecret,
        [scriptblock]$OnAuthUrl,
        [scriptblock]$ShouldCancel,
        # Called with (identity, account) when the previous identity is unknown; must return $true to go on.
        [scriptblock]$ConfirmIdentity,
        # Status texts of the steps (see Invoke-CdOAuthRemoteCreate).
        [scriptblock]$OnProgress,
        # Providers that sign in with a password (WebDAV): the new sign-in (New-CdWebDavCredential).
        [object]$WebDavLogin
    )
    $account = Get-CdAccount -Id $AccountId
    if (-not $account) { throw (New-CdException -Code 'CD-2006' -Detail "unknown account '$AccountId'") }
    $definition = Get-CdProvider -Id $account.provider
    $remote = Get-CdAccountRemoteName -AccountId $AccountId
    $signIn = Get-CdSignInRemoteName -AccountId $AccountId

    [void](Start-CdEngine)
    $exists = (Get-CdRemoteNames) -contains $remote
    $current = $null
    if ($exists) { $current = Invoke-CdRc -Command 'config/get' -Body @{ name = $remote } }
    if (-not $ClientId -and $current -and $current.client_id) {
        $ClientId = [string]$current.client_id
        $ClientSecret = [string]$current.client_secret
    }
    $clientChanged = $exists -and ([string]$ClientId -ne [string]$current.client_id -or [string]$ClientSecret -ne [string]$current.client_secret)

    # The identity the new sign-in has to match.
    $expected = $null
    if ($account.identity -and $account.identity.id) {
        $expected = [pscustomobject]@{ Id = [string]$account.identity.id; Name = [string]$account.identity.name }
    }
    elseif ($exists) {
        try { $expected = Get-CdRemoteIdentity -RemoteName $remote -Provider $account.provider -TimeoutSec 15 }
        catch { Write-CdLog -Level DEBUG -Component 'Accounts' -Message "Previous identity of '$AccountId' unknown: $((Get-CdErrorInfo $_).Code)" }
    }

    Remove-CdRemoteIfPresent -Name $signIn
    if (Test-CdPasswordSignIn -Definition $definition) {
        if (-not $WebDavLogin) { throw (New-CdException -Code 'CD-2006' -Detail "account '$AccountId' needs an address, a user and a password") }
        New-CdWebDavRemote -RemoteName $signIn -Login $WebDavLogin -OnProgress $OnProgress
    }
    else {
        $parameters = & $definition.NewParameters $ClientId $ClientSecret
        [void](Invoke-CdOAuthRemoteCreate -RemoteName $signIn -RcloneType $definition.RcloneType -Parameters $parameters -Answers (Get-CdConfigAnswers -Definition $definition) `
                -OnAuthUrl $OnAuthUrl -ShouldCancel $ShouldCancel -OnProgress $OnProgress)
    }
    try {
        Send-CdProgress -OnProgress $OnProgress -Text (Get-CdText 'progress.identity')
        $identity = Get-CdRemoteIdentity -RemoteName $signIn -Provider $account.provider
        if (-not $identity) { throw (New-CdException -Code 'CD-3008' -Detail 'the new sign-in could not be verified') }
        if ($expected -and $identity.Id -ne $expected.Id) {
            Write-CdLog -Level WARN -Component 'Accounts' -Message "New sign-in of '$AccountId' belongs to another account - discarded."
            throw (New-CdException -Code 'CD-3009' -Detail (Get-CdText 'relogin.otherAccount' $identity.Name, $expected.Name))
        }
        if (-not $expected -and $ConfirmIdentity -and -not (& $ConfirmIdentity $identity $account)) {
            throw (New-CdException -Code 'CD-3004' -Detail 'the signed-in account was not confirmed')
        }

        # Take over the new sign-in: only the values the browser sign-in produced, without running rclone's
        # configuration dialog again (nonInteractive stops at its first question, after storing the values).
        $new = Invoke-CdRc -Command 'config/get' -Body @{ name = $signIn }
        $values = [ordered]@{}
        foreach ($key in @('client_id', 'client_secret')) {
            # An empty value clears an own client the account no longer uses.
            if ($new.$key -or ($current -and $current.$key)) { $values[$key] = [string]$new.$key }
        }
        # The password is taken over obscured, as rclone stored it on the temporary remote.
        foreach ($key in @('token', 'drive_id', 'drive_type', 'user', 'pass')) {
            if ($new.$key) { $values[$key] = [string]$new.$key }
        }
        Backup-CdRcloneConfig
        if ($exists) {
            [void](Invoke-CdRc -Command 'config/update' -Body @{ name = $remote; parameters = $values; opt = @{ nonInteractive = $true; noObscure = $true } })
        }
        else {
            foreach ($property in $new.PSObject.Properties) {
                if ($property.Name -ne 'type' -and -not $values.Contains($property.Name)) { $values[$property.Name] = [string]$property.Value }
            }
            [void](Invoke-CdRc -Command 'config/create' -Body @{ name = $remote; type = $definition.RcloneType; parameters = $values; opt = @{ nonInteractive = $true; noObscure = $true } })
        }
    }
    finally {
        Remove-CdRemoteIfPresent -Name $signIn
    }
    # Drop cached connections that still use the old sign-in.
    try { [void](Invoke-CdRc -Command 'fscache/clear') } catch { Write-CdLog -Level DEBUG -Component 'Accounts' -Message "fscache/clear: $($_.Exception.Message)" }
    $script:CdQuotaCache.Remove($remote)

    $settings = Get-CdSettings
    $entry = @($settings.accounts | Where-Object { $_.id -eq $AccountId })[0]
    $entry.identity = [ordered]@{ id = $identity.Id; name = $identity.Name }
    if (-not (Test-CdPasswordSignIn -Definition $definition)) { $entry.clientId = $(if ($values.client_id) { 'own' } else { 'default' }) }
    Save-CdSettings -Settings $settings
    Write-CdLog -Component 'Accounts' -Message "Account '$AccountId' signed in again (client changed: $clientChanged)."

    Send-CdProgress -OnProgress $OnProgress -Text (Get-CdText 'progress.reconnect')
    $drives = @(Restart-CdAccountDrives -AccountId $AccountId)
    New-CdResult -Message (Get-CdText 'relogin.done' $account.label) -Data ([pscustomobject]@{
            Account       = $entry
            Identity      = $identity
            ClientChanged = $clientChanged
            Drives        = $drives
        })
}

function Get-CdOwnGoogleClients {
    # Own client IDs already used by configured Google accounts, so the user sets one up only once.
    $clients = New-Object System.Collections.Generic.List[object]
    foreach ($account in @((Get-CdSettings).accounts | Where-Object { $_.provider -eq 'drive' -and $_.clientId -eq 'own' })) {
        try {
            $remote = Invoke-CdRc -Command 'config/get' -Body @{ name = (Get-CdAccountRemoteName -AccountId $account.id) }
            $known = @($clients | Where-Object { $_.ClientId -eq $remote.client_id }).Count -gt 0
            if ($remote.client_id -and $remote.client_secret -and -not $known) {
                $clients.Add([pscustomobject]@{ AccountLabel = $account.label; ClientId = [string]$remote.client_id; ClientSecret = [string]$remote.client_secret })
            }
        }
        catch { Write-CdLog -Level WARN -Component 'Accounts' -Message "Client of '$($account.id)' unavailable: $($_.Exception.Message)" }
    }
    , $clients.ToArray()
}

function Add-CdAccount {
    # Adds an account: an rclone remote of its own, signed in through the browser (OAuth) or with address, user name and
    # password (WebDAV), then the entry in the settings. The rclone configuration is backed up before it changes.
    param(
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$Label,
        [string]$Kind = 'personal',
        [string]$ClientId,
        [string]$ClientSecret,
        [scriptblock]$OnAuthUrl,
        [scriptblock]$ShouldCancel,
        # Status texts of the steps (see Invoke-CdOAuthRemoteCreate).
        [scriptblock]$OnProgress,
        # Providers that sign in with a password (WebDAV): address, user and password (New-CdWebDavCredential).
        [object]$WebDavLogin
    )
    $definition = Get-CdProvider -Id $Provider
    if (-not $definition) { throw (New-CdException -Code 'CD-2006' -Detail "unknown provider '$Provider'") }

    $settings = Get-CdSettings
    $existingIds = @($settings.accounts | ForEach-Object { $_.id })
    $id = New-CdUniqueId -Text $Label -Existing $existingIds -Fallback $Provider
    $remote = Get-CdAccountRemoteName -AccountId $id

    [void](Start-CdEngine)
    Remove-CdRemoteIfPresent -Name $remote
    Backup-CdRcloneConfig

    if (Test-CdPasswordSignIn -Definition $definition) {
        if (-not $WebDavLogin) { throw (New-CdException -Code 'CD-2006' -Detail "provider '$Provider' needs an address, a user and a password") }
        New-CdWebDavRemote -RemoteName $remote -Login $WebDavLogin -OnProgress $OnProgress
    }
    else {
        $parameters = & $definition.NewParameters $ClientId $ClientSecret
        [void](Invoke-CdOAuthRemoteCreate -RemoteName $remote -RcloneType $definition.RcloneType -Parameters $parameters -Answers (Get-CdConfigAnswers -Definition $definition) `
                -OnAuthUrl $OnAuthUrl -ShouldCancel $ShouldCancel -OnProgress $OnProgress)
    }

    Send-CdProgress -OnProgress $OnProgress -Text (Get-CdText 'progress.quota')
    try { $about = Get-CdRemoteAbout -RemoteName $remote -CacheSec 0 }
    catch {
        Remove-CdRemoteIfPresent -Name $remote
        throw
    }

    # Remember who signed in, and refuse the same cloud account twice (more folders of one account become
    # additional drives instead).
    $identity = $null
    Send-CdProgress -OnProgress $OnProgress -Text (Get-CdText 'progress.identity')
    try { $identity = Get-CdRemoteIdentity -RemoteName $remote -Provider $Provider }
    catch { Write-CdLog -Level WARN -Component 'Accounts' -Message "Identity of the new account unavailable: $((Get-CdErrorInfo $_).Code)" }
    if ($identity) {
        $duplicate = @($settings.accounts | Where-Object { $_.provider -eq $Provider -and $_.identity -and $_.identity.id -eq $identity.Id }) | Select-Object -First 1
        if ($duplicate) {
            Remove-CdRemoteIfPresent -Name $remote
            throw (New-CdException -Code 'CD-3010' -Detail (Get-CdText 'account.duplicate' $identity.Name, $duplicate.label))
        }
    }

    $account = [ordered]@{
        id       = $id
        provider = $Provider
        kind     = $Kind
        label    = $Label
    }
    # Which OAuth client signs in (password sign-ins have none).
    if (-not (Test-CdPasswordSignIn -Definition $definition)) {
        $account.clientId = 'default'
        if ($ClientId) { $account.clientId = 'own' }
    }
    $account.added = (Get-Date).ToString('yyyy-MM-dd')
    if ($identity) { $account.identity = [ordered]@{ id = $identity.Id; name = $identity.Name } }
    $settings.accounts = Add-CdArrayItem -Array $settings.accounts -Item $account
    Save-CdSettings -Settings $settings
    Write-CdLog -Component 'Accounts' -Message "Account '$id' ($Provider/$Kind) added."
    New-CdResult -Message (Get-CdText 'account.added' $Label) -Data ([pscustomobject]@{ Account = $account; About = $about; Identity = $identity })
}

function Remove-CdAccount {
    # Disconnects and removes all drives of an account, deletes its rclone remotes and settings entries.
    param([Parameter(Mandatory)][string]$Id)
    $settings = Get-CdSettings
    $account = Get-CdAccount -Id $Id
    if (-not $account) { throw (New-CdException -Code 'CD-2006' -Detail "unknown account '$Id'") }
    $drives = @($settings.drives | Where-Object { $_.account -eq $Id })
    Remove-CdWantedDrives -DriveIds @($drives | ForEach-Object { [string]$_.id })

    [void](Start-CdEngine)
    $provider = Get-CdProvider -Id $account.provider
    $revokeUrl = [string]$provider.RevokeUrl
    if ($provider.ContainsKey('GetRevokeUrl')) {
        try { $revokeUrl = [string](& $provider.GetRevokeUrl $account (Invoke-CdRc -Command 'config/get' -Body @{ name = (Get-CdAccountRemoteName -AccountId $Id) })) }
        catch { Write-CdLog -Level DEBUG -Component 'Accounts' -Message "Revoke address of '$Id' unknown: $($_.Exception.Message)" }
    }
    foreach ($drive in $drives) {
        try { [void](Dismount-CdDrive -Drive $drive -Force) }
        catch { Write-CdLog -Level WARN -Component 'Accounts' -Message "Disconnect of '$($drive.id)' failed: $($_.Exception.Message)" }
        Remove-CdDriveLabel -Drive $drive
        if ($drive.encrypted) { Remove-CdRemoteIfPresent -Name (Get-CdVaultRemoteName -DriveId $drive.id) }
    }
    Remove-CdRemoteIfPresent -Name (Get-CdAccountRemoteName -AccountId $Id)

    $settings.drives = @($settings.drives | Where-Object { $_.account -ne $Id })
    $settings.accounts = @($settings.accounts | Where-Object { $_.id -ne $Id })
    Save-CdSettings -Settings $settings
    Write-CdLog -Component 'Accounts' -Message "Account '$Id' removed."
    New-CdResult -Message (Get-CdText 'account.removed' $account.label) -Data ([pscustomobject]@{ Account = $account; RevokeUrl = $revokeUrl })
}
