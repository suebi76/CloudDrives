# Diagnosis ("doctor"), the checks: system, components, settings, network, updates, engine, accounts, drives and
# recent errors. Every check is a uniform item (area, name, status, message, optional error code and fix id).
# Checks only read - except that the engine is started when accounts have to be checked. Doctor.ps1 runs them
# all, adds the checks of the background tasks, sums them up and repairs what can be repaired.

# rclone log errors that are no problems (see Get-CdEngineChecks).
$script:CdBenignRcloneErrors = @('^rc: "', 'symlinks not supported without the --links flag', 'context canceled', 'directory not found')
# Remembered once per process (see Get-CdLastBootTime).
$script:CdBootTime = $null

function New-CdCheck {
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('ok', 'info', 'warn', 'fail', 'skip')][string]$Status = 'ok',
        [string]$Message = '',
        [string]$Code = '',
        [string]$Fix = '',
        [string]$Target = ''
    )
    [pscustomobject]@{
        PSTypeName = 'CloudDrives.Check'
        Area       = $Area
        Name       = $Name
        Status     = $Status
        Message    = $Message
        Code       = $Code
        Fix        = $Fix
        Target     = $Target
    }
}

function Get-CdSystemChecks {
    $checks = New-Object System.Collections.Generic.List[object]
    $os = [Environment]::OSVersion.Version
    $caption = "Windows $os"
    try { $caption = [string](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption } catch { Write-CdLog -Level DEBUG -Component 'Doctor' -Message 'OS caption unavailable.' }
    $checks.Add((New-CdCheck -Area 'system' -Name (Get-CdText 'doctor.windows') -Status 'info' -Message ('{0} (Build {1}, {2})' -f $caption, $os.Build, (Get-CdArchitecture))))
    $checks.Add((New-CdCheck -Area 'system' -Name 'PowerShell' -Status 'info' -Message ('{0} {1}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)))

    # The VFS cache lives in the home folder; uploads wait there until they reach the cloud.
    $ctx = Get-CdContext
    try {
        $disk = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($ctx.Home))
        $free = [long]$disk.AvailableFreeSpace
        $status = 'ok'
        $code = ''
        if ($free -lt 1GB) { $status = 'fail'; $code = 'CD-7001' }
        elseif ($free -lt 5GB) { $status = 'warn'; $code = 'CD-7001' }
        $checks.Add((New-CdCheck -Area 'system' -Name (Get-CdText 'doctor.cacheSpace') -Status $status -Code $code -Message (Get-CdText 'doctor.cacheSpaceValue' (Format-CdSize $free), $disk.Name)))
    }
    catch { $checks.Add((New-CdCheck -Area 'system' -Name (Get-CdText 'doctor.cacheSpace') -Status 'skip' -Message $_.Exception.Message)) }
    $checks.ToArray()
}

function Get-CdComponentChecks {
    $checks = New-Object System.Collections.Generic.List[object]
    $deps = Get-CdDependencyInfo
    $rclone = Find-CdRclone
    if ($rclone) {
        $source = Get-CdText "doctor.source.$($rclone.Source)"
        $checks.Add((New-CdCheck -Area 'components' -Name 'rclone' -Message (Get-CdText 'doctor.rcloneOk' ([string]$rclone.Version), $source)))
    }
    else {
        $checks.Add((New-CdCheck -Area 'components' -Name 'rclone' -Status 'fail' -Code 'CD-1001' -Fix 'install-rclone' -Message (Get-CdText 'doctor.rcloneMissing')))
    }

    $winfsp = Get-CdWinFsp
    $minimum = [version]$deps.winfsp.minimumVersion
    if (-not $winfsp) {
        $checks.Add((New-CdCheck -Area 'components' -Name 'WinFsp' -Status 'fail' -Code 'CD-1002' -Fix 'install-winfsp' -Message (Get-CdText 'doctor.winfspMissing')))
    }
    elseif ($winfsp.Version -lt $minimum) {
        $checks.Add((New-CdCheck -Area 'components' -Name 'WinFsp' -Status 'fail' -Code 'CD-1002' -Fix 'install-winfsp' -Message (Get-CdText 'doctor.winfspOld' ([string]$winfsp.Version), ([string]$minimum))))
    }
    else {
        $checks.Add((New-CdCheck -Area 'components' -Name 'WinFsp' -Message (Get-CdText 'doctor.winfspOk' ([string]$winfsp.Version))))
    }

    $ctx = Get-CdContext
    if (Test-CdInstalled) { $checks.Add((New-CdCheck -Area 'components' -Name 'CloudDrives' -Message (Get-CdText 'doctor.appInstalled' $ctx.Version, $ctx.AppRoot))) }
    else { $checks.Add((New-CdCheck -Area 'components' -Name 'CloudDrives' -Status 'info' -Message (Get-CdText 'doctor.appPortable' $ctx.Version, $ctx.AppRoot))) }
    $checks.ToArray()
}

function Get-CdSettingsChecks {
    $checks = New-Object System.Collections.Generic.List[object]
    $ctx = Get-CdContext
    $settings = $null
    try {
        $settings = Get-CdSettings
        # Test-CdSettings returns its list as one object; wrapping it in @() would count the list itself.
        $problems = Test-CdSettings -Settings $settings
        if (@($problems).Count -gt 0) { $checks.Add((New-CdCheck -Area 'settings' -Name (Get-CdText 'doctor.settings') -Status 'fail' -Code 'CD-2001' -Message ($problems -join '; '))) }
        else { $checks.Add((New-CdCheck -Area 'settings' -Name (Get-CdText 'doctor.settings') -Message (Get-CdText 'doctor.settingsOk' @($settings.accounts).Count, @($settings.drives).Count))) }
    }
    catch {
        $info = Get-CdErrorInfo $_
        $checks.Add((New-CdCheck -Area 'settings' -Name (Get-CdText 'doctor.settings') -Status 'fail' -Code $info.Code -Message $info.Title))
    }

    $hasAccounts = $settings -and @($settings.accounts).Count -gt 0
    if (Test-CdRcloneConfigExists) {
        if (Test-CdRcloneConfigEncrypted) { $checks.Add((New-CdCheck -Area 'settings' -Name (Get-CdText 'doctor.config') -Message (Get-CdText 'doctor.configEncrypted'))) }
        else { $checks.Add((New-CdCheck -Area 'settings' -Name (Get-CdText 'doctor.config') -Status 'warn' -Message (Get-CdText 'doctor.configPlain'))) }
    }
    elseif ($hasAccounts) { $checks.Add((New-CdCheck -Area 'settings' -Name (Get-CdText 'doctor.config') -Status 'fail' -Code 'CD-2002' -Message (Get-CdText 'doctor.configMissing' $ctx.BackupDir))) }
    else { $checks.Add((New-CdCheck -Area 'settings' -Name (Get-CdText 'doctor.config') -Status 'info' -Message (Get-CdText 'doctor.configNone'))) }

    if ($settings -and $settings.securityMode -eq 'masterPassword') {
        $checks.Add((New-CdCheck -Area 'settings' -Name (Get-CdText 'doctor.key') -Status 'info' -Message (Get-CdText 'doctor.keyMaster')))
    }
    elseif (Get-CdSecret -Name 'config') {
        $checks.Add((New-CdCheck -Area 'settings' -Name (Get-CdText 'doctor.key') -Message (Get-CdText 'doctor.keyStored')))
    }
    elseif (Test-CdRcloneConfigExists) {
        $checks.Add((New-CdCheck -Area 'settings' -Name (Get-CdText 'doctor.key') -Status 'fail' -Code 'CD-2003' -Message (Get-CdText 'doctor.keyMissing')))
    }

    if (Test-Path -LiteralPath $ctx.Home) {
        if (Test-CdPrivateDirectory -Path $ctx.Home) { $checks.Add((New-CdCheck -Area 'settings' -Name (Get-CdText 'doctor.home') -Message (Get-CdText 'doctor.homePrivate'))) }
        else { $checks.Add((New-CdCheck -Area 'settings' -Name (Get-CdText 'doctor.home') -Status 'warn' -Fix 'protect-home' -Message (Get-CdText 'doctor.homeOpen'))) }
    }
    $checks.ToArray()
}

function Get-CdNetworkChecks {
    $checks = New-Object System.Collections.Generic.List[object]
    $providers = @((Get-CdSettings).accounts | ForEach-Object { [string]$_.provider } | Select-Object -Unique)
    if ($providers.Count -eq 0) { $providers = @('drive', 'onedrive') }
    $targets = [ordered]@{}
    if ($providers -contains 'drive') { $targets['Google'] = @('www.googleapis.com', 'oauth2.googleapis.com') }
    if ($providers -contains 'onedrive') { $targets['Microsoft'] = @('graph.microsoft.com', 'login.microsoftonline.com') }
    $targets['GitHub'] = @('api.github.com')
    foreach ($name in $targets.Keys) {
        $unreachable = @($targets[$name] | Where-Object { -not (Test-CdTcpEndpoint -HostName $_ -Port 443 -TimeoutMs 3000) })
        if ($unreachable.Count -eq 0) { $checks.Add((New-CdCheck -Area 'network' -Name $name -Message (Get-CdText 'doctor.reachable'))) }
        else {
            # Without GitHub only the update check suffers.
            $status = 'fail'
            if ($name -eq 'GitHub') { $status = 'warn' }
            $checks.Add((New-CdCheck -Area 'network' -Name $name -Status $status -Code 'CD-5001' -Message (Get-CdText 'doctor.unreachable' ($unreachable -join ', '))))
        }
    }

    # rclone does not use the Windows proxy settings, only the HTTPS_PROXY environment variable.
    try {
        $uri = [Uri]'https://www.googleapis.com/'
        $proxy = [Net.WebRequest]::GetSystemWebProxy().GetProxy($uri)
        if ($proxy -and $proxy.AbsoluteUri -ne $uri.AbsoluteUri) {
            if ($env:HTTPS_PROXY -or $env:https_proxy) { $checks.Add((New-CdCheck -Area 'network' -Name (Get-CdText 'doctor.proxy') -Status 'info' -Message (Get-CdText 'doctor.proxyForRclone' $proxy.Authority))) }
            else { $checks.Add((New-CdCheck -Area 'network' -Name (Get-CdText 'doctor.proxy') -Status 'warn' -Message (Get-CdText 'doctor.proxyNotForRclone' $proxy.Authority))) }
        }
    }
    catch { Write-CdLog -Level DEBUG -Component 'Doctor' -Message "Proxy lookup: $($_.Exception.Message)" }
    $checks.ToArray()
}

function Get-CdUpdateChecks {
    $name = Get-CdText 'doctor.updates'
    if (-not (Test-CdTcpEndpoint -HostName 'api.github.com' -Port 443 -TimeoutMs 3000)) {
        return (New-CdCheck -Area 'updates' -Name $name -Status 'skip' -Message (Get-CdText 'doctor.updateFailed'))
    }
    try {
        $state = Get-CdUpdateState
        if (-not $state.Latest) { return (New-CdCheck -Area 'updates' -Name $name -Status 'info' -Message (Get-CdText 'doctor.updateNone')) }
        if ($state.Available) { return (New-CdCheck -Area 'updates' -Name $name -Status 'warn' -Message (Get-CdText 'doctor.updateAvailable' ([string]$state.Latest))) }
        New-CdCheck -Area 'updates' -Name $name -Message (Get-CdText 'doctor.updateCurrent')
    }
    catch { New-CdCheck -Area 'updates' -Name $name -Status 'skip' -Message (Get-CdText 'doctor.updateFailed') }
}

function Get-CdLastBootTime {
    # When Windows was started (cached: it cannot change while CloudDrives runs).
    if (-not $script:CdBootTime) {
        try { $script:CdBootTime = [datetime](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime }
        catch { return $null }
    }
    $script:CdBootTime
}

function Get-CdEngineChecks {
    $checks = New-Object System.Collections.Generic.List[object]
    $name = Get-CdText 'doctor.engine'
    $state = Read-CdEngineState
    if (-not $state) { $checks.Add((New-CdCheck -Area 'engine' -Name $name -Status 'info' -Message (Get-CdText 'doctor.engineIdle'))) }
    else {
        $engine = Get-CdEngine
        if ($engine.Healthy) {
            $since = '-'
            if ($engine.StartTimeUtc) { $since = $engine.StartTimeUtc.ToLocalTime().ToString('g') }
            $checks.Add((New-CdCheck -Area 'engine' -Name $name -Message (Get-CdText 'doctor.engineRunning' $since, $engine.RcloneVersion)))
        }
        elseif ($engine.Alive) { $checks.Add((New-CdCheck -Area 'engine' -Name $name -Status 'fail' -Code 'CD-5003' -Fix 'restart-engine' -Message (Get-CdText 'doctor.engineHung'))) }
        else {
            # A state file from before the last Windows start is no crash, just left over.
            $boot = Get-CdLastBootTime
            if ($boot -and $engine.StartTimeUtc -and $engine.StartTimeUtc -lt $boot.ToUniversalTime()) {
                $checks.Add((New-CdCheck -Area 'engine' -Name $name -Status 'info' -Message (Get-CdText 'doctor.engineIdle')))
            }
            else { $checks.Add((New-CdCheck -Area 'engine' -Name $name -Status 'warn' -Fix 'restart-engine' -Message (Get-CdText 'doctor.engineCrashed'))) }
        }
    }

    # Errors rclone logged during the last 24 hours ("2026/10/04 12:34:56 ERROR : ..."), without noise:
    # failed RC requests are CloudDrives' own (it handles and logs them itself, e.g. when probing for a vault
    # folder), cancelled requests are timeouts it chose, and Windows asks every drive for symbolic links.
    $log = Join-Path (Get-CdContext).LogDir 'rclone.log'
    if (Test-Path -LiteralPath $log) {
        $since = (Get-Date).AddHours(-24)
        $errors = foreach ($line in ((Read-CdFileTail -Path $log -MaxBytes 524288) -split "`r?`n")) {
            if ($line -match '^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}) ERROR : (.*)$') {
                $text = $Matches[2]
                $time = [datetime]::ParseExact($Matches[1], 'yyyy/MM/dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
                $benign = @($script:CdBenignRcloneErrors | Where-Object { $text -match $_ }).Count -gt 0
                if ($time -ge $since -and -not $benign) { [pscustomobject]@{ Time = $time; Text = $text } }
            }
        }
        $errors = @($errors)
        if ($errors.Count -eq 0) { $checks.Add((New-CdCheck -Area 'engine' -Name (Get-CdText 'doctor.rcloneLog') -Message (Get-CdText 'doctor.rcloneLogOk'))) }
        else {
            $last = $errors[-1]
            $code = Resolve-CdErrorCode -Text $last.Text
            if ($code -eq 'CD-9000') { $code = '' }
            $checks.Add((New-CdCheck -Area 'engine' -Name (Get-CdText 'doctor.rcloneLog') -Status 'warn' -Code $code -Message (Get-CdText 'doctor.rcloneLogErrors' $errors.Count, (Format-CdShort -Text (Protect-CdText $last.Text) -Length 120).TrimEnd())))
        }
    }
    $checks.ToArray()
}

function Get-CdAccountChecks {
    $checks = New-Object System.Collections.Generic.List[object]
    $settings = Get-CdSettings
    if (@($settings.accounts).Count -eq 0) { return (New-CdCheck -Area 'accounts' -Name (Get-CdText 'doctor.area.accounts') -Status 'info' -Message (Get-CdText 'doctor.noAccounts')) }
    try { if (-not (Test-CdEngineRunning)) { [void](Start-CdEngine) } }
    catch {
        $info = Get-CdErrorInfo $_
        return (New-CdCheck -Area 'accounts' -Name (Get-CdText 'doctor.area.accounts') -Status 'skip' -Code $info.Code -Message (Get-CdText 'doctor.accountsSkipped' $info.Title))
    }
    $remotes = @(Get-CdRemoteNames)
    foreach ($account in @($settings.accounts)) {
        $remote = Get-CdAccountRemoteName -AccountId $account.id
        if ($remotes -notcontains $remote) {
            $checks.Add((New-CdCheck -Area 'accounts' -Name $account.label -Status 'fail' -Code 'CD-3001' -Fix 'relogin' -Target $account.id -Message (Get-CdText 'doctor.accountMissing')))
            continue
        }
        try {
            $about = Get-CdRemoteAbout -RemoteName $remote -CacheSec 0 -TimeoutSec 20
            $parts = New-Object System.Collections.Generic.List[string]
            if ($account.identity -and $account.identity.name) { $parts.Add([string]$account.identity.name) }
            $status = 'ok'
            $code = ''
            if ($about -and $null -ne $about.used) {
                if ($about.total) { $parts.Add((Get-CdText 'doctor.quota' (Format-CdSize $about.used), (Format-CdSize $about.total))) }
                else { $parts.Add((Get-CdText 'doctor.quotaUsed' (Format-CdSize $about.used))) }
                if ($about.total -and ([double]$about.used / [double]$about.total) -ge 0.95) {
                    $status = 'warn'
                    $code = 'CD-3006'
                    $parts.Add((Get-CdText 'doctor.storageFull' ([int][Math]::Floor(100 * [double]$about.used / [double]$about.total))))
                }
                # Workspace users get 15 GB when the admin console limits storage per user.
                if ($account.kind -eq 'workspace' -and [double]$about.total -eq 16106127360) {
                    $status = 'warn'
                    $parts.Add((Get-CdText 'doctor.workspaceLimit'))
                }
            }
            $checks.Add((New-CdCheck -Area 'accounts' -Name $account.label -Status $status -Code $code -Target $account.id -Message ($parts -join ' · ')))
        }
        catch {
            $info = Get-CdErrorInfo $_
            $entry = Get-CdErrorEntry -Code $info.Code
            $fix = ''
            $status = 'warn'
            if ($entry -and $entry.action -eq 'reconnect-account') { $fix = 'relogin'; $status = 'fail' }
            $checks.Add((New-CdCheck -Area 'accounts' -Name $account.label -Status $status -Code $info.Code -Fix $fix -Target $account.id -Message $info.Title))
        }
        if ($account.provider -eq 'drive' -and $account.clientId -ne 'own') {
            $checks.Add((New-CdCheck -Area 'accounts' -Name $account.label -Status 'warn' -Fix 'change-client' -Target $account.id -Message (Get-CdText 'doctor.sharedClient')))
        }
    }
    $checks.ToArray()
}

function Get-CdDriveChecks {
    $checks = New-Object System.Collections.Generic.List[object]
    $settings = Get-CdSettings
    if (@($settings.drives).Count -eq 0) { return (New-CdCheck -Area 'drives' -Name (Get-CdText 'doctor.area.drives') -Status 'info' -Message (Get-CdText 'doctor.noDrives')) }
    $mounted = Get-CdMountedDrives
    $used = @(Get-CdUsedDriveLetters)
    foreach ($drive in @($settings.drives)) {
        $mountPoint = "$($drive.letter):".ToUpperInvariant()
        $name = '{0} {1}' -f $mountPoint, $drive.label
        if (-not $mounted.ContainsKey($mountPoint)) {
            if ($used -contains [string]$drive.letter) { $checks.Add((New-CdCheck -Area 'drives' -Name $name -Status 'fail' -Code 'CD-4001' -Target $drive.id -Message (Get-CdText 'doctor.driveLetterTaken' $mountPoint))) }
            elseif ($drive.autoConnect -ne $false) { $checks.Add((New-CdCheck -Area 'drives' -Name $name -Status 'warn' -Fix 'connect' -Target $drive.id -Message (Get-CdText 'doctor.driveNotConnected'))) }
            else { $checks.Add((New-CdCheck -Area 'drives' -Name $name -Status 'info' -Target $drive.id -Message (Get-CdText 'doctor.driveManual'))) }
            continue
        }

        # Read test through the engine: lists the top folder of the drive.
        $watch = [Diagnostics.Stopwatch]::StartNew()
        try {
            [void](Invoke-CdRc -Command 'operations/list' -Body ([ordered]@{ fs = (Get-CdDriveFs -Drive $drive); remote = ''; opt = @{ noModTime = $true; noMimeType = $true } }) -TimeoutSec 30)
            $parts = New-Object System.Collections.Generic.List[string]
            $parts.Add((Get-CdText 'doctor.driveOk' ('{0:N1}' -f $watch.Elapsed.TotalSeconds)))
            $status = 'ok'
            $code = ''
            try {
                $cache = (Invoke-CdRc -Command 'vfs/stats' -Body @{ fs = [string]$mounted[$mountPoint].Fs } -TimeoutSec 15).diskCache
                if ($cache) {
                    $pending = [int]$cache.uploadsInProgress + [int]$cache.uploadsQueued
                    if ($pending -gt 0) { $parts.Add((Get-CdText 'doctor.uploadsPending' $pending)) }
                    if ($cache.outOfSpace) { $status = 'fail'; $code = 'CD-7001'; $parts.Add((Get-CdText 'doctor.cacheFull')) }
                    elseif ([int]$cache.erroredFiles -gt 0) { $status = 'warn'; $code = 'CD-7002'; $parts.Add((Get-CdText 'doctor.uploadErrors' ([int]$cache.erroredFiles))) }
                }
            }
            catch { Write-CdLog -Level DEBUG -Component 'Doctor' -Message "vfs/stats for '$($drive.id)': $($_.Exception.Message)" }
            $checks.Add((New-CdCheck -Area 'drives' -Name $name -Status $status -Code $code -Target $drive.id -Message ($parts -join ' · ')))
        }
        catch {
            $info = Get-CdErrorInfo $_
            $checks.Add((New-CdCheck -Area 'drives' -Name $name -Status 'fail' -Code $info.Code -Target $drive.id -Message (Get-CdText 'doctor.driveReadFailed')))
        }

        if ($drive.encrypted) {
            try {
                if (-not (Test-CdVaultKey -DriveId $drive.id)) { $checks.Add((New-CdCheck -Area 'drives' -Name $name -Status 'fail' -Code 'CD-6001' -Target $drive.id -Message (Get-CdText 'doctor.vaultWrong'))) }
            }
            catch { Write-CdLog -Level DEBUG -Component 'Doctor' -Message "Vault check of '$($drive.id)': $($_.Exception.Message)" }
        }
        $shown = Get-CdDriveLabel -Drive $drive
        if (-not $shown) {
            $checks.Add((New-CdCheck -Area 'drives' -Name $name -Status 'warn' -Fix 'labels' -Target $drive.id -Message (Get-CdText 'doctor.driveLabel')))
        }
        elseif ($shown -cne [string]$drive.label) {
            # Renamed in Explorer: no problem, CloudDrives adopts the name (Sync-CdDriveLabels).
            $checks.Add((New-CdCheck -Area 'drives' -Name $name -Status 'info' -Target $drive.id -Message (Get-CdText 'doctor.driveLabelDiffers' $shown, $drive.label)))
        }
    }
    $checks.ToArray()
}

function Get-CdLogChecks {
    # Errors CloudDrives logged during the last days, grouped by error code.
    param([int]$Days = 7)
    $ctx = Get-CdContext
    $name = Get-CdText 'doctor.logs'
    $since = (Get-Date).AddDays(-$Days)
    $byCode = @{}
    if (Test-Path -LiteralPath $ctx.LogDir) {
        foreach ($file in @(Get-ChildItem -LiteralPath $ctx.LogDir -Filter 'clouddrives-*.log' -File | Where-Object { $_.LastWriteTime -ge $since })) {
            foreach ($line in ((Read-CdFileTail -Path $file.FullName -MaxBytes 4194304) -split "`r?`n")) {
                if ($line -notmatch '^(\S+) \[ERROR\]') { continue }
                $time = [datetime]::MinValue
                if (-not [datetime]::TryParse($Matches[1], [ref]$time) -or $time -lt $since) { continue }
                $code = 'other'
                if ($line -match '\b(CD-\d{4})\b') { $code = $Matches[1] }
                if (-not $byCode.ContainsKey($code)) { $byCode[$code] = [pscustomobject]@{ Code = $code; Count = 0; Last = $time } }
                $byCode[$code].Count++
                if ($time -gt $byCode[$code].Last) { $byCode[$code].Last = $time }
            }
        }
    }
    if ($byCode.Count -eq 0) { return (New-CdCheck -Area 'logs' -Name $name -Message (Get-CdText 'doctor.logsOk' $Days)) }
    foreach ($entry in @($byCode.Values | Sort-Object -Property Count -Descending | Select-Object -First 5)) {
        $last = $entry.Last.ToString('g')
        if ($entry.Code -eq 'other') { New-CdCheck -Area 'logs' -Name $name -Status 'warn' -Message (Get-CdText 'doctor.logsOther' $entry.Count, $last) }
        else { New-CdCheck -Area 'logs' -Name $name -Status 'warn' -Code $entry.Code -Message (Get-CdText 'doctor.logsCode' $entry.Count, (Get-CdText "error.$($entry.Code).title"), $last) }
    }
}
