# Running the diagnosis: all checks (Health.ps1) plus those of the background tasks - watchdog, symbol in the
# notification area, autostart -, the summary with its exit code, the automatic fixes and the report. The
# console shows the report as a traffic-light list, the support bundle stores it.

# Fixes that need the user (a sign-in in the browser); everything else can run unattended.
$script:CdInteractiveFixes = @('relogin', 'change-client')

function Get-CdTaskScriptCheck {
    # A background task must run an existing CloudDrives - preferably the installed one. Returns a check for
    # a problem, or $null when the task is fine.
    param([Parameter(Mandatory)][object]$Task, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Fix)
    $arguments = [string]@($Task.Actions)[0].Arguments
    $script = $null
    if ($arguments -match '-File\s+(?:"([^"]+)"|(\S+))') { $script = @($Matches[1], $Matches[2]) | Where-Object { $_ } | Select-Object -First 1 }
    if (-not $script) { return $null }
    if (-not (Test-Path -LiteralPath $script)) {
        return (New-CdCheck -Area 'autostart' -Name $Name -Status 'fail' -Fix $Fix -Message (Get-CdText 'doctor.autostartMissing' $script))
    }
    $preferred = Join-Path (Get-CdPreferredSrcRoot) 'CloudDrives.ps1'
    if (-not [string]::Equals([IO.Path]::GetFullPath($script), [IO.Path]::GetFullPath($preferred), [StringComparison]::OrdinalIgnoreCase)) {
        return (New-CdCheck -Area 'autostart' -Name $Name -Status 'warn' -Fix $Fix -Message (Get-CdText 'doctor.autostartNotInstalled'))
    }
    $null
}

function Get-CdWatchdogChecks {
    $name = Get-CdText 'doctor.watchdog'
    if (-not (Get-CdWatchdog).Enabled) {
        # Without the watchdog a crash or standby leaves the drives disconnected until the next sign-in.
        if ((Get-CdAutostart).Enabled) { return (New-CdCheck -Area 'autostart' -Name $name -Status 'warn' -Fix 'enable-watchdog' -Message (Get-CdText 'doctor.watchdogOff')) }
        return (New-CdCheck -Area 'autostart' -Name $name -Status 'info' -Message (Get-CdText 'doctor.watchdogOffInfo'))
    }
    $problem = Get-CdTaskScriptCheck -Task (Get-CdWatchdogTask) -Name $name -Fix 'enable-watchdog'
    if ($problem) { return $problem }
    $state = Read-CdWatchdogState
    $waiting = foreach ($key in @($state.Keys)) {
        $title = Get-CdText "error.$($state[$key].code).title"
        $drive = Get-CdDrive -Id $key
        if ($drive) { '{0} {1}' -f "$($drive.letter):", $title }
        elseif ($key -eq '#engine') { $title }
    }
    if (@($waiting).Count -gt 0) { return (New-CdCheck -Area 'autostart' -Name $name -Status 'warn' -Message (Get-CdText 'doctor.watchdogWaiting' (@($waiting) -join '; '))) }
    New-CdCheck -Area 'autostart' -Name $name -Message (Get-CdText 'doctor.watchdogOk')
}

function Get-CdTrayChecks {
    $name = Get-CdText 'doctor.tray'
    $tray = Get-CdTray
    if (-not $tray.Enabled) { return (New-CdCheck -Area 'autostart' -Name $name -Status 'info' -Message (Get-CdText 'doctor.trayOff')) }
    $problem = Get-CdTaskScriptCheck -Task (Get-CdTrayTask) -Name $name -Fix 'enable-tray'
    if ($problem) { return $problem }
    if (-not $tray.Running) { return (New-CdCheck -Area 'autostart' -Name $name -Status 'warn' -Fix 'start-tray' -Message (Get-CdText 'doctor.trayNotRunning')) }
    New-CdCheck -Area 'autostart' -Name $name -Message (Get-CdText 'doctor.trayOk')
}

function Get-CdAutostartChecks {
    $name = Get-CdText 'doctor.autostart'
    $state = Get-CdAutostart
    if (-not $state.Enabled) { return (New-CdCheck -Area 'autostart' -Name $name -Status 'info' -Message (Get-CdText 'doctor.autostartOff')) }
    if ($state.Method -ne 'task') { return (New-CdCheck -Area 'autostart' -Name $name -Message (Get-CdText 'doctor.autostartShortcut')) }

    $task = Get-CdAutostartTask
    $problem = Get-CdTaskScriptCheck -Task $task -Name $name -Fix 'enable-autostart'
    if ($problem) { return $problem }
    $info = $null
    try { $info = Get-ScheduledTaskInfo -InputObject $task -ErrorAction Stop } catch { Write-CdLog -Level DEBUG -Component 'Doctor' -Message "Task info: $($_.Exception.Message)" }
    # 267011 = the task has not run yet, 267009 = it is running right now.
    if (-not $info -or $info.LastTaskResult -eq 267011) { return (New-CdCheck -Area 'autostart' -Name $name -Message (Get-CdText 'doctor.autostartNeverRun')) }
    if ($info.LastTaskResult -ne 0 -and $info.LastTaskResult -ne 267009) {
        return (New-CdCheck -Area 'autostart' -Name $name -Status 'warn' -Message (Get-CdText 'doctor.autostartFailed' $info.LastRunTime.ToString('g'), ('0x{0:X}' -f [int64]$info.LastTaskResult)))
    }
    New-CdCheck -Area 'autostart' -Name $name -Message (Get-CdText 'doctor.autostartLastRun' $info.LastRunTime.ToString('g'))
}

function Invoke-CdDoctor {
    # Runs all checks; a failing area is reported and the others still run. -OnArea receives each area name
    # before it is checked (for a progress display).
    param([scriptblock]$OnArea)
    # A distinctive name: callbacks see this function's variables (dynamic scoping) and must not hit them.
    $doctorAreaChecks = [ordered]@{
        system     = { Get-CdSystemChecks }
        components = { Get-CdComponentChecks }
        settings   = { Get-CdSettingsChecks }
        network    = { Get-CdNetworkChecks }
        updates    = { Get-CdUpdateChecks }
        engine     = { Get-CdEngineChecks }
        accounts   = { Get-CdAccountChecks }
        drives     = { Get-CdDriveChecks }
        logs       = { Get-CdLogChecks }
        autostart  = { Get-CdAutostartChecks; Get-CdWatchdogChecks; Get-CdTrayChecks }
    }
    $checks = New-Object System.Collections.Generic.List[object]
    $engineWasRunning = Test-CdEngineRunning
    foreach ($area in $doctorAreaChecks.Keys) {
        if ($OnArea) { & $OnArea $area }
        try {
            foreach ($check in @(& $doctorAreaChecks[$area])) { if ($check) { $checks.Add($check) } }
        }
        catch {
            $info = Get-CdErrorInfo $_
            Write-CdLog -Level ERROR -Component 'Doctor' -Message "Check '$area' failed: $($info.Code) $($info.Detail)"
            $checks.Add((New-CdCheck -Area $area -Name (Get-CdText "doctor.area.$area") -Status 'fail' -Code $info.Code -Message $info.Title))
        }
    }
    # The account checks may have started the engine; leave things as they were.
    if (-not $engineWasRunning -and (Test-CdEngineRunning) -and (Get-CdMountedDrives).Count -eq 0) {
        try { Stop-CdEngine } catch { Write-CdLog -Level DEBUG -Component 'Doctor' -Message "Engine stop: $($_.Exception.Message)" }
    }
    $summary = Get-CdDoctorSummary -Checks $checks.ToArray()
    Write-CdLog -Component 'Doctor' -Message "Diagnosis: $($summary.Fail) problem(s), $($summary.Warn) warning(s)."
    $checks.ToArray()
}

function Get-CdDoctorSummary {
    param([AllowEmptyCollection()][object[]]$Checks = @())
    $fail = @($Checks | Where-Object { $_.Status -eq 'fail' }).Count
    $warn = @($Checks | Where-Object { $_.Status -eq 'warn' }).Count
    $exitCode = 0
    if ($fail -gt 0) { $exitCode = 2 }
    elseif ($warn -gt 0) { $exitCode = 1 }
    [pscustomobject]@{
        Fail     = $fail
        Warn     = $warn
        Fixable  = @($Checks | Where-Object { $_.Fix -and @('warn', 'fail') -contains $_.Status })
        ExitCode = $exitCode
    }
}

function Test-CdFixInteractive {
    # Fixes that need the user in the browser (sign-in) are carried out by the UI.
    param([AllowEmptyString()][string]$Fix)
    $script:CdInteractiveFixes -contains $Fix
}

function Invoke-CdDoctorFix {
    # Repairs one problem found by the diagnosis. Returns a result (or several, for reconnected drives).
    param([Parameter(Mandatory)][object]$Check)
    switch ($Check.Fix) {
        'install-rclone' {
            [void](Install-CdRclone)
            return (New-CdResult -Message (Get-CdText 'doctor.fixed.rclone'))
        }
        'install-winfsp' {
            [void](Install-CdWinFsp)
            return (New-CdResult -Message (Get-CdText 'doctor.fixed.winfsp'))
        }
        'restart-engine' {
            if (Read-CdEngineState) { Stop-CdEngine }
            [void](Start-CdEngine)
            $results = @(New-CdResult -Message (Get-CdText 'doctor.fixed.engine'))
            return ($results + @(Invoke-CdConnect))
        }
        'connect' { return @(Invoke-CdConnect -Selection @($Check.Target)) }
        'labels' {
            $drive = Get-CdDrive -Id $Check.Target
            if (-not $drive) { throw (New-CdException -Code 'CD-2006' -Detail "unknown drive '$($Check.Target)'") }
            Set-CdDriveLabel -Drive $drive
            return (New-CdResult -Message (Get-CdText 'doctor.fixed.labels' "$($drive.letter):"))
        }
        'protect-home' {
            if (-not (Protect-CdDirectory -Path (Get-CdContext).Home)) { throw (New-CdException -Code 'CD-9001' -Detail 'permissions could not be restricted') }
            return (New-CdResult -Message (Get-CdText 'doctor.fixed.home'))
        }
        'enable-autostart' { return (Enable-CdAutostart -SrcRoot (Get-CdPreferredSrcRoot)) }
        'enable-watchdog' { return (Enable-CdWatchdog -SrcRoot (Get-CdPreferredSrcRoot)) }
        'enable-tray' { return (Enable-CdTray -SrcRoot (Get-CdPreferredSrcRoot)) }
        'start-tray' {
            [void](Start-CdTrayProcess -SrcRoot (Get-CdPreferredSrcRoot))
            return (New-CdResult -Message (Get-CdText 'doctor.fixed.tray'))
        }
        default { throw (New-CdException -Code 'CD-9001' -Detail "no automatic fix '$($Check.Fix)'") }
    }
}

function Format-CdDoctorReport {
    # Plain-text report (support bundle, logs): one line per check, grouped by area.
    param([AllowEmptyCollection()][object[]]$Checks = @())
    $lines = New-Object System.Collections.Generic.List[string]
    $area = $null
    foreach ($check in $Checks) {
        if ($check.Area -ne $area) {
            $area = $check.Area
            if ($lines.Count -gt 0) { $lines.Add('') }
            $lines.Add((Get-CdText "doctor.area.$area"))
        }
        $line = '  [{0}] {1}: {2}' -f (Get-CdText "doctor.status.$($check.Status)"), $check.Name, $check.Message
        if ($check.Code) { $line += " ($($check.Code))" }
        $lines.Add($line)
    }
    $summary = Get-CdDoctorSummary -Checks $Checks
    $lines.Add('')
    if ($summary.Fail -eq 0 -and $summary.Warn -eq 0) { $lines.Add((Get-CdText 'doctor.summaryOk')) }
    else { $lines.Add((Get-CdText 'doctor.summary' $summary.Fail, $summary.Warn)) }
    $lines -join "`r`n"
}
