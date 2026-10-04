# Autostart: a scheduled task connects all auto-connect drives when the user signs in to Windows.
# It runs invisibly (conhost --headless), in the user's own session (mounts must be visible in Explorer),
# 30 seconds after logon, also on battery and without a time limit. If the Task Scheduler is not usable,
# a shortcut in the user's Startup folder is the fallback.

$script:CdAutostartTaskPath = '\CloudDrives\'

function Get-CdAutostartName {
    # No square brackets: the Task Scheduler cmdlets treat them as wildcards.
    $ctx = Get-CdContext
    if ($ctx.IsDefaultHome) { return 'CloudDrives Autostart' }
    "CloudDrives Autostart - $($ctx.HomeId)"
}

function Get-CdAutostartTask {
    # Exact-name lookup (the cmdlet's -TaskName filter is a wildcard match).
    $name = Get-CdAutostartName
    Get-ScheduledTask -TaskPath $script:CdAutostartTaskPath -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -eq $name } | Select-Object -First 1
}

function Get-CdStartupShortcutPath {
    Join-Path ([Environment]::GetFolderPath('Startup')) ((Get-CdAutostartName) + '.lnk')
}

function Get-CdAutostartCommand {
    # The command the autostart runs: hidden Windows PowerShell executing "connect --silent".
    param([string]$SrcRoot)
    $ctx = Get-CdContext
    if (-not $SrcRoot) { $SrcRoot = $ctx.SrcRoot }
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script = Join-Path $SrcRoot 'CloudDrives.ps1'
    $arguments = @('--headless', $powershell, '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script, 'connect', '--silent', '--autostart')
    if (-not $ctx.IsDefaultHome) { $arguments += "--home=$($ctx.Home)" }
    [pscustomobject]@{
        Execute          = Join-Path $env:WINDIR 'System32\conhost.exe'
        Arguments        = ConvertTo-CdArgumentString -ArgumentList $arguments
        WorkingDirectory = Get-CdNeutralDirectory
    }
}

function Get-CdAutostart {
    # Whether autostart is set up, and how.
    $task = Get-CdAutostartTask
    if ($task) {
        return [pscustomobject]@{ Enabled = ($task.State -ne 'Disabled'); Method = 'task'; Detail = "$($script:CdAutostartTaskPath)$($task.TaskName)" }
    }
    $shortcut = Get-CdStartupShortcutPath
    if (Test-Path -LiteralPath $shortcut) { return [pscustomobject]@{ Enabled = $true; Method = 'shortcut'; Detail = $shortcut } }
    [pscustomobject]@{ Enabled = $false; Method = $null; Detail = $null }
}

function Enable-CdAutostart {
    # -SrcRoot lets the installer point the autostart at the freshly installed copy.
    param([string]$SrcRoot)
    $command = Get-CdAutostartCommand -SrcRoot $SrcRoot
    $user = "$env:USERDOMAIN\$env:USERNAME"
    try {
        $action = New-ScheduledTaskAction -Execute $command.Execute -Argument $command.Arguments -WorkingDirectory $command.WorkingDirectory
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $trigger.Delay = 'PT30S'
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
        [void](Register-ScheduledTask -TaskPath $script:CdAutostartTaskPath -TaskName (Get-CdAutostartName) -Action $action -Trigger $trigger `
                -Principal $principal -Settings $settings -Description 'CloudDrives: verbindet die Cloud-Laufwerke bei der Anmeldung.' -Force -ErrorAction Stop)
        Remove-CdStartupShortcut
        Write-CdLog -Component 'Autostart' -Message 'Autostart task registered.'
        return (New-CdResult -Message (Get-CdText 'autostart.enabled') -Data (Get-CdAutostart))
    }
    catch {
        Write-CdLog -Level WARN -Component 'Autostart' -Message "Task Scheduler unavailable, using a Startup shortcut: $($_.Exception.Message)"
    }
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut((Get-CdStartupShortcutPath))
    $link.TargetPath = $command.Execute
    $link.Arguments = $command.Arguments
    $link.WorkingDirectory = $command.WorkingDirectory
    $link.WindowStyle = 7
    $link.Description = 'CloudDrives Autostart'
    $link.Save()
    Write-CdLog -Component 'Autostart' -Message 'Autostart shortcut created.'
    New-CdResult -Message (Get-CdText 'autostart.enabled') -Data (Get-CdAutostart)
}

function Remove-CdStartupShortcut {
    $shortcut = Get-CdStartupShortcutPath
    if (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut -Force }
}

function Disable-CdAutostart {
    $task = Get-CdAutostartTask
    if ($task) { $task | Unregister-ScheduledTask -Confirm:$false }
    Remove-CdStartupShortcut
    Write-CdLog -Component 'Autostart' -Message 'Autostart removed.'
    New-CdResult -Message (Get-CdText 'autostart.disabled')
}
