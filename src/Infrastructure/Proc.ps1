# Process helpers: Windows command-line quoting, synchronous runs with captured output and timeout,
# and detached background starts for the rclone engine.

function ConvertTo-CdQuotedArgument {
    # Quotes one argument following the rules of CommandLineToArgvW / the MSVC runtime.
    param([AllowEmptyString()][string]$Argument)
    if ($null -eq $Argument -or $Argument.Length -eq 0) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }
    $backslash = [char]92
    $quote = [char]34
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append($quote)
    $backslashes = 0
    foreach ($char in $Argument.ToCharArray()) {
        if ($char -eq $backslash) { $backslashes++; continue }
        if ($char -eq $quote) {
            [void]$builder.Append($backslash, (2 * $backslashes) + 1)
            [void]$builder.Append($quote)
        }
        else {
            if ($backslashes -gt 0) { [void]$builder.Append($backslash, $backslashes) }
            [void]$builder.Append($char)
        }
        $backslashes = 0
    }
    if ($backslashes -gt 0) { [void]$builder.Append($backslash, 2 * $backslashes) }
    [void]$builder.Append($quote)
    $builder.ToString()
}

function ConvertTo-CdArgumentString {
    param([AllowEmptyCollection()][string[]]$ArgumentList = @())
    (@($ArgumentList) | ForEach-Object { ConvertTo-CdQuotedArgument $_ }) -join ' '
}

function Invoke-CdProcess {
    # Runs a process synchronously, captures stdout/stderr and enforces a timeout.
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [AllowEmptyCollection()][string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{},
        [int]$TimeoutSec = 120,
        [string]$WorkingDirectory
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ConvertTo-CdArgumentString -ArgumentList $ArgumentList
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    foreach ($key in $Environment.Keys) { $psi.EnvironmentVariables[[string]$key] = [string]$Environment[$key] }

    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($TimeoutSec * 1000)
        if ($timedOut) {
            try { $process.Kill() } catch { Write-CdLog -Level DEBUG -Component 'Proc' -Message "Kill failed: $($_.Exception.Message)" }
            [void]$process.WaitForExit(5000)
        }
        else {
            $process.WaitForExit()
        }
        $exitCode = -1
        if (-not $timedOut) { $exitCode = $process.ExitCode }
        [pscustomobject]@{
            ExitCode = $exitCode
            StdOut   = $stdoutTask.GetAwaiter().GetResult()
            StdErr   = $stderrTask.GetAwaiter().GetResult()
            TimedOut = $timedOut
        }
    }
    finally {
        $process.Dispose()
    }
}

function Start-CdDetachedProcess {
    # Starts a long-running background process without a window and returns its process id.
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [AllowEmptyCollection()][string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{},
        [string]$WorkingDirectory
    )
    if (-not $WorkingDirectory) { $WorkingDirectory = Split-Path -Parent $FilePath }
    $arguments = ConvertTo-CdArgumentString -ArgumentList $ArgumentList

    if (Initialize-CdNative) {
        $environmentTable = @{}
        foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) { $environmentTable[[string]$entry.Key] = [string]$entry.Value }
        foreach ($key in $Environment.Keys) { $environmentTable[[string]$key] = [string]$Environment[$key] }
        $commandLine = (ConvertTo-CdQuotedArgument $FilePath) + ' ' + $arguments
        return [CloudDrives.Native.ProcessLauncher]::StartDetached($FilePath, $commandLine, $WorkingDirectory, $environmentTable)
    }

    # Fallback without native helpers: hidden .NET process start (handles may be inherited).
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $WorkingDirectory
    foreach ($key in $Environment.Keys) { $psi.EnvironmentVariables[[string]$key] = [string]$Environment[$key] }
    $process = [System.Diagnostics.Process]::Start($psi)
    $process.Id
}
