# The engine: one hidden "rclone rcd" process per user session that hosts every mount.
# It listens on 127.0.0.1 with a random port and random credentials (stored in the secret store).
# State (pid, port, start time - no secrets) is kept in <home>\state\engine.json.

function Get-CdEngineStateFile {
    Join-Path (Get-CdContext).StateDir 'engine.json'
}

function Read-CdEngineState {
    # Port and process of the engine as recorded when it was started (state\engine.json), or $null.
    $file = Get-CdEngineStateFile
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try { [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch { $null }
}

function Clear-CdEngineState {
    $file = Get-CdEngineStateFile
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    Remove-CdSecret -Name 'rc'
}

function Get-CdEngineConnection {
    # What a call to the engine needs: its port and process and the RC credentials from the secret store; $null
    # when no engine was started.
    $state = Read-CdEngineState
    if (-not $state) { return $null }
    $credential = Get-CdSecret -Name 'rc'
    if (-not $credential) { return $null }
    [pscustomobject]@{
        Port      = [int]$state.port
        ProcessId = [int]$state.pid
        AuthToken = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($credential))
    }
}

function Test-CdEngineProcess {
    # True when the recorded process is still the rclone engine we started (guards against PID reuse).
    # The start time is stored as UTC ticks: JSON dates are parsed differently by PowerShell 5.1 and 7.
    param([Parameter(Mandatory)][object]$State)
    $process = Get-Process -Id ([int]$State.pid) -ErrorAction SilentlyContinue
    if (-not $process -or $process.ProcessName -ne 'rclone') { return $false }
    try {
        $difference = [Math]::Abs($process.StartTime.ToUniversalTime().Ticks - [long]$State.startTicks)
        return ($difference -lt [TimeSpan]::FromSeconds(5).Ticks)
    }
    catch { return $true }
}

function Get-CdEngine {
    # Returns the engine status or $null when no engine was started.
    $state = Read-CdEngineState
    if (-not $state) { return $null }
    $alive = Test-CdEngineProcess -State $state
    $healthy = $false
    if ($alive) {
        $connection = Get-CdEngineConnection
        if ($connection) {
            try { [void](Invoke-CdRc -Command 'rc/noop' -Connection $connection -TimeoutSec 5); $healthy = $true }
            catch { Write-CdLog -Level WARN -Component 'Engine' -Message "Engine not responding: $($_.Exception.Message)" }
        }
    }
    $started = $null
    if ($state.startTicks) { $started = New-Object DateTime([long]$state.startTicks, [DateTimeKind]::Utc) }
    [pscustomobject]@{
        PSTypeName    = 'CloudDrives.Engine'
        ProcessId     = [int]$state.pid
        Port          = [int]$state.port
        Alive         = $alive
        Healthy       = $healthy
        RcloneVersion = [string]$state.rcloneVersion
        StartTimeUtc  = $started
    }
}

function Test-CdEngineRunning {
    # True when the engine runs and answers (a recorded process alone is not enough).
    $engine = Get-CdEngine
    [bool]($engine -and $engine.Healthy)
}

function Stop-CdEngineProcess {
    # Gives an engine process time to end and terminates it when it does not end in time.
    param([Parameter(Mandatory)][int]$ProcessId, [int]$WaitSec = 10)
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { return }
    if (-not $process.WaitForExit($WaitSec * 1000)) {
        Write-CdLog -Level WARN -Component 'Engine' -Message "Engine $ProcessId did not exit in time, terminating it."
        try { $process.Kill(); [void]$process.WaitForExit(5000) }
        catch { Write-CdLog -Level WARN -Component 'Engine' -Message "Kill failed: $($_.Exception.Message)" }
    }
}

function Start-CdEngine {
    # Starts the engine (or returns the running one). Retries on port problems; classifies start failures.
    param([switch]$AllowInstall)
    $lock = Enter-CdLock -Name 'engine'
    try {
        $existing = Get-CdEngine
        if ($existing -and $existing.Healthy) { return $existing }
        if ($existing -and $existing.Alive) {
            Write-CdLog -Level WARN -Component 'Engine' -Message 'Found an unresponsive engine, restarting it.'
            Stop-CdEngineProcess -ProcessId $existing.ProcessId -WaitSec 0
        }
        Clear-CdEngineState

        Initialize-CdHome
        $rclone = Resolve-CdRclone -AllowInstall:$AllowInstall
        if (-not (Test-CdWinFsp)) { throw (New-CdException -Code 'CD-1002') }
        $configPassword = Get-CdConfigPassword
        Initialize-CdRcloneConfig -RclonePath $rclone.Path -ConfigPassword $configPassword

        $ctx = Get-CdContext
        $settings = Get-CdSettings
        $cacheDir = $ctx.CacheDir
        if ($settings.cache.dir) { $cacheDir = [Environment]::ExpandEnvironmentVariables([string]$settings.cache.dir) }
        $logFile = Join-Path $ctx.LogDir 'rclone.log'
        $logLevel = 'INFO'
        if ($settings.logLevel -eq 'DEBUG' -or $env:CLOUDDRIVES_DEBUG -eq '1') { $logLevel = 'DEBUG' }

        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $port = Get-CdFreeTcpPort
            $rcUser = 'clouddrives'
            $rcPassword = New-CdRandomSecret
            Set-CdSecret -Name 'rc' -Value "${rcUser}:$rcPassword"
            $logOffset = 0
            if (Test-Path -LiteralPath $logFile) { $logOffset = (Get-Item -LiteralPath $logFile).Length }

            $rcloneArgs = @(
                'rcd', '--rc-addr', "127.0.0.1:$port",
                '--config', $ctx.RcloneConfig,
                '--cache-dir', $cacheDir,
                '--log-file', $logFile, '--log-level', $logLevel,
                '--log-file-max-size', '10M', '--log-file-max-backups', '5', '--log-file-compress',
                '--rc-job-expire-duration', '10m'
            )
            $environment = @{ RCLONE_CONFIG_PASS = $configPassword; RCLONE_RC_USER = $rcUser; RCLONE_RC_PASS = $rcPassword }
            $engineId = Start-CdDetachedProcess -FilePath $rclone.Path -ArgumentList $rcloneArgs -Environment $environment -WorkingDirectory $ctx.Home

            $startTime = (Get-Date).ToUniversalTime()
            try { $startTime = (Get-Process -Id $engineId -ErrorAction Stop).StartTime.ToUniversalTime() }
            catch { Write-CdLog -Level DEBUG -Component 'Engine' -Message "Start time of $engineId unavailable: $($_.Exception.Message)" }
            $state = [ordered]@{
                pid           = $engineId
                port          = $port
                startTicks    = $startTime.Ticks
                rclonePath    = $rclone.Path
                rcloneVersion = [string]$rclone.Version
            }
            [IO.File]::WriteAllText((Get-CdEngineStateFile), (ConvertTo-Json -InputObject $state), (New-Object Text.UTF8Encoding($false)))

            $connection = [pscustomobject]@{
                Port      = $port
                ProcessId = $engineId
                AuthToken = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${rcUser}:$rcPassword"))
            }
            $deadline = (Get-Date).AddSeconds(20)
            while ((Get-Date) -lt $deadline) {
                if (-not (Get-Process -Id $engineId -ErrorAction SilentlyContinue)) { break }
                try {
                    [void](Invoke-CdRc -Command 'rc/noop' -Connection $connection -TimeoutSec 3)
                    Write-CdLog -Component 'Engine' -Message "Engine started (pid $engineId, port $port, rclone $($rclone.Version))."
                    return (Get-CdEngine)
                }
                catch {
                    # Only "not reachable yet" is expected while the engine starts; anything else is a real error.
                    if ((Get-CdErrorCode $_) -ne 'CD-5003') { Stop-CdEngineProcess -ProcessId $engineId -WaitSec 0; Clear-CdEngineState; throw }
                    Start-Sleep -Milliseconds 300
                }
            }

            $output = Read-CdFileTail -Path $logFile -FromOffset $logOffset
            Stop-CdEngineProcess -ProcessId $engineId -WaitSec 0
            Clear-CdEngineState
            $code = Resolve-CdErrorCode -Text $output
            Write-CdLog -Level ERROR -Component 'Engine' -Message "Engine start failed ($code), attempt $attempt." -Data @{ log = $output }
            if ($code -eq 'CD-5002') { continue }
            if ($code -eq 'CD-9000') { $code = 'CD-5004' }
            throw (New-CdException -Code $code -Detail $output)
        }
        throw (New-CdException -Code 'CD-5002')
    }
    finally {
        Exit-CdLock -Mutex $lock
    }
}

function Stop-CdEngine {
    # Stops the engine gracefully (core/quit), terminating it only if it does not exit in time.
    $lock = Enter-CdLock -Name 'engine'
    try {
        $engine = Get-CdEngine
        if (-not $engine) { return }
        if ($engine.Healthy) {
            try { [void](Invoke-CdRc -Command 'core/quit' -TimeoutSec 5) }
            catch { Write-CdLog -Level DEBUG -Component 'Engine' -Message "core/quit: $($_.Exception.Message)" }
        }
        if ($engine.Alive) { Stop-CdEngineProcess -ProcessId $engine.ProcessId -WaitSec 15 }
        Clear-CdEngineState
        Write-CdLog -Component 'Engine' -Message 'Engine stopped.'
    }
    finally {
        Exit-CdLock -Mutex $lock
    }
}
