# Support bundle: one ZIP with the diagnosis, versions, settings and recent logs for troubleshooting.
# It never contains passwords, tokens, keys or file contents. All texts are redacted (secrets, e-mail
# addresses, user and computer name, profile paths), and before the ZIP is written every file is searched
# for each secret value CloudDrives can see - a single hit discards the bundle (CD-9003).

# rclone options whose values are safe and useful in a bundle; all others only show that they are set.
$script:CdSupportSafeKeys = @('type', 'scope', 'drive_type', 'export_formats', 'filename_encryption', 'directory_name_encryption', 'filename_encoding')

function Protect-CdSupportText {
    # Redacts text for other people: secrets (as in the logs) plus personal data.
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $t = Protect-CdText $Text
    $t = [regex]::Replace($t, '[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}', '***@***')
    foreach ($pair in @(@($env:USERPROFILE, '%USERPROFILE%'), @($env:USERNAME, '<user>'), @($env:COMPUTERNAME, '<pc>'))) {
        if ($pair[0] -and $pair[0].Length -ge 3) {
            $t = [regex]::Replace($t, '(?i)(?<![A-Za-z0-9])' + [regex]::Escape($pair[0]) + '(?![A-Za-z0-9])', $pair[1])
        }
    }
    $t
}

function Get-CdKnownSecretValues {
    # Every secret CloudDrives can see right now: its own keys and, from the engine, tokens, client secrets
    # and vault passwords of all remotes. Used to prove that none of them ends up in a support bundle.
    $values = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('config', 'rc')) {
        $value = Get-CdSecret -Name $name
        if ($value) { $values.Add([string]$value) }
    }
    if (Test-CdEngineRunning) {
        foreach ($remote in @(Get-CdRemoteNames)) {
            $config = Invoke-CdRc -Command 'config/get' -Body @{ name = $remote }
            foreach ($property in @($config.PSObject.Properties)) {
                if ($property.Name -notmatch '^(token|client_secret|password2?|pass|key|secret_access_key|service_account_credentials)$') { continue }
                $value = [string]$property.Value
                if (-not $value) { continue }
                $values.Add($value)
                if ($property.Name -eq 'token') {
                    try {
                        $token = $value | ConvertFrom-Json
                        foreach ($part in @($token.access_token, $token.refresh_token)) { if ($part) { $values.Add([string]$part) } }
                    }
                    catch { Write-CdLog -Level DEBUG -Component 'Support' -Message "Token of '$remote' is not JSON." }
                }
            }
        }
    }
    # One value per pipeline item: callers collect them with @(...).
    $values | Where-Object { $_.Length -ge 8 } | Select-Object -Unique
}

function Get-CdSupportSystemText {
    $ctx = Get-CdContext
    $rclone = Find-CdRclone
    $winfsp = Get-CdWinFsp
    $rcloneText = 'missing'
    if ($rclone) { $rcloneText = '{0} ({1}, {2})' -f $rclone.Version, $rclone.Source, $rclone.Path }
    $winfspText = 'missing'
    if ($winfsp) { $winfspText = '{0} (launcher: {1})' -f $winfsp.Version, $winfsp.LauncherStatus }
    $mode = 'portable'
    if (Test-CdInstalled) { $mode = 'installed' }
    @(
        "CloudDrives: $($ctx.Version) ($mode, $($ctx.AppRoot))"
        "Created:     $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))"
        "Windows:     $([Environment]::OSVersion.VersionString) ($(Get-CdArchitecture))"
        "PowerShell:  $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
        "Language:    $([Globalization.CultureInfo]::CurrentUICulture.Name)"
        "rclone:      $rcloneText"
        "WinFsp:      $winfspText"
        "Home:        $($ctx.Home)"
    ) -join "`r`n"
}

function Get-CdSupportSettingsText {
    # The settings without the names of signed-in users and without the master password salt.
    $file = (Get-CdContext).SettingsFile
    if (-not (Test-Path -LiteralPath $file)) { return '{}' }
    $settings = ConvertTo-CdHashtable ([IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json)
    foreach ($account in @($settings.accounts)) {
        if ($account -and $account.identity) { $account.identity.name = '***' }
    }
    if ($settings.masterPasswordSalt) { $settings.masterPasswordSalt = '***' }
    ConvertTo-Json -InputObject $settings -Depth 10
}

function Get-CdSupportEngineText {
    $engine = Get-CdEngine
    if (-not $engine) { return 'Engine: not started' }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('Engine: pid {0}, alive {1}, healthy {2}, rclone {3}, started {4:u}' -f $engine.ProcessId, $engine.Alive, $engine.Healthy, $engine.RcloneVersion, $engine.StartTimeUtc))
    if (-not $engine.Healthy) { return ($lines -join "`r`n") }
    try { $lines.Add('core/version: ' + (ConvertTo-Json -InputObject (Invoke-CdRc -Command 'core/version') -Compress)) }
    catch { $lines.Add("core/version: $($_.Exception.Message)") }
    $lines.Add('')
    $lines.Add('Remotes (values only for harmless options):')
    foreach ($name in @(Get-CdRemoteNames)) {
        $config = Invoke-CdRc -Command 'config/get' -Body @{ name = $name }
        $values = foreach ($property in @($config.PSObject.Properties)) {
            if ($script:CdSupportSafeKeys -contains $property.Name -or [string]::IsNullOrEmpty([string]$property.Value)) { '{0}={1}' -f $property.Name, $property.Value }
            else { '{0}=(set)' -f $property.Name }
        }
        $lines.Add(('  {0}: {1}' -f $name, ($values -join ', ')))
    }
    $lines.Add('')
    $lines.Add('Mounts:')
    foreach ($mount in @((Invoke-CdRc -Command 'mount/listmounts').mountPoints | Where-Object { $_ })) {
        $lines.Add(('  {0} -> {1}' -f $mount.MountPoint, $mount.Fs))
        try { $lines.Add('    vfs/stats: ' + (ConvertTo-Json -InputObject (Invoke-CdRc -Command 'vfs/stats' -Body @{ fs = [string]$mount.Fs } -TimeoutSec 15) -Depth 5 -Compress)) }
        catch { $lines.Add("    vfs/stats: $($_.Exception.Message)") }
    }
    $lines -join "`r`n"
}

function Write-CdSupportFile {
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Text)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    [IO.File]::WriteAllText($Path, (Protect-CdSupportText $Text), (New-Object Text.UTF8Encoding($false)))
}

function New-CdSupportBundle {
    # Writes the support bundle (ZIP) and returns a result with its path. -Checks reuses a diagnosis.
    param([object[]]$Checks, [string]$Path)
    $ctx = Get-CdContext
    if (-not $Checks) { $Checks = @(Invoke-CdDoctor) }
    if (-not $Path) { $Path = Join-Path ([Environment]::GetFolderPath('Desktop')) ('CloudDrives-Support-{0}.zip' -f (Get-Date).ToString('yyyyMMdd-HHmmss')) }
    $Path = [IO.Path]::GetFullPath($Path)

    $work = Join-Path ([IO.Path]::GetTempPath()) ('clouddrives-support-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $work -Force)
    $engineWasRunning = Test-CdEngineRunning
    try {
        Write-CdSupportFile -Path (Join-Path $work 'README.txt') -Text (Get-CdText 'support.readme' $ctx.Version, (Get-Date).ToString('g'))
        Write-CdSupportFile -Path (Join-Path $work 'report.txt') -Text (Format-CdDoctorReport -Checks $Checks)
        Write-CdSupportFile -Path (Join-Path $work 'report.json') -Text (ConvertTo-Json -InputObject @($Checks | Select-Object Area, Name, Status, Message, Code, Fix) -Depth 4)
        Write-CdSupportFile -Path (Join-Path $work 'system.txt') -Text (Get-CdSupportSystemText)
        Write-CdSupportFile -Path (Join-Path $work 'settings.json') -Text (Get-CdSupportSettingsText)

        # The engine knows the remotes and their secrets (for the final check); start it if necessary.
        if (-not $engineWasRunning -and (Find-CdRclone)) {
            try { [void](Start-CdEngine) } catch { Write-CdLog -Level WARN -Component 'Support' -Message "Engine unavailable: $((Get-CdErrorInfo $_).Code)" }
        }
        Write-CdSupportFile -Path (Join-Path $work 'engine.txt') -Text (Get-CdSupportEngineText)

        $since = (Get-Date).AddDays(-7)
        if (Test-Path -LiteralPath $ctx.LogDir) {
            foreach ($file in @(Get-ChildItem -LiteralPath $ctx.LogDir -Filter 'clouddrives-*.log' -File | Where-Object { $_.LastWriteTime -ge $since })) {
                Write-CdSupportFile -Path (Join-Path $work "logs\$($file.Name)") -Text (Read-CdFileTail -Path $file.FullName -MaxBytes 4194304)
            }
            $rcloneLog = Join-Path $ctx.LogDir 'rclone.log'
            if (Test-Path -LiteralPath $rcloneLog) {
                Write-CdSupportFile -Path (Join-Path $work 'logs\rclone.log') -Text (Read-CdFileTail -Path $rcloneLog -MaxBytes 1048576)
            }
        }

        # Last line of defence: no secret CloudDrives knows may appear anywhere in the bundle.
        $secrets = @(Get-CdKnownSecretValues)
        foreach ($file in @(Get-ChildItem -LiteralPath $work -Recurse -File)) {
            $text = [IO.File]::ReadAllText($file.FullName)
            foreach ($secret in $secrets) {
                if ($text.Contains($secret)) {
                    Write-CdLog -Level ERROR -Component 'Support' -Message "A secret was found in '$($file.Name)'; the support bundle was discarded."
                    throw (New-CdException -Code 'CD-9003' -Detail $file.Name)
                }
            }
        }

        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($work, $Path, [IO.Compression.CompressionLevel]::Optimal, $false)
        $files = @(Get-ChildItem -LiteralPath $work -Recurse -File | ForEach-Object { $_.FullName.Substring($work.Length + 1) })
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        if (-not $engineWasRunning -and (Test-CdEngineRunning) -and (Get-CdMountedDrives).Count -eq 0) {
            try { Stop-CdEngine } catch { Write-CdLog -Level DEBUG -Component 'Support' -Message "Engine stop: $($_.Exception.Message)" }
        }
    }
    Write-CdLog -Component 'Support' -Message "Support bundle written ($($files.Count) files)."
    New-CdResult -Message (Get-CdText 'support.created' $Path) -Data ([pscustomobject]@{ Path = $Path; Files = $files })
}
