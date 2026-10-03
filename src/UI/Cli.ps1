# Command-line front end. "CloudDrives.bat" without arguments opens the menu; otherwise:
#   connect|verbinden [all|<drive>...] [--silent]    disconnect|trennen [all|<drive>...] [--force]
#   status [--json]   add-account   remove-account   setup   version   help

$script:CdCommandAliases = @{
    'verbinden'        = 'connect'
    'trennen'          = 'disconnect'
    'konto-hinzufuegen' = 'add-account'
    'konto-entfernen'  = 'remove-account'
    'einrichten'       = 'setup'
    'hilfe'            = 'help'
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
    $results = @(Invoke-CdConnect -Selection $selection -Silent:$silent -OnResult {
            param($Result)
            if (-not $silent) { Write-CdResult -Result $Result }
        })
    $failed = @($results | Where-Object { -not $_.Success })
    foreach ($item in $failed) { Write-CdLog -Level WARN -Component 'Cli' -Message "connect: $($item.Code) $($item.Message)" }
    if ($silent) { Send-CdConnectSummary -Results $results }
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
        [Console]::Out.WriteLine((ConvertTo-Json -InputObject $export -Depth 5))
        return 0
    }
    Write-CdHeader
    Write-CdStatusTable -StatusList $status.Drives
    0
}

function Invoke-CdCli {
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
        Write-CdLog -Component 'Cli' -Message "CloudDrives $($ctx.Version): '$($parsed.Command)'" -Data @{
            args = $Arguments; ps = $PSVersionTable.PSVersion.ToString(); edition = $PSVersionTable.PSEdition
            os = [Environment]::OSVersion.VersionString; home = $ctx.Home
        }
        if ($settingsError) { throw $settingsError }
        if (-not $silent) { Initialize-CdConsole }

        switch ($parsed.Command) {
            'menu' { $exitCode = Get-CdLastInt (Start-CdConsoleMenu) }
            'connect' { $exitCode = Get-CdLastInt (Invoke-CdCommandLineConnect -Parsed $parsed) }
            'disconnect' { $exitCode = Get-CdLastInt (Invoke-CdCommandLineDisconnect -Parsed $parsed) }
            'status' { $exitCode = Get-CdLastInt (Invoke-CdCommandLineStatus -Parsed $parsed) }
            'autostart' { $exitCode = Get-CdLastInt (Invoke-CdCommandLineAutostart -Parsed $parsed) }
            'add-account' { $null = Start-CdAddAccountWizard }
            'remove-account' { $null = Start-CdRemoveAccountWizard }
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
    Write-CdLog -Component 'Cli' -Message "Finished with exit code $exitCode."
    [int]$exitCode
}
