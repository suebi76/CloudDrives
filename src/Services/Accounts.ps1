# Cloud accounts: sign-in through OAuth in the browser (handled by the engine), storage quota, removal.
# CloudDrives never sees a password - the user signs in on the provider's own page; rclone stores the
# resulting (revocable) token in the encrypted rclone.conf.

$script:CdQuotaCache = @{}

function Invoke-CdOAuthRemoteCreate {
    # Creates an OAuth remote through the engine. The browser opens via $OnAuthUrl; $ShouldCancel is polled.
    param(
        [Parameter(Mandatory)][string]$RemoteName,
        [Parameter(Mandatory)][string]$RcloneType,
        [System.Collections.IDictionary]$Parameters = @{},
        [scriptblock]$OnAuthUrl,
        [scriptblock]$ShouldCancel,
        [int]$TimeoutSec = 600
    )
    $allParameters = [ordered]@{}
    foreach ($key in $Parameters.Keys) { $allParameters[$key] = $Parameters[$key] }
    # We open the browser ourselves so the link can also be shown in the console.
    $allParameters['config_auth_no_browser'] = 'true'

    $body = [ordered]@{ name = $RemoteName; type = $RcloneType; parameters = $allParameters; opt = @{ obscure = $true }; _async = $true }
    $job = Invoke-CdRc -Command 'config/create' -Body $body
    $jobId = [int]$job.jobid
    Write-CdLog -Component 'Accounts' -Message "OAuth configuration started for '$RemoteName' (job $jobId)."

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $urlDelivered = $false
    while ($true) {
        $status = Invoke-CdRc -Command 'job/status' -Body @{ jobid = $jobId }
        if ($status.finished) { break }
        if (-not $urlDelivered) {
            $oauth = $null
            try { $oauth = Invoke-CdRc -Command 'config/oauthstatus' } catch { Write-CdLog -Level DEBUG -Component 'Accounts' -Message "oauthstatus: $($_.Exception.Message)" }
            if ($oauth -and $oauth.status -eq 'running' -and $oauth.authUrl) {
                $urlDelivered = $true
                if ($OnAuthUrl) { & $OnAuthUrl ([string]$oauth.authUrl) }
            }
        }
        $cancelled = $false
        if ($ShouldCancel) { $cancelled = [bool](& $ShouldCancel) }
        if ($cancelled -or (Get-Date) -gt $deadline) {
            try { [void](Invoke-CdRc -Command 'config/oauthstop') } catch { Write-CdLog -Level DEBUG -Component 'Accounts' -Message "oauthstop: $($_.Exception.Message)" }
            try { [void](Invoke-CdRc -Command 'job/stop' -Body @{ jobid = $jobId }) } catch { Write-CdLog -Level DEBUG -Component 'Accounts' -Message "job/stop: $($_.Exception.Message)" }
            Remove-CdRemoteIfPresent -Name $RemoteName
            if ($cancelled) { throw (New-CdException -Code 'CD-3004') }
            throw (New-CdException -Code 'CD-3005')
        }
        Start-Sleep -Milliseconds 500
    }

    if (-not $status.success) {
        $text = [string]$status.error
        $code = Resolve-CdErrorCode -Text $text
        if ($code -eq 'CD-9000') { $code = 'CD-3008' }
        Remove-CdRemoteIfPresent -Name $RemoteName
        throw (New-CdException -Code $code -Detail $text)
    }
    Write-CdLog -Component 'Accounts' -Message "OAuth configuration of '$RemoteName' completed."
    $status
}

function Remove-CdRemoteIfPresent {
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
        [scriptblock]$ConfirmIdentity
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
    $parameters = & $definition.NewParameters $ClientId $ClientSecret
    [void](Invoke-CdOAuthRemoteCreate -RemoteName $signIn -RcloneType $definition.RcloneType -Parameters $parameters -OnAuthUrl $OnAuthUrl -ShouldCancel $ShouldCancel)
    try {
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
        foreach ($key in @('token', 'drive_id', 'drive_type')) {
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
    $entry.clientId = $(if ($values.client_id) { 'own' } else { 'default' })
    Save-CdSettings -Settings $settings
    Write-CdLog -Component 'Accounts' -Message "Account '$AccountId' signed in again (client changed: $clientChanged)."

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
    param(
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$Label,
        [string]$Kind = 'personal',
        [string]$ClientId,
        [string]$ClientSecret,
        [scriptblock]$OnAuthUrl,
        [scriptblock]$ShouldCancel
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

    $parameters = & $definition.NewParameters $ClientId $ClientSecret
    [void](Invoke-CdOAuthRemoteCreate -RemoteName $remote -RcloneType $definition.RcloneType -Parameters $parameters -OnAuthUrl $OnAuthUrl -ShouldCancel $ShouldCancel)

    try { $about = Get-CdRemoteAbout -RemoteName $remote -CacheSec 0 }
    catch {
        Remove-CdRemoteIfPresent -Name $remote
        throw
    }

    # Remember who signed in, and refuse the same cloud account twice (more folders of one account become
    # additional drives instead).
    $identity = $null
    try { $identity = Get-CdRemoteIdentity -RemoteName $remote -Provider $Provider }
    catch { Write-CdLog -Level WARN -Component 'Accounts' -Message "Identity of the new account unavailable: $((Get-CdErrorInfo $_).Code)" }
    if ($identity) {
        $duplicate = @($settings.accounts | Where-Object { $_.provider -eq $Provider -and $_.identity -and $_.identity.id -eq $identity.Id }) | Select-Object -First 1
        if ($duplicate) {
            Remove-CdRemoteIfPresent -Name $remote
            throw (New-CdException -Code 'CD-3010' -Detail (Get-CdText 'account.duplicate' $identity.Name, $duplicate.label))
        }
    }

    $clientMode = 'default'
    if ($ClientId) { $clientMode = 'own' }
    $account = [ordered]@{
        id       = $id
        provider = $Provider
        kind     = $Kind
        label    = $Label
        clientId = $clientMode
        added    = (Get-Date).ToString('yyyy-MM-dd')
    }
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

    [void](Start-CdEngine)
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
    $provider = Get-CdProvider -Id $account.provider
    New-CdResult -Message (Get-CdText 'account.removed' $account.label) -Data ([pscustomobject]@{ Account = $account; RevokeUrl = $provider.RevokeUrl })
}
