# Watchdog: keeps the drives the user wants connected connected - after standby, a network change or a crash
# of the engine. A scheduled task runs one short cycle every 5 minutes, after waking up and after a network
# connection. A cycle only acts when something is wrong:
#   the engine is gone or does not respond -> restart it and reconnect the drives
#   a wanted drive is not connected         -> connect it
# "Wanted" are the drives the user or the autostart connected since the last Windows start; drives the user
# disconnected stay disconnected. Persistent problems (e.g. an expired sign-in) are retried less and less
# often and reported once instead of on every cycle.

$script:CdWatchdogTaskPath = '\CloudDrives\'
# Minutes to wait after the 1st, 2nd, 3rd and every further failure of a drive.
$script:CdWatchdogBackoffMinutes = @(0, 15, 60, 360)

function Write-CdStateFile {
    # Replaces a small state file in one step, so a reader never sees half of it.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $temp = "$Path.tmp"
    [IO.File]::WriteAllText($temp, $Text, (New-Object Text.UTF8Encoding($false)))
    # [NullString]: PowerShell would pass $null as an empty string, which File.Replace rejects.
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
    else { [IO.File]::Move($temp, $Path) }
}

function Get-CdWantedStateFile {
    Join-Path (Get-CdContext).StateDir 'wanted-drives.json'
}

function Get-CdWantedDrives {
    # Ids of the drives the user wants connected. A list from before the last Windows start does not count:
    # after a restart only the autostart or the user decides what gets connected.
    $file = Get-CdWantedStateFile
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    try { $state = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch { return @() }
    $boot = Get-CdLastBootTime
    if ($boot -and [long]$state.updatedTicks -lt $boot.ToUniversalTime().Ticks) { return @() }
    @($state.drives | Where-Object { $_ } | ForEach-Object { [string]$_ })
}

function Set-CdWantedDrives {
    param([AllowEmptyCollection()][string[]]$DriveIds = @())
    $state = [ordered]@{ drives = @($DriveIds | Where-Object { $_ } | Select-Object -Unique); updatedTicks = (Get-Date).ToUniversalTime().Ticks }
    Write-CdStateFile -Path (Get-CdWantedStateFile) -Text (ConvertTo-Json -InputObject $state)
}

function Add-CdWantedDrives {
    param([AllowEmptyCollection()][string[]]$DriveIds = @())
    if (@($DriveIds).Count -eq 0) { return }
    $lock = Enter-CdLock -Name 'state' -TimeoutSec 15
    try { Set-CdWantedDrives -DriveIds (@(Get-CdWantedDrives) + @($DriveIds)) }
    finally { Exit-CdLock -Mutex $lock }
}

function Remove-CdWantedDrives {
    param([AllowEmptyCollection()][string[]]$DriveIds = @())
    if (@($DriveIds).Count -eq 0) { return }
    $lock = Enter-CdLock -Name 'state' -TimeoutSec 15
    try { Set-CdWantedDrives -DriveIds @(Get-CdWantedDrives | Where-Object { $DriveIds -notcontains $_ }) }
    finally { Exit-CdLock -Mutex $lock }
}

function Get-CdWatchdogStateFile {
    Join-Path (Get-CdContext).StateDir 'watchdog.json'
}

function Read-CdWatchdogState {
    # Failures per drive: @{ <drive id> = @{ failures; code; nextTicks; notified } }; '#engine' (never a drive id)
    # records a failed engine restart.
    $file = Get-CdWatchdogStateFile
    $state = @{}
    if (-not (Test-Path -LiteralPath $file)) { return $state }
    try {
        $data = ConvertTo-CdHashtable ([IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json)
        foreach ($key in @($data.Keys)) { $state[[string]$key] = $data[$key] }
    }
    catch { Write-CdLog -Level DEBUG -Component 'Watchdog' -Message "State unreadable, starting fresh: $($_.Exception.Message)" }
    $state
}

function Save-CdWatchdogState {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    Write-CdStateFile -Path (Get-CdWatchdogStateFile) -Text (ConvertTo-Json -InputObject $State -Depth 4)
}

function Get-CdWatchdogBackoff {
    # Minutes until the next attempt after the given number of failures.
    param([Parameter(Mandatory)][int]$Failures)
    $index = [Math]::Min([Math]::Max($Failures, 1), $script:CdWatchdogBackoffMinutes.Count) - 1
    $script:CdWatchdogBackoffMinutes[$index]
}

function Send-CdWatchdogSummary {
    # Notifies about reconnected drives (setting "all") and about new problems (unless notifications are off).
    param([object[]]$Reconnected = @(), [object[]]$Problems = @())
    $mode = [string](Get-CdSettings).notifications
    if ($mode -eq 'off') { return }
    if ($Problems.Count -gt 0) {
        $lines = foreach ($item in $Problems) { '{0} - {1}' -f $item.Message, (Get-CdText "error.$($item.Code).title") }
        $hint = Get-CdText 'notify.openHint'
        if (@($Problems | Where-Object { $entry = Get-CdErrorEntry -Code ([string]$_.Code); $entry -and $entry.action -eq 'reconnect-account' }).Count -gt 0) { $hint = Get-CdText 'notify.reloginHint' }
        [void](Show-CdNotification -Title (Get-CdText 'watchdog.problemTitle') -Message ((@($lines) -join "`n") + "`n" + $hint) -Kind 'Warning')
    }
    if ($Reconnected.Count -gt 0 -and $mode -eq 'all') {
        $letters = (@($Reconnected | ForEach-Object { "$($_.Data.letter):" }) -join ', ')
        [void](Show-CdNotification -Title 'CloudDrives' -Message (Get-CdText 'watchdog.reconnected' $letters))
    }
}

function Invoke-CdWatchdog {
    # One watchdog cycle. Returns @{ Status = idle|busy|offline|ok|failed; EngineRestarted; Results }.
    $result = [pscustomobject]@{ Status = 'idle'; EngineRestarted = $false; Results = @() }
    # Drives renamed in Explorer: adopt the new names soon, so the menu and the symbol show them too.
    try { [void](Sync-CdDriveLabels) } catch { Write-CdLog -Level DEBUG -Component 'Watchdog' -Message "Explorer names: $($_.Exception.Message)" }
    $wanted = @(Get-CdWantedDrives)
    $drives = @((Get-CdSettings).drives | Where-Object { $wanted -contains $_.id })
    if ($drives.Count -eq 0) { return $result }

    # Never interfere with a connect or disconnect that is running right now; the next cycle comes soon.
    try { $lock = Enter-CdLock -Name 'connect' -TimeoutSec 5 }
    catch { $result.Status = 'busy'; return $result }
    try {
        if (-not (Test-CdInternet)) { $result.Status = 'offline'; return $result }
        $state = Read-CdWatchdogState
        $results = New-Object System.Collections.Generic.List[object]
        $problems = New-Object System.Collections.Generic.List[object]

        # The engine: a busy engine answers late, so it gets a second chance before it is restarted.
        $engine = Get-CdEngine
        if ($engine -and $engine.Alive -and -not $engine.Healthy) {
            Start-Sleep -Seconds 10
            $engine = Get-CdEngine
        }
        if (-not $engine -or -not $engine.Healthy) {
            $reason = 'gone'
            if ($engine -and $engine.Alive) { $reason = 'not responding' }
            Write-CdLog -Level WARN -Component 'Watchdog' -Message "Engine $reason - restarting it."
            try {
                [void](Start-CdEngine)
                $result.EngineRestarted = $true
            }
            catch {
                $info = Get-CdErrorInfo $_
                Write-CdLog -Level ERROR -Component 'Watchdog' -Message "Engine restart failed: $($info.Code) $($info.Detail)"
                $record = $state['#engine']
                if (-not $record -or $record.code -ne $info.Code) {
                    $problems.Add((New-CdResult -Success $false -Code $info.Code -Message (Get-CdText 'watchdog.engineFailed')))
                }
                $state['#engine'] = @{ failures = 1; code = $info.Code; nextTicks = 0; notified = $true }
                Save-CdWatchdogState -State $state
                Send-CdWatchdogSummary -Problems $problems.ToArray()
                $result.Status = 'failed'
                return $result
            }
        }
        $state.Remove('#engine')

        $mounted = Get-CdMountedDrives
        $now = (Get-Date).ToUniversalTime()
        $reconnected = New-Object System.Collections.Generic.List[object]
        foreach ($drive in $drives) {
            $mountPoint = "$($drive.letter):".ToUpperInvariant()
            if ($mounted.ContainsKey($mountPoint)) {
                $state.Remove([string]$drive.id)
                continue
            }
            # The user may have disconnected the drive while this cycle was running.
            if (@(Get-CdWantedDrives) -notcontains $drive.id) { continue }
            $record = $state[[string]$drive.id]
            if ($record -and [long]$record.nextTicks -gt $now.Ticks) { continue }
            try {
                $mount = Mount-CdDrive -Drive $drive
                $results.Add($mount)
                $reconnected.Add($mount)
                $state.Remove([string]$drive.id)
                Write-CdLog -Component 'Watchdog' -Message "Reconnected '$($drive.id)' as $mountPoint."
            }
            catch {
                $info = Get-CdErrorInfo $_
                $failures = 1
                if ($record) { $failures = [int]$record.failures + 1 }
                $failed = New-CdResult -Success $false -Code $info.Code -Message (Get-CdText 'drive.connectFailed' $drive.label, $mountPoint) -Detail $info.Detail -Data $drive
                $results.Add($failed)
                # Report each problem once; a different problem of the same drive is reported again.
                if (-not $record -or $record.code -ne $info.Code) { $problems.Add($failed) }
                $state[[string]$drive.id] = @{ failures = $failures; code = $info.Code; nextTicks = $now.AddMinutes((Get-CdWatchdogBackoff -Failures $failures)).Ticks; notified = $true }
                Write-CdLog -Level WARN -Component 'Watchdog' -Message "Reconnect of '$($drive.id)' failed ($($info.Code)), attempt $failures."
            }
        }
        Save-CdWatchdogState -State $state
        Send-CdWatchdogSummary -Reconnected $reconnected.ToArray() -Problems $problems.ToArray()
        $result.Results = $results.ToArray()
        $result.Status = 'ok'
        if (@($results | Where-Object { -not $_.Success }).Count -gt 0) { $result.Status = 'failed' }
        $result
    }
    finally {
        Exit-CdLock -Mutex $lock
    }
}

function Get-CdWatchdogName {
    # No square brackets: the Task Scheduler cmdlets treat them as wildcards.
    $ctx = Get-CdContext
    if ($ctx.IsDefaultHome) { return 'CloudDrives Watchdog' }
    "CloudDrives Watchdog - $($ctx.HomeId)"
}

function Get-CdWatchdogTask {
    $name = Get-CdWatchdogName
    Get-ScheduledTask -TaskPath $script:CdWatchdogTaskPath -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -eq $name } | Select-Object -First 1
}

function Get-CdWatchdog {
    $task = Get-CdWatchdogTask
    if (-not $task) { return [pscustomobject]@{ Enabled = $false; Detail = $null } }
    [pscustomobject]@{ Enabled = ($task.State -ne 'Disabled'); Detail = "$($script:CdWatchdogTaskPath)$($task.TaskName)" }
}

function Get-CdWatchdogTaskXml {
    # Task definition: every 5 minutes, after waking up (Power-Troubleshooter event 1) and after a network
    # connection (NetworkProfile event 10000); hidden, in the user's session, also on battery, never twice.
    param([string]$SrcRoot)
    $command = Get-CdAutostartCommand -SrcRoot $SrcRoot -Command @('watchdog', '--silent')
    $escape = { param([string]$Text) [System.Security.SecurityElement]::Escape($Text) }
    $resume = "<QueryList><Query Id='0' Path='System'><Select Path='System'>*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]</Select></Query></QueryList>"
    $network = "<QueryList><Query Id='0' Path='Microsoft-Windows-NetworkProfile/Operational'><Select Path='Microsoft-Windows-NetworkProfile/Operational'>*[System[Provider[@Name='Microsoft-Windows-NetworkProfile'] and EventID=10000]]</Select></Query></QueryList>"
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$(& $escape (Get-CdText 'watchdog.taskDescription'))</Description>
  </RegistrationInfo>
  <Triggers>
    <TimeTrigger>
      <Repetition>
        <Interval>PT5M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>$((Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'))</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>$(& $escape $resume)</Subscription>
      <Delay>PT30S</Delay>
    </EventTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>$(& $escape $network)</Subscription>
      <Delay>PT15S</Delay>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$user</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT15M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(& $escape $command.Execute)</Command>
      <Arguments>$(& $escape $command.Arguments)</Arguments>
      <WorkingDirectory>$(& $escape $command.WorkingDirectory)</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
}

function Enable-CdWatchdog {
    # -SrcRoot lets the installer point the watchdog at the freshly installed copy.
    param([string]$SrcRoot)
    try {
        [void](Register-ScheduledTask -TaskPath $script:CdWatchdogTaskPath -TaskName (Get-CdWatchdogName) -Xml (Get-CdWatchdogTaskXml -SrcRoot $SrcRoot) -Force -ErrorAction Stop)
    }
    catch { throw (New-CdException -Code 'CD-9004' -Detail $_.Exception.Message -InnerException $_.Exception) }
    Write-CdLog -Component 'Watchdog' -Message 'Watchdog task registered.'
    New-CdResult -Message (Get-CdText 'watchdog.enabled') -Data (Get-CdWatchdog)
}

function Disable-CdWatchdog {
    $task = Get-CdWatchdogTask
    if ($task) { $task | Unregister-ScheduledTask -Confirm:$false }
    $file = Get-CdWatchdogStateFile
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    Write-CdLog -Component 'Watchdog' -Message 'Watchdog removed.'
    New-CdResult -Message (Get-CdText 'watchdog.disabled')
}
