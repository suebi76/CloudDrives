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
    $settings.accounts = Add-CdArrayItem -Array $settings.accounts -Item $account
    Save-CdSettings -Settings $settings
    Write-CdLog -Component 'Accounts' -Message "Account '$id' ($Provider/$Kind) added."
    New-CdResult -Message (Get-CdText 'account.added' $Label) -Data ([pscustomobject]@{ Account = $account; About = $about })
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
