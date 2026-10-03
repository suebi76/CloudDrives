# Drives: drive-letter management, mount options, connecting and disconnecting through the engine.

function Get-CdUsedDriveLetters {
    # Letters taken by disks, network drives (also disconnected persistent ones) and A-C.
    $used = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($letter in @('A', 'B', 'C')) { [void]$used.Add($letter) }
    foreach ($drive in [IO.DriveInfo]::GetDrives()) { [void]$used.Add($drive.Name.Substring(0, 1)) }
    foreach ($key in @(Get-ChildItem -Path 'HKCU:\Network' -ErrorAction SilentlyContinue)) {
        if ($key.PSChildName.Length -ge 1) { [void]$used.Add($key.PSChildName.Substring(0, 1)) }
    }
    @($used | Sort-Object)
}

function Get-CdFreeDriveLetters {
    # Free letters (D-Z) that are neither in use nor reserved by another CloudDrives drive.
    param([string]$IgnoreDriveId)
    $used = Get-CdUsedDriveLetters
    $reserved = @((Get-CdSettings).drives | Where-Object { $_.id -ne $IgnoreDriveId } | ForEach-Object { [string]$_.letter })
    @(68..90 | ForEach-Object { [string][char]$_ } | Where-Object { $used -notcontains $_ -and $reserved -notcontains $_ })
}

function Get-CdSuggestedDriveLetter {
    param([string[]]$Preferred = @())
    $free = Get-CdFreeDriveLetters
    foreach ($letter in $Preferred) { if ($free -contains $letter) { return $letter } }
    $free | Select-Object -First 1
}

function New-CdDrive {
    # Adds a drive definition to the settings and returns it.
    param(
        [Parameter(Mandatory)][string]$AccountId,
        [Parameter(Mandatory)][string]$Letter,
        [string]$Label,
        [string]$Path = '',
        [switch]$Encrypted,
        [string]$Id,
        [System.Collections.IDictionary]$Vault,
        [bool]$AutoConnect = $true
    )
    $settings = Get-CdSettings
    $account = Get-CdAccount -Id $AccountId
    if (-not $account) { throw (New-CdException -Code 'CD-2006' -Detail "unknown account '$AccountId'") }
    $Letter = $Letter.Trim().TrimEnd(':').ToUpperInvariant()
    if ((Get-CdFreeDriveLetters) -notcontains $Letter) { throw (New-CdException -Code 'CD-4001' -Detail "${Letter}: is not available") }
    if (-not $Label) { $Label = $account.label }
    if (-not $Id) { $Id = New-CdUniqueId -Text $Label -Existing @($settings.drives | ForEach-Object { $_.id }) -Fallback 'drive' }
    $drive = [ordered]@{
        id          = $Id
        account     = $AccountId
        label       = $Label
        letter      = $Letter
        path        = ([string]$Path).Trim('/')
        encrypted   = [bool]$Encrypted
        autoConnect = $AutoConnect
        readOnly    = $false
    }
    if ($Encrypted) { $drive.vault = $Vault }
    $settings.drives = Add-CdArrayItem -Array $settings.drives -Item $drive
    Save-CdSettings -Settings $settings
    Write-CdLog -Component 'Drives' -Message "Drive '$id' (${Letter}:) added for account '$AccountId'."
    $drive
}

function Get-CdDriveFs {
    # The rclone path that is mounted for a drive.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Drive)
    if ($Drive.encrypted) { return "$(Get-CdVaultRemoteName -DriveId $Drive.id):" }
    '{0}:{1}' -f (Get-CdAccountRemoteName -AccountId $Drive.account), ([string]$Drive.path).Trim('/')
}

function Get-CdMountOptions {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Drive,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Account,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings
    )
    $options = [ordered]@{
        network_mode       = $true
        volname            = "\\CloudDrives\$($Drive.id)"
        vfs_cache_mode     = 'full'
        vfs_cache_max_size = [string]$Settings.cache.maxSizePerDrive
        vfs_cache_max_age  = [string]$Settings.cache.maxAge
        vfs_write_back     = '5s'
    }
    $provider = Get-CdProvider -Id $Account.provider
    foreach ($key in $provider.MountOptions.Keys) { $options[$key] = $provider.MountOptions[$key] }
    switch ([string]$Settings.profile) {
        'fast' { $options.vfs_read_ahead = '256M'; $options.vfs_read_chunk_streams = 4 }
        'lean' { $options.vfs_cache_max_size = '2G'; $options.vfs_cache_max_age = '1h' }
    }
    if ($Drive.readOnly) { $options.read_only = $true }
    $options
}

function Get-CdMountedDrives {
    # Map "K:" -> mount info for everything the running engine has mounted.
    $map = @{}
    if (-not (Test-CdEngineRunning)) { return $map }
    $list = Invoke-CdRc -Command 'mount/listmounts'
    foreach ($mount in @($list.mountPoints)) {
        if ($mount -and $mount.MountPoint) { $map[([string]$mount.MountPoint).ToUpperInvariant()] = $mount }
    }
    $map
}

function Get-CdPendingUploadCount {
    param([Parameter(Mandatory)][string]$Fs)
    try {
        $stats = Invoke-CdRc -Command 'vfs/stats' -Body @{ fs = $Fs } -TimeoutSec 15
        if (-not $stats.diskCache) { return 0 }
        return ([int]$stats.diskCache.uploadsInProgress + [int]$stats.diskCache.uploadsQueued)
    }
    catch {
        Write-CdLog -Level DEBUG -Component 'Drives' -Message "vfs/stats for '$Fs': $($_.Exception.Message)"
        return 0
    }
}

function Wait-CdDriveReady {
    param([Parameter(Mandatory)][string]$MountPoint, [int]$TimeoutSec = 15)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ([IO.Directory]::Exists("$MountPoint\")) { return $true }
        Start-Sleep -Milliseconds 250
    }
    $false
}

function Mount-CdDrive {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Drive)
    $settings = Get-CdSettings
    $account = Get-CdAccount -Id $Drive.account
    if (-not $account) { throw (New-CdException -Code 'CD-2006' -Detail "drive '$($Drive.id)' references unknown account '$($Drive.account)'") }
    $mountPoint = "$($Drive.letter):".ToUpperInvariant()

    if ((Get-CdMountedDrives).ContainsKey($mountPoint)) {
        return (New-CdResult -Code 'CD-0001' -Message (Get-CdText 'drive.alreadyConnected' $Drive.label, $mountPoint) -Data $Drive)
    }
    if ((Get-CdUsedDriveLetters) -contains [string]$Drive.letter) {
        throw (New-CdException -Code 'CD-4001' -Detail "$mountPoint is already in use")
    }
    if ($Drive.encrypted) {
        # Never mount a vault with a wrong or missing key - new files would be encrypted with it.
        if ((Get-CdRemoteNames) -notcontains (Get-CdVaultRemoteName -DriveId $Drive.id)) { throw (New-CdException -Code 'CD-6003') }
        if (-not (Test-CdVaultKey -DriveId $Drive.id)) { throw (New-CdException -Code 'CD-6001') }
    }

    $body = [ordered]@{ fs = (Get-CdDriveFs -Drive $Drive); mountPoint = $mountPoint; mountType = 'cmount' }
    $options = Get-CdMountOptions -Drive $Drive -Account $account -Settings $settings
    foreach ($key in $options.Keys) { $body[$key] = $options[$key] }

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            [void](Invoke-CdRc -Command 'mount/mount' -Body $body -TimeoutSec 120)
            break
        }
        catch {
            $code = Get-CdErrorCode $_
            if ($attempt -lt 3 -and @('CD-5001', 'CD-3002', 'CD-4003') -contains $code) {
                Write-CdLog -Level WARN -Component 'Drives' -Message "Mount of '$($Drive.id)' failed ($code), retrying."
                Start-Sleep -Seconds (2 * $attempt)
                continue
            }
            throw
        }
    }
    if (-not (Wait-CdDriveReady -MountPoint $mountPoint)) {
        throw (New-CdException -Code 'CD-4002' -Detail "$mountPoint did not become ready")
    }
    Set-CdDriveLabel -Drive $Drive
    Write-CdLog -Component 'Drives' -Message "Drive '$($Drive.id)' connected as $mountPoint."
    New-CdResult -Message (Get-CdText 'drive.connected' $Drive.label, $mountPoint) -Data $Drive
}

function Dismount-CdDrive {
    # Disconnects a drive. Without -Force, pending uploads are reported (code CD-4006) instead.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Drive, [switch]$Force)
    $mountPoint = "$($Drive.letter):".ToUpperInvariant()
    $mounted = Get-CdMountedDrives
    if (-not $mounted.ContainsKey($mountPoint)) {
        return (New-CdResult -Code 'CD-0002' -Message (Get-CdText 'drive.notConnected' $Drive.label, $mountPoint) -Data $Drive)
    }
    if (-not $Force) {
        $pending = Get-CdPendingUploadCount -Fs ([string]$mounted[$mountPoint].Fs)
        if ($pending -gt 0) {
            return (New-CdResult -Success $false -Code 'CD-4006' -Message (Get-CdText 'drive.pendingUploads' $Drive.label, $pending) -Data ([pscustomobject]@{ Drive = $Drive; Pending = $pending }))
        }
    }
    [void](Invoke-CdRc -Command 'mount/unmount' -Body @{ mountPoint = $mountPoint } -TimeoutSec 60)
    Write-CdLog -Component 'Drives' -Message "Drive '$($Drive.id)' disconnected from $mountPoint."
    New-CdResult -Message (Get-CdText 'drive.disconnected' $Drive.label, $mountPoint) -Data $Drive
}

function Remove-CdDrive {
    # Disconnects a drive and removes its definition (and the vault key on this PC). Cloud data stays untouched.
    param([Parameter(Mandatory)][string]$Id)
    $drive = Get-CdDrive -Id $Id
    if (-not $drive) { throw (New-CdException -Code 'CD-2006' -Detail "unknown drive '$Id'") }
    if (Test-CdEngineRunning) {
        try { [void](Dismount-CdDrive -Drive $drive -Force) }
        catch { Write-CdLog -Level WARN -Component 'Drives' -Message "Disconnect of '$($drive.id)' failed: $($_.Exception.Message)" }
    }
    if ($drive.encrypted) {
        [void](Start-CdEngine)
        Remove-CdRemoteIfPresent -Name (Get-CdVaultRemoteName -DriveId $drive.id)
    }
    Remove-CdDriveLabel -Drive $drive
    $settings = Get-CdSettings
    $settings.drives = @($settings.drives | Where-Object { $_.id -ne $drive.id })
    Save-CdSettings -Settings $settings
    if ((Get-CdMountedDrives).Count -eq 0 -and (Read-CdEngineState)) { Stop-CdEngine }
    Write-CdLog -Component 'Drives' -Message "Drive '$($drive.id)' removed."
    New-CdResult -Message (Get-CdText 'drive.removed' $drive.label, "$($drive.letter):") -Data $drive
}

function Get-CdDriveStatusList {
    param([switch]$IncludeQuota)
    $settings = Get-CdSettings
    $mounted = Get-CdMountedDrives
    $quotaByAccount = @{}
    foreach ($drive in @($settings.drives)) {
        $mountPoint = "$($drive.letter):".ToUpperInvariant()
        $isMounted = $mounted.ContainsKey($mountPoint)
        $pending = 0
        $quota = $null
        if ($isMounted) {
            $pending = Get-CdPendingUploadCount -Fs ([string]$mounted[$mountPoint].Fs)
            if ($IncludeQuota) {
                if (-not $quotaByAccount.ContainsKey($drive.account)) { $quotaByAccount[$drive.account] = Get-CdAccountQuota -AccountId $drive.account }
                $quota = $quotaByAccount[$drive.account]
            }
        }
        [pscustomobject]@{
            PSTypeName     = 'CloudDrives.DriveStatus'
            Drive          = $drive
            Account        = Get-CdAccount -Id $drive.account
            MountPoint     = $mountPoint
            Mounted        = $isMounted
            PendingUploads = $pending
            Quota          = $quota
        }
    }
}
