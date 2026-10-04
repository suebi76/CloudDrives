# Commands for connecting and disconnecting drives. They return one result per drive and never write
# to the screen, so the console menu, the command line and (later) the tray app can share them.

function Select-CdDrives {
    # Resolves drive ids/letters; without selection all drives (optionally only auto-connect ones).
    param([string[]]$Selection, [switch]$AutoConnectOnly)
    $all = @((Get-CdSettings).drives)
    if (-not $Selection -or $Selection -contains 'all') {
        if ($AutoConnectOnly) { return @($all | Where-Object { $_.autoConnect -ne $false }) }
        return $all
    }
    $selected = foreach ($item in $Selection) {
        $drive = Get-CdDrive -Id $item
        if (-not $drive) { throw (New-CdException -Code 'CD-2006' -Detail "unknown drive '$item'") }
        $drive
    }
    @($selected)
}

function Invoke-CdConnect {
    param(
        [string[]]$Selection,
        [switch]$Silent,
        [switch]$AllowInstall,
        [scriptblock]$OnResult,
        # Status texts of the steps: waiting for the network, starting the engine, each drive.
        [scriptblock]$OnProgress
    )
    $drives = Select-CdDrives -Selection $Selection -AutoConnectOnly:(-not $Selection)
    if ($drives.Count -eq 0) { return @() }
    # The user (or the autostart) wants these drives - even if this attempt fails, the watchdog keeps trying.
    Add-CdWantedDrives -DriveIds @($drives | ForEach-Object { [string]$_.id })

    $waitSec = 15
    if ($Silent) { $waitSec = 120 }
    if (-not (Wait-CdNetwork -TimeoutSec $waitSec -OnWaiting { Send-CdProgress -OnProgress $OnProgress -Text (Get-CdText 'progress.network') })) {
        $offline = New-CdResult -Success $false -Code 'CD-5001' -Message (Get-CdText 'error.CD-5001.title')
        if ($OnResult) { & $OnResult $offline }
        return @($offline)
    }

    $lock = Enter-CdLock -Name 'connect' -TimeoutSec 180
    try {
        if ($OnProgress -and -not (Test-CdEngineRunning)) { Send-CdProgress -OnProgress $OnProgress -Text (Get-CdText 'progress.engine') }
        [void](Start-CdEngine -AllowInstall:$AllowInstall)
        $results = foreach ($drive in $drives) {
            Send-CdProgress -OnProgress $OnProgress -Text (Get-CdText 'progress.connect' ('{0} ({1}:)' -f $drive.label, $drive.letter))
            try { $result = Mount-CdDrive -Drive $drive }
            catch {
                $info = Get-CdErrorInfo $_
                Write-CdLog -Level ERROR -Component 'Connect' -Message "Drive '$($drive.id)' failed: $($info.Code) $($info.Detail)"
                $result = New-CdResult -Success $false -Code $info.Code -Message (Get-CdText 'drive.connectFailed' $drive.label, "$($drive.letter):") -Detail $info.Detail -Data $drive
            }
            if ($OnResult) { & $OnResult $result }
            $result
        }
    }
    finally {
        Exit-CdLock -Mutex $lock
    }
    # Learn who is signed in on older accounts while their sign-in works (needed to check a later sign-in).
    $connected = @($results | Where-Object { $_.Success -and $_.Data -and $_.Data.account } | ForEach-Object { [string]$_.Data.account } | Select-Object -Unique)
    if ($connected.Count -gt 0) { Update-CdAccountIdentities -AccountIds $connected }
    @($results)
}

function Invoke-CdDisconnect {
    param(
        [string[]]$Selection,
        [switch]$Force,
        [scriptblock]$OnResult,
        # Status text of each drive.
        [scriptblock]$OnProgress
    )
    $drives = Select-CdDrives -Selection $Selection
    # Disconnected on purpose: the watchdog must not bring these drives back.
    Remove-CdWantedDrives -DriveIds @($drives | ForEach-Object { [string]$_.id })
    if (-not (Test-CdEngineRunning)) {
        if (Read-CdEngineState) { Stop-CdEngine }
        return @()
    }
    $lock = Enter-CdLock -Name 'connect' -TimeoutSec 180
    try {
        $results = foreach ($drive in $drives) {
            Send-CdProgress -OnProgress $OnProgress -Text (Get-CdText 'progress.disconnect' ('{0} ({1}:)' -f $drive.label, $drive.letter))
            try { $result = Dismount-CdDrive -Drive $drive -Force:$Force }
            catch {
                $info = Get-CdErrorInfo $_
                Write-CdLog -Level ERROR -Component 'Disconnect' -Message "Drive '$($drive.id)' failed: $($info.Code) $($info.Detail)"
                $result = New-CdResult -Success $false -Code $info.Code -Message (Get-CdText 'drive.disconnectFailed' $drive.label, "$($drive.letter):") -Detail $info.Detail -Data $drive
            }
            if ($OnResult -and $result.Code -ne 'CD-0002') { & $OnResult $result }
            $result
        }
        # Drives that stay connected (e.g. because of pending uploads) are still wanted.
        $kept = @($results | Where-Object { -not $_.Success -and $_.Data } | ForEach-Object {
                if ($_.Data -is [System.Collections.IDictionary]) { [string]$_.Data.id } else { [string]$_.Data.Drive.id }
            } | Where-Object { $_ })
        Add-CdWantedDrives -DriveIds $kept
        # The engine is only needed while something is mounted.
        if ((Get-CdMountedDrives).Count -eq 0) { Stop-CdEngine }
    }
    finally {
        Exit-CdLock -Mutex $lock
    }
    @($results | Where-Object { $_.Code -ne 'CD-0002' })
}

function Get-CdStatus {
    $engine = Get-CdEngine
    $drives = @()
    if ($engine -and $engine.Healthy) { $drives = @(Get-CdDriveStatusList -IncludeQuota) }
    else {
        $drives = @(foreach ($drive in @((Get-CdSettings).drives)) {
                [pscustomobject]@{
                    PSTypeName     = 'CloudDrives.DriveStatus'
                    Drive          = $drive
                    Account        = Get-CdAccount -Id $drive.account
                    MountPoint     = "$($drive.letter):"
                    Mounted        = $false
                    PendingUploads = 0
                    Quota          = $null
                }
            })
    }
    [pscustomobject]@{
        PSTypeName = 'CloudDrives.Status'
        Engine     = $engine
        Drives     = $drives
    }
}

function Get-CdSetupState {
    $rclone = Find-CdRclone
    [pscustomobject]@{
        Rclone      = $rclone
        WinFsp      = Get-CdWinFsp
        WinFspOk    = Test-CdWinFsp
        HasAccounts = (@((Get-CdSettings).accounts).Count -gt 0)
        Ready       = ($null -ne $rclone) -and (Test-CdWinFsp)
    }
}
