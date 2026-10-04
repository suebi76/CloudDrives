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
        [scriptblock]$OnResult
    )
    $drives = Select-CdDrives -Selection $Selection -AutoConnectOnly:(-not $Selection)
    if ($drives.Count -eq 0) { return @() }

    $waitSec = 15
    if ($Silent) { $waitSec = 120 }
    if (-not (Wait-CdNetwork -TimeoutSec $waitSec)) {
        $offline = New-CdResult -Success $false -Code 'CD-5001' -Message (Get-CdText 'error.CD-5001.title')
        if ($OnResult) { & $OnResult $offline }
        return @($offline)
    }

    [void](Start-CdEngine -AllowInstall:$AllowInstall)
    $results = foreach ($drive in $drives) {
        try { $result = Mount-CdDrive -Drive $drive }
        catch {
            $info = Get-CdErrorInfo $_
            Write-CdLog -Level ERROR -Component 'Connect' -Message "Drive '$($drive.id)' failed: $($info.Code) $($info.Detail)"
            $result = New-CdResult -Success $false -Code $info.Code -Message (Get-CdText 'drive.connectFailed' $drive.label, "$($drive.letter):") -Detail $info.Detail -Data $drive
        }
        if ($OnResult) { & $OnResult $result }
        $result
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
        [scriptblock]$OnResult
    )
    if (-not (Test-CdEngineRunning)) {
        if (Read-CdEngineState) { Stop-CdEngine }
        return @()
    }
    $drives = Select-CdDrives -Selection $Selection
    $results = foreach ($drive in $drives) {
        try { $result = Dismount-CdDrive -Drive $drive -Force:$Force }
        catch {
            $info = Get-CdErrorInfo $_
            Write-CdLog -Level ERROR -Component 'Disconnect' -Message "Drive '$($drive.id)' failed: $($info.Code) $($info.Detail)"
            $result = New-CdResult -Success $false -Code $info.Code -Message (Get-CdText 'drive.disconnectFailed' $drive.label, "$($drive.letter):") -Detail $info.Detail -Data $drive
        }
        if ($OnResult -and $result.Code -ne 'CD-0002') { & $OnResult $result }
        $result
    }
    # The engine is only needed while something is mounted.
    if ((Get-CdMountedDrives).Count -eq 0) { Stop-CdEngine }
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
