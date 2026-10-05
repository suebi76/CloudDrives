# Symbol in the notification area: what it shows, that only one runs per user, and its start at Windows
# sign-in (a scheduled task). The symbol itself (Windows Forms) lives in UI\Tray.ps1.

$script:CdTrayTaskPath = '\CloudDrives\'
$script:CdTraySettingsStamp = $null

function Get-CdTrayMutexName {
    "Local\CloudDrives-$((Get-CdContext).HomeId)-tray"
}

function Get-CdTrayExitEvent {
    # Named signal that asks a running symbol to close (switched off, or replaced after an update).
    $created = $false
    New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, "Local\CloudDrives-$((Get-CdContext).HomeId)-tray-exit", [ref]$created)
}

function Test-CdTrayRunning {
    $mutex = $null
    if ([System.Threading.Mutex]::TryOpenExisting((Get-CdTrayMutexName), [ref]$mutex)) {
        $mutex.Dispose()
        return $true
    }
    $false
}

function Get-CdSyncAppPath {
    # CloudDrive-Sync - the separate program that keeps folders on this PC in step with Nextcloud, IServ and other
    # WebDAV servers - when it is installed for this user. The symbol then opens it from its menu.
    # Installed with its setup program, CloudDrive-Sync records its place under "App Paths"; its usual folders
    # follow, the one of the setup program first, then the one of earlier test versions.
    param(
        [string]$LocalAppData = [Environment]::GetFolderPath('LocalApplicationData'),
        [string]$AppPathKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\CloudDrive-Sync.exe'
    )
    $recorded = $null
    $key = Get-Item -LiteralPath $AppPathKey -ErrorAction SilentlyContinue
    if ($key) { $recorded = $key.GetValue('') }
    $candidates = @($recorded, (Join-Path $LocalAppData 'CloudDriveSync\current\CloudDrive-Sync.exe'),
        (Join-Path $LocalAppData 'Programs\CloudDrive-Sync\CloudDrive-Sync.exe'))
    foreach ($file in $candidates) {
        if ($file -and (Test-Path -LiteralPath $file -PathType Leaf)) { return $file }
    }
    $null
}

function Get-CdTrayState {
    # What the symbol shows: Level (ok/warn/error/idle), a short Text, every drive with its state, the accounts whose
    # sign-in has to be renewed and a newer version of CloudDrives found on GitHub (Update).
    # The symbol runs for hours, so settings changed by another CloudDrives window are read again.
    $file = (Get-CdContext).SettingsFile
    $stamp = 0
    if (Test-Path -LiteralPath $file) { $stamp = (Get-Item -LiteralPath $file).LastWriteTimeUtc.Ticks }
    if ($stamp -ne $script:CdTraySettingsStamp) {
        [void](Get-CdSettings -Reload)
        $script:CdTraySettingsStamp = $stamp
    }
    $settings = Get-CdSettings
    $wanted = @(Get-CdWantedDrives)
    $problems = Read-CdWatchdogState
    $mounted = @{}
    if (Test-CdEngineRunning) { $mounted = Get-CdMountedDrives }

    $drives = @(foreach ($drive in @($settings.drives)) {
            $mountPoint = "$($drive.letter):".ToUpperInvariant()
            $code = $null
            if ($problems.ContainsKey([string]$drive.id)) { $code = [string]$problems[[string]$drive.id].code }
            [pscustomobject]@{
                Id        = [string]$drive.id
                Letter    = $mountPoint
                Label     = [string]$drive.label
                Account   = [string]$drive.account
                Connected = $mounted.ContainsKey($mountPoint)
                Wanted    = $wanted -contains $drive.id
                Problem   = $code
            }
        })
    $connected = @($drives | Where-Object { $_.Connected })
    $missing = @($drives | Where-Object { $_.Wanted -and -not $_.Connected })
    $failing = @($drives | Where-Object { $_.Problem -and -not $_.Connected })
    $relogin = @($failing | Where-Object { $entry = Get-CdErrorEntry -Code $_.Problem; $entry -and $entry.action -eq 'reconnect-account' } | ForEach-Object { $_.Account } | Select-Object -Unique)

    $letters = { param($List) (@($List) | ForEach-Object { $_.Letter }) -join ', ' }
    $level = 'idle'
    $text = Get-CdText 'tray.idle'
    if ($problems.ContainsKey('#engine')) {
        $level = 'error'
        $text = Get-CdText 'watchdog.engineFailed'
    }
    elseif ($failing.Count -gt 0) {
        $level = 'error'
        $text = Get-CdText 'tray.problem' $failing[0].Letter, (Get-CdText "error.$($failing[0].Problem).title")
    }
    elseif ($missing.Count -gt 0) {
        $level = 'warn'
        $text = Get-CdText 'tray.reconnecting' (& $letters $missing)
    }
    elseif ($connected.Count -gt 0) {
        $level = 'ok'
        $text = Get-CdText 'tray.connected' (& $letters $connected)
    }
    [pscustomobject]@{
        Level           = $level
        Text            = $text
        Drives          = $drives
        ReloginAccounts = $relogin
        Update          = Get-CdPendingUpdate
    }
}

function Test-CdTrayUpdateCheckDue {
    # Whether the symbol should start the hidden "update --background" now: the regular look on GitHub is due, or a
    # version waits to be installed automatically and no CloudDrives window is open any more.
    if (Test-CdUpdateCheckDue) { return $true }
    (Get-CdSettings).updates -eq 'automatic' -and (Get-CdPendingUpdate) -and -not (Test-CdWindowOpen)
}

function Start-CdTrayProcess {
    # Starts the symbol as a hidden background process. Returns $false when it is already running.
    param([string]$SrcRoot)
    if (Test-CdTrayRunning) { return $false }
    $command = Get-CdAutostartCommand -SrcRoot $SrcRoot -Command @('tray') -Sta
    [void](Start-CdDetachedProcess -FilePath $command.Execute -RawArguments $command.Arguments -WorkingDirectory $command.WorkingDirectory)
    $true
}

function Stop-CdTray {
    # Asks a running symbol to close and waits a few seconds for it.
    if (-not (Test-CdTrayRunning)) { return }
    $signal = Get-CdTrayExitEvent
    try {
        [void]$signal.Set()
        $deadline = (Get-Date).AddSeconds(10)
        while ((Test-CdTrayRunning) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
    }
    finally {
        [void]$signal.Reset()
        $signal.Dispose()
    }
}

function Get-CdTrayTaskName {
    # No square brackets: the Task Scheduler cmdlets treat them as wildcards.
    $ctx = Get-CdContext
    if ($ctx.IsDefaultHome) { return 'CloudDrives Tray' }
    "CloudDrives Tray - $($ctx.HomeId)"
}

function Get-CdTrayTask {
    $name = Get-CdTrayTaskName
    Get-ScheduledTask -TaskPath $script:CdTrayTaskPath -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -eq $name } | Select-Object -First 1
}

function Get-CdTray {
    $task = Get-CdTrayTask
    [pscustomobject]@{
        Enabled = [bool]($task -and $task.State -ne 'Disabled')
        Running = Test-CdTrayRunning
    }
}

function Enable-CdTray {
    # Shows the symbol at every Windows sign-in (and right now, unless -NoStart).
    param([string]$SrcRoot, [switch]$NoStart)
    $command = Get-CdAutostartCommand -SrcRoot $SrcRoot -Command @('tray') -Sta
    $user = "$env:USERDOMAIN\$env:USERNAME"
    try {
        $action = New-ScheduledTaskAction -Execute $command.Execute -Argument $command.Arguments -WorkingDirectory $command.WorkingDirectory
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $trigger.Delay = 'PT10S'
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
        [void](Register-ScheduledTask -TaskPath $script:CdTrayTaskPath -TaskName (Get-CdTrayTaskName) -Action $action -Trigger $trigger `
                -Principal $principal -Settings $settings -Description (Get-CdText 'tray.taskDescription') -Force -ErrorAction Stop)
    }
    catch { throw (New-CdException -Code 'CD-9004' -Detail $_.Exception.Message -InnerException $_.Exception) }
    Write-CdLog -Component 'Tray' -Message 'Tray task registered.'
    if (-not $NoStart) { [void](Start-CdTrayProcess -SrcRoot $SrcRoot) }
    New-CdResult -Message (Get-CdText 'tray.enabled') -Data (Get-CdTray)
}

function Disable-CdTray {
    $task = Get-CdTrayTask
    if ($task) { $task | Unregister-ScheduledTask -Confirm:$false }
    Stop-CdTray
    Write-CdLog -Component 'Tray' -Message 'Tray removed.'
    New-CdResult -Message (Get-CdText 'tray.disabled')
}
