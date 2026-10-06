# Application log: one text file per day in <home>\logs. Secrets are always redacted before writing.

$script:CdLogLevel = 'INFO'
$script:CdLogLevels = @{ DEBUG = 0; INFO = 1; WARN = 2; ERROR = 3 }

function Set-CdLogLevel {
    param([ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')][string]$Level)
    $script:CdLogLevel = $Level
}

function Protect-CdText {
    # Masks tokens, passwords and other secrets in free text before it is logged or displayed.
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $t = $Text
    $t = [regex]::Replace($t, '(?i)("(?:access_token|refresh_token|id_token|client_secret|password2?|pass|token|secret)"\s*:\s*")[^"]*(")', '$1***$2')
    $t = [regex]::Replace($t, '(?i)\b(access_token|refresh_token|id_token|client_secret|password2?|pass|token|secret)(\s*[=:]\s*)(?!\*\*\*)[^\s,;&"]+', '$1$2***')
    $t = [regex]::Replace($t, '(?i)\b(RCLONE_[A-Z0-9_]*(?:PASS|PASSWORD2?|TOKEN|SECRET|USER)[A-Z0-9_]*)=\S+', '$1=***')
    $t = [regex]::Replace($t, '(?i)(Bearer\s+)[A-Za-z0-9\-\._~\+/]+=*', '$1***')
    $t = [regex]::Replace($t, '(?i)(Basic\s+)[A-Za-z0-9\+/]+=*', '$1***')
    $t = [regex]::Replace($t, 'ya29\.[0-9A-Za-z\-_]+', 'ya29.***')
    $t = [regex]::Replace($t, '\b1//[0-9A-Za-z\-_]{20,}', '1//***')
    $t = [regex]::Replace($t, '\beyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]*', '***jwt***')
    $t = [regex]::Replace($t, '\bM\.C\d+_[A-Za-z0-9!\*\$\.\-_]{20,}', 'M.C***')
    $t
}

function Write-CdLog {
    # Writes one line to the log - redacted, never throwing. Lines below the log level are skipped;
    # CLOUDDRIVES_DEBUG=1 writes everything.
    param(
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [string]$Component = 'App',
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [object]$Data
    )
    try {
        $threshold = $script:CdLogLevels[$script:CdLogLevel]
        if ($env:CLOUDDRIVES_DEBUG -eq '1') { $threshold = 0 }
        if ($script:CdLogLevels[$Level] -lt $threshold) { return }

        $ctx = Get-CdContext
        if (-not (Test-Path -LiteralPath $ctx.LogDir)) { return }

        $line = '{0} [{1,-5}] [{2}] [{3}] {4}' -f (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz'), $Level, $ctx.RunId, $Component, (Protect-CdText $Message)
        if ($null -ne $Data) {
            $json = $null
            try { $json = ConvertTo-Json -InputObject $Data -Depth 6 -Compress } catch { $json = [string]$Data }
            $line += ' ' + (Protect-CdText $json)
        }

        $file = Join-Path $ctx.LogDir ('clouddrives-{0}.log' -f (Get-Date).ToString('yyyy-MM-dd'))
        $bytes = [Text.Encoding]::UTF8.GetBytes($line + "`r`n")
        for ($i = 0; $i -lt 5; $i++) {
            try {
                $stream = New-Object IO.FileStream($file, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
                try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
                break
            }
            catch { Start-Sleep -Milliseconds (20 * ($i + 1)) }
        }
    }
    catch {
        # Logging must never break the application.
        $null = $_
    }
}

function Remove-CdOldLog {
    param([int]$KeepDays = 14)
    $ctx = Get-CdContext
    if (-not (Test-Path -LiteralPath $ctx.LogDir)) { return }
    $limit = (Get-Date).AddDays(-$KeepDays)
    Get-ChildItem -LiteralPath $ctx.LogDir -Filter 'clouddrives-*.log' -File |
        Where-Object { $_.LastWriteTime -lt $limit } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Read-CdFileTail {
    # Returns text appended to a file since a byte offset (used to read fresh rclone log output).
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$FromOffset = 0,
        [int]$MaxBytes = 65536
    )
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $start = [Math]::Max($FromOffset, $stream.Length - $MaxBytes)
        if ($start -gt $stream.Length) { $start = 0 }
        [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
        $reader.ReadToEnd()
    }
    finally { $stream.Dispose() }
}
