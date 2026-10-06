# Command-line front end. "CloudDrives.bat" without arguments opens the menu; otherwise:
#   connect|verbinden [all|<drive>...] [--silent]    disconnect|trennen [all|<drive>...] [--force]
#   status [--json]   add-account   remove-account   relogin|neu-anmelden [<account>]
#   change-client|client-id [<account>]   doctor|diagnose [--fix] [--bundle [--out=<zip>]] [--json]
#   watchdog [on|off|status]   tray [on|off|status]   autostart   install   uninstall   setup   version   help
#   update [--check] [--background] [--silent]   about|info
# "--window" (set when CloudDrives opens a window of its own): the window shows the CloudDrives symbol in the taskbar.

$script:CdCommandAliases = @{
    'verbinden'        = 'connect'
    'trennen'          = 'disconnect'
    'konto-hinzufuegen' = 'add-account'
    'konto-entfernen'  = 'remove-account'
    'neu-anmelden'     = 'relogin'
    'client-id'        = 'change-client'
    'diagnose'         = 'doctor'
    'einrichten'       = 'setup'
    'installieren'     = 'install'
    'aktualisieren'    = 'update'
    'deinstallieren'   = 'uninstall'
    'hilfe'            = 'help'
    'info'             = 'about'
    '-?'               = 'help'
    '/?'               = 'help'
}

function ConvertFrom-CdCliArguments {
    param([AllowEmptyCollection()][string[]]$Arguments = @())
    $command = $null
    $targets = New-Object System.Collections.Generic.List[string]
    $flags = @{}
    foreach ($argument in @($Arguments)) {
        if ([string]::IsNullOrWhiteSpace($argument)) { continue }
        if ($script:CdCommandAliases.ContainsKey($argument.ToLowerInvariant()) -and -not $command) {
            $command = $script:CdCommandAliases[$argument.ToLowerInvariant()]
            continue
        }
        if ($argument -match '^--?([A-Za-z][A-Za-z0-9-]*)(?:=(.*))?$') {
            $value = $true
            if ($Matches[2]) { $value = $Matches[2] }
            $flags[$Matches[1].ToLowerInvariant()] = $value
            continue
        }
        if (-not $command) { $command = $argument.ToLowerInvariant() }
        else { $targets.Add($argument) }
    }
    if (-not $command) { $command = 'menu' }
    if ($flags.ContainsKey('help') -or $flags.ContainsKey('h')) { $command = 'help' }
    [pscustomobject]@{ Command = $command; Targets = $targets.ToArray(); Flags = $flags }
}

function Show-CdHelp {
    Write-CdHeader
    Write-CdInfo -Text (Get-CdText 'help.text')
}

function Get-CdLastInt {
    # Picks the exit code from a command's output, ignoring anything else that was emitted.
    param([AllowNull()][object[]]$Values, [int]$Default = 0)
    $numbers = @($Values | Where-Object { $_ -is [int] })
    if ($numbers.Count -gt 0) { return $numbers[-1] }
    $Default
}

function Invoke-CdCommandLineConnect {
    param([pscustomobject]$Parsed)
    $silent = [bool]$Parsed.Flags['silent']
    $selection = $Parsed.Targets
    $results = @(Invoke-CdConnect -Selection $selection -Silent:$silent -AllowInstall -OnResult {
            param($Result)
            if (-not $silent) { Write-CdResult -Result $Result }
        })
    $failed = @($results | Where-Object { -not $_.Success })
    foreach ($item in $failed) { Write-CdLog -Level WARN -Component 'Cli' -Message "connect: $($item.Code) $($item.Message)" }
    if ($silent) { Send-CdConnectSummary -Results $results }
    if ($silent) { [void](Invoke-CdBackgroundUpdateCheck) }
    if ($failed.Count -eq 0) { return 0 }
    if ($failed.Count -lt $results.Count) { return 1 }
    2
}

function Invoke-CdCommandLineDisconnect {
    param([pscustomobject]$Parsed)
    $force = [bool]$Parsed.Flags['force']
    $results = @(Invoke-CdDisconnect -Selection $Parsed.Targets -Force:$force -OnResult { param($Result) Write-CdResult -Result $Result })
    if (@($results | Where-Object { -not $_.Success }).Count -gt 0) { return 1 }
    0
}

function Invoke-CdCommandLineInstall {
    param([pscustomobject]$Parsed)
    $result = Install-CdApplication -Desktop:([bool]$Parsed.Flags['desktop']) -NoShortcuts:([bool]$Parsed.Flags['no-shortcuts'])
    Write-CdResult -Result $result
    0
}

function Invoke-CdCommandLineUpdate {
    # --background: the regular look for the autostart and the symbol (see Invoke-CdBackgroundUpdateCheck).
    # --silent: the one click on the symbol in the notification area; the outcome arrives as a notification.
    param([pscustomobject]$Parsed)
    if ($Parsed.Flags['background']) {
        [void](Invoke-CdBackgroundUpdateCheck)
        return 0
    }
    if ($Parsed.Flags['silent'] -and -not $Parsed.Flags['check']) {
        try { $result = Install-CdUpdate }
        catch {
            [void](Show-CdNotification -Title (Get-CdText 'update.failedTitle') -Message (Get-CdErrorInfo $_).Title -Kind 'Warning')
            throw
        }
        [void](Show-CdNotification -Title 'CloudDrives' -Message $result.Message)
        if ($result.Success) { return 0 }
        return 1
    }
    if ($Parsed.Flags['check']) {
        $state = Get-CdUpdateState
        if (-not $state.Latest) { Write-CdInfo -Text (Get-CdText 'error.CD-8004.title') }
        elseif ($state.Available) { Write-CdInfo -Text (Get-CdText 'update.available' ([string]$state.Latest), ([string]$state.Current)) }
        else { Write-CdInfo -Text (Get-CdText 'update.upToDate' ([string]$state.Current)) }
        return 0
    }
    $result = Install-CdUpdate
    Write-CdResult -Result $result
    if ($result.Success) { return 0 }
    1
}

function Invoke-CdCommandLineUninstall {
    param([pscustomobject]$Parsed)
    $removeData = [bool]$Parsed.Flags['remove-data']
    if (-not $Parsed.Flags['yes']) {
        Write-CdInfo -Text (Get-CdText 'uninstall.explain') -Color Yellow
        if (-not (Read-CdYesNo -Prompt (Get-CdText 'uninstall.confirm') -Default $false)) { return 0 }
        if (-not $removeData) { $removeData = Read-CdYesNo -Prompt (Get-CdText 'uninstall.removeData') -Default $false }
    }
    Write-CdResult -Result (Uninstall-CdApplication -RemoveData:$removeData)
    Write-CdInfo -Text (Get-CdText 'uninstall.winfspNote') -Color DarkGray
    0
}

function Invoke-CdCommandLineAutostart {
    param([pscustomobject]$Parsed)
    $mode = 'status'
    if ($Parsed.Targets.Count -gt 0) { $mode = $Parsed.Targets[0].ToLowerInvariant() }
    switch ($mode) {
        { @('on', 'an', 'ein') -contains $_ } { Write-CdResult -Result (Enable-CdAutostart); return 0 }
        { @('off', 'aus') -contains $_ } { Write-CdResult -Result (Disable-CdAutostart); return 0 }
        default {
            $state = Get-CdAutostart
            if ($state.Enabled) { Write-CdInfo -Text (Get-CdText 'autostart.statusOn' $state.Detail) }
            else { Write-CdInfo -Text (Get-CdText 'autostart.statusOff') }
            return 0
        }
    }
}

function Resolve-CdAccountArgument {
    # Finds an account by id, label or the letter of one of its drives ("gpro", "Google Pro", "K").
    param([Parameter(Mandatory)][string]$Value)
    $settings = Get-CdSettings
    $match = @($settings.accounts | Where-Object { $_.id -eq $Value -or $_.label -eq $Value }) | Select-Object -First 1
    if (-not $match) {
        $drive = @($settings.drives | Where-Object { $_.letter -eq $Value.TrimEnd(':') }) | Select-Object -First 1
        if ($drive) { $match = Get-CdAccount -Id $drive.account }
    }
    if (-not $match) { throw (New-CdException -Code 'CD-2006' -Detail "unknown account '$Value'") }
    $match
}

function Invoke-CdCommandLineRelogin {
    param([pscustomobject]$Parsed, [switch]$ChangeClient)
    $account = $null
    if ($Parsed.Targets.Count -gt 0) { $account = Resolve-CdAccountArgument -Value $Parsed.Targets[0] }
    $done = @(Start-CdReloginWizard -Account $account -ChangeClient:$ChangeClient) | Where-Object { $_ -is [bool] } | Select-Object -Last 1
    if ($done) { return 0 }
    1
}

function Invoke-CdCommandLineDoctor {
    # Exit code: 0 = all fine, 1 = warnings, 2 = problems.
    param([pscustomobject]$Parsed)
    $json = [bool]$Parsed.Flags['json']
    $checks = @(Invoke-CdDoctor)
    if ($Parsed.Flags['fix']) {
        foreach ($check in @((Get-CdDoctorSummary -Checks $checks).Fixable | Where-Object { -not (Test-CdFixInteractive -Fix $_.Fix) })) {
            try { foreach ($result in @(Invoke-CdDoctorFix -Check $check)) { if ($result -and -not $json) { Write-CdResult -Result $result } } }
            catch { if (-not $json) { Write-CdErrorInfo -Info (Get-CdErrorInfo $_) } }
        }
        $checks = @(Invoke-CdDoctor)
    }
    if ($json) { [Console]::Out.WriteLine((ConvertTo-CdJsonText -InputObject @($checks | Select-Object Area, Name, Status, Message, Code, Fix, Target) -Depth 4)) }
    else {
        Write-CdHeader -Subtitle (Get-CdText 'doctor.title')
        Show-CdDoctorReport -Checks $checks
    }
    if ($Parsed.Flags['bundle']) {
        $out = $null
        if ($Parsed.Flags['out'] -is [string]) { $out = $Parsed.Flags['out'] }
        $result = New-CdSupportBundle -Checks $checks -Path $out
        if ($json) { [Console]::Error.WriteLine($result.Data.Path) } else { Write-CdResult -Result $result }
    }
    # Started from the tray in its own window: keep the window open until the result has been read.
    if ($Parsed.Flags['pause'] -and -not $json) { Wait-CdKeyPress }
    (Get-CdDoctorSummary -Checks $checks).ExitCode
}

function Invoke-CdCommandLineWatchdog {
    # Without an argument one watchdog cycle runs (that is what the scheduled task does every 5 minutes).
    param([pscustomobject]$Parsed)
    $mode = 'run'
    if ($Parsed.Targets.Count -gt 0) { $mode = $Parsed.Targets[0].ToLowerInvariant() }
    switch ($mode) {
        { @('on', 'an', 'ein') -contains $_ } { Write-CdResult -Result (Enable-CdWatchdog); return 0 }
        { @('off', 'aus') -contains $_ } { Write-CdResult -Result (Disable-CdWatchdog); return 0 }
        'status' {
            $state = Get-CdWatchdog
            if ($state.Enabled) { Write-CdInfo -Text (Get-CdText 'watchdog.statusOn' $state.Detail) }
            else { Write-CdInfo -Text (Get-CdText 'watchdog.statusOff') }
            return 0
        }
        default {
            $cycle = Invoke-CdWatchdog
            if ($cycle.Status -ne 'idle') { Write-CdLog -Component 'Watchdog' -Message "Cycle: $($cycle.Status) (engine restarted: $($cycle.EngineRestarted), drives: $(@($cycle.Results).Count))." }
            if (-not $Parsed.Flags['silent']) {
                foreach ($item in @($cycle.Results)) { Write-CdResult -Result $item }
                Write-CdInfo -Text (Get-CdText "watchdog.cycle.$($cycle.Status)")
            }
            if ($cycle.Status -eq 'failed') { return 1 }
            return 0
        }
    }
}

function Invoke-CdCommandLineTray {
    # Without an argument the symbol is shown (until it is hidden); that is what the sign-in task runs.
    param([pscustomobject]$Parsed)
    $mode = 'show'
    if ($Parsed.Targets.Count -gt 0) { $mode = $Parsed.Targets[0].ToLowerInvariant() }
    switch ($mode) {
        { @('on', 'an', 'ein') -contains $_ } { Write-CdResult -Result (Enable-CdTray); return 0 }
        { @('off', 'aus') -contains $_ } { Write-CdResult -Result (Disable-CdTray); return 0 }
        'status' {
            $state = Get-CdTray
            if ($state.Enabled) { Write-CdInfo -Text (Get-CdText 'tray.statusOn' (Get-CdText "tray.running.$($state.Running)")) }
            else { Write-CdInfo -Text (Get-CdText 'tray.statusOff') }
            return 0
        }
        default { return (Start-CdTray) }
    }
}

function Invoke-CdCommandLineStatus {
    param([pscustomobject]$Parsed)
    $status = Get-CdStatus
    if ($Parsed.Flags['json']) {
        $export = [ordered]@{
            engineRunning = [bool]($status.Engine -and $status.Engine.Healthy)
            drives        = @($status.Drives | ForEach-Object {
                    [ordered]@{
                        id             = $_.Drive.id
                        label          = $_.Drive.label
                        letter         = $_.Drive.letter
                        account        = $_.Drive.account
                        encrypted      = [bool]$_.Drive.encrypted
                        mounted        = $_.Mounted
                        pendingUploads = $_.PendingUploads
                        usedBytes      = $(if ($_.Quota) { $_.Quota.used } else { $null })
                        totalBytes     = $(if ($_.Quota) { $_.Quota.total } else { $null })
                    }
                })
        }
        [Console]::Out.WriteLine((ConvertTo-CdJsonText -InputObject $export -Depth 5))
        return 0
    }
    Write-CdHeader
    Write-CdStatusTable -StatusList $status.Drives
    0
}

function Invoke-CdCli {
    # Runs one command line of CloudDrives.bat and returns its exit code: prepares the data folder, language
    # and log, opens the menu or runs the command, and turns an error into its explanation and exit code 2.
    param([AllowEmptyCollection()][string[]]$Arguments = @())
    $parsed = ConvertFrom-CdCliArguments -Arguments $Arguments
    $silent = [bool]$parsed.Flags['silent']
    $homePath = $null
    if ($parsed.Flags['home'] -is [string]) { $homePath = $parsed.Flags['home'] }
    [void](Initialize-CdContext -HomePath $homePath -Silent:$silent)
    $exitCode = 0
    try {
        Initialize-CdHome
        $settingsError = $null
        $settings = $null
        try { $settings = Get-CdSettings } catch { $settingsError = $_ }
        $language = 'auto'
        if ($settings -and $settings.language) { $language = [string]$settings.language }
        Initialize-CdI18n -Language $language
        if ($settings -and $settings.logLevel) { Set-CdLogLevel -Level ([string]$settings.logLevel) }
        Remove-CdOldLog
        $ctx = Get-CdContext
        # The watchdog runs every 5 minutes; only what it actually does belongs in the normal log.
        $routineLevel = 'INFO'
        if ($parsed.Command -eq 'watchdog' -and $parsed.Targets.Count -eq 0) { $routineLevel = 'DEBUG' }
        Write-CdLog -Level $routineLevel -Component 'Cli' -Message "CloudDrives $($ctx.Version): '$($parsed.Command)'" -Data @{
            args = $Arguments; ps = $PSVersionTable.PSVersion.ToString(); edition = $PSVersionTable.PSEdition
            os = [Environment]::OSVersion.VersionString; home = $ctx.Home
        }
        if ($settingsError) { throw $settingsError }
        if (-not $silent) {
            Initialize-CdConsole
            if ($parsed.Flags.ContainsKey('window')) { Set-CdConsoleIdentity }
            # Automatic updates wait while a window is open; the symbol in the notification area is none.
            if ($parsed.Command -ne 'tray') { Register-CdWindow }
        }

        switch ($parsed.Command) {
            'menu' { $exitCode = Get-CdLastInt (Start-CdConsoleMenu) }
            'about' {
                Show-CdAbout
                if ($parsed.Flags.ContainsKey('pause')) { Wait-CdKeyPress }
            }
            'connect' { $exitCode = Get-CdLastInt (Invoke-CdCommandLineConnect -Parsed $parsed) }
            'disconnect' { $exitCode = Get-CdLastInt (Invoke-CdCommandLineDisconnect -Parsed $parsed) }
            'status' { $exitCode = Get-CdLastInt (Invoke-CdCommandLineStatus -Parsed $parsed) }
            'autostart' { $exitCode = Get-CdLastInt (Invoke-CdCommandLineAutostart -Parsed $parsed) }
            'install' { $exitCode = Get-CdLastInt (Invoke-CdCommandLineInstall -Parsed $parsed) }
            'update' { $exitCode = Get-CdLastInt (Invoke-CdCommandLineUpdate -Parsed $parsed) }
            'uninstall' { $exitCode = Get-CdLastInt (Invoke-CdCommandLineUninstall -Parsed $parsed) }
            'add-account' { $null = Start-CdAddAccountWizard }
            'remove-account' { $null = Start-CdRemoveAccountWizard }
            'relogin' { $exitCode = Get-CdLastInt (Invoke-CdCommandLineRelogin -Parsed $parsed) }
            'change-client' { $exitCode = Get-CdLastInt (Invoke-CdCommandLineRelogin -Parsed $parsed -ChangeClient) }
            'doctor' { $exitCode = Get-CdLastInt (Invoke-CdCommandLineDoctor -Parsed $parsed) }
            'watchdog' { $exitCode = Get-CdLastInt (Invoke-CdCommandLineWatchdog -Parsed $parsed) }
            'tray' { $exitCode = Get-CdLastInt (Invoke-CdCommandLineTray -Parsed $parsed) }
            'setup' {
                $ready = @(Start-CdSetupWizard) | Where-Object { $_ -is [bool] } | Select-Object -Last 1
                if (-not $ready) { $exitCode = 2 }
            }
            'version' { [Console]::Out.WriteLine((Get-CdContext).Version) }
            'help' { Show-CdHelp }
            default {
                Write-CdInfo -Text (Get-CdText 'cli.unknownCommand' $parsed.Command) -Color Yellow
                Show-CdHelp
                $exitCode = 3
            }
        }
    }
    catch {
        $info = Get-CdErrorInfo $_
        Write-CdLog -Level ERROR -Component 'Cli' -Message "$($info.Code): $($info.Detail)" -Data @{ at = $_.ScriptStackTrace }
        if (-not $silent) {
            Write-CdErrorInfo -Info $info
            if ($parsed.Command -eq 'menu') { Wait-CdKeyPress }
        }
        $exitCode = 2
    }
    $finishLevel = 'INFO'
    if ($routineLevel -eq 'DEBUG' -and $exitCode -eq 0) { $finishLevel = 'DEBUG' }
    Write-CdLog -Level $finishLevel -Component 'Cli' -Message "Finished with exit code $exitCode."
    [int]$exitCode
}
