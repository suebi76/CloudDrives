# Console rendering and input helpers. This layer is the only place that talks to the user.

$script:CdRuleChar = [char]0x2500
$script:CdDotOn = [string][char]0x25CF
$script:CdDotOff = [string][char]0x25CB
$script:CdCheck = [string][char]0x2713
$script:CdCross = [string][char]0x2717
# The status line of a long operation (Write-CdProgress) and the length it was last drawn with.
$script:CdProgress = $null
$script:CdLiveLength = 0

function Initialize-CdConsole {
    try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { Write-CdLog -Level DEBUG -Component 'UI' -Message 'Console encoding could not be set.' }
    try { $Host.UI.RawUI.WindowTitle = 'CloudDrives' } catch { Write-CdLog -Level DEBUG -Component 'UI' -Message 'Window title could not be set.' }
}

function Test-CdSingleKeyInput {
    try { return ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected) } catch { return $false }
}

function Write-CdRule {
    Complete-CdProgress
    Write-Host ('  ' + [string]::new($script:CdRuleChar, 66)) -ForegroundColor DarkGray
}

function Write-CdHeader {
    param([string]$Subtitle)
    Complete-CdProgress
    Write-Host ''
    Write-Host ('  CloudDrives ' + (Get-CdContext).Version) -ForegroundColor Cyan -NoNewline
    if ($Subtitle) { Write-Host ('   ' + $Subtitle) -ForegroundColor Gray }
    else { Write-Host '' }
    Write-CdRule
}

function Write-CdInfo {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    Complete-CdProgress
    foreach ($line in ($Text -split "`n")) { Write-Host ('  ' + $line.TrimEnd("`r")) -ForegroundColor $Color }
}

function Write-CdStep {
    param([string]$Text)
    Complete-CdProgress
    Write-Host ''
    Write-Host ('  ' + $Text) -ForegroundColor White
}

function Write-CdOk {
    param([string]$Text)
    Complete-CdProgress
    Write-Host ('  ' + $script:CdCheck + ' ') -ForegroundColor Green -NoNewline
    Write-Host $Text
}

function Write-CdFail {
    param([string]$Text)
    Complete-CdProgress
    Write-Host ('  ' + $script:CdCross + ' ') -ForegroundColor Red -NoNewline
    Write-Host $Text
}

function Test-CdLiveConsole {
    # True when the output goes to a console window that can redraw a line (not redirected into a file or pipe).
    try { return ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected) } catch { return $false }
}

function Format-CdElapsed {
    # "12 s" below a minute, "1:05 min" from a minute on.
    param([TimeSpan]$Elapsed)
    $seconds = [int][Math]::Floor($Elapsed.TotalSeconds)
    if ($seconds -lt 60) { return "$seconds s" }
    '{0}:{1:00} min' -f [int][Math]::Floor($seconds / 60), ($seconds % 60)
}

function Test-CdStatusLineNative {
    # The status line that redraws itself comes with the native helpers (not with an older copy of them that this
    # process may have loaded before an update).
    if (-not (Initialize-CdNative)) { return $false }
    [bool]('CloudDrives.Native.StatusLine' -as [type])
}

function Write-CdProgress {
    # Status line of a long operation: the current step, a turning bar and how long the step has taken so far, so
    # it is visible that CloudDrives is still working. A text starts a new step. The native line redraws itself, also
    # while CloudDrives waits for a blocking call; without it, a call without text redraws the line. Without a
    # console window that can redraw a line, each step is written as a line of its own. Any other output and every
    # question remove the line first (Complete-CdProgress).
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $live = Test-CdLiveConsole
    if ($Text) {
        if (-not $live) { Write-CdInfo -Text $Text -Color DarkGray; return }
        if (Test-CdStatusLineNative) {
            [CloudDrives.Native.StatusLine]::Show($Text)
            $script:CdProgress = @{ Native = $true }
            return
        }
        $script:CdProgress = @{ Native = $false; Text = $Text; Watch = [Diagnostics.Stopwatch]::StartNew(); Frame = 0 }
    }
    $progress = $script:CdProgress
    if (-not $progress -or $progress.Native -or -not $live) { return }
    $bar = @('|', '/', '-', '\')[$progress.Frame % 4]
    $progress.Frame++
    # The time appears from the first second on; a short step shows none instead of a "0 s" that never changes.
    $line = '  {0} {1}' -f $bar, $progress.Text
    if ($progress.Watch.Elapsed.TotalSeconds -ge 1) { $line += ' ' + (Format-CdElapsed -Elapsed $progress.Watch.Elapsed) }
    $width = 80
    try { $width = [Console]::WindowWidth } catch { $width = 80 }
    if ($line.Length -ge $width) { $line = $line.Substring(0, [Math]::Max(1, $width - 1)) }
    $padding = ' ' * [Math]::Max(0, $script:CdLiveLength - $line.Length)
    Write-Host ("`r" + $line + $padding) -NoNewline -ForegroundColor Cyan
    $script:CdLiveLength = $line.Length
}

function Complete-CdProgress {
    # Removes the status line, so whatever follows is written where it stood.
    $progress = $script:CdProgress
    if (-not $progress) { return }
    $script:CdProgress = $null
    if ($progress.Native) { [CloudDrives.Native.StatusLine]::Clear() }
    elseif ($script:CdLiveLength -gt 0 -and (Test-CdLiveConsole)) { Write-Host ("`r" + (' ' * $script:CdLiveLength) + "`r") -NoNewline }
    $script:CdLiveLength = 0
}

function Format-CdShort {
    param([AllowNull()][string]$Text, [int]$Length)
    if ($null -eq $Text) { $Text = '' }
    if ($Text.Length -le $Length) { return $Text.PadRight($Length) }
    $Text.Substring(0, $Length - 1) + [char]0x2026
}

function Write-CdErrorInfo {
    param([Parameter(Mandatory)][object]$Info)
    Complete-CdProgress
    Write-Host ''
    Write-Host ('  ' + $Info.Code + '  ' + $Info.Title) -ForegroundColor Red
    if ($Info.Fix -and -not $Info.Fix.StartsWith('[')) { Write-CdInfo -Text $Info.Fix -Color Yellow }
    if ($Info.Detail) { Write-CdInfo -Text ((Get-CdText 'ui.detail') + ': ' + (Format-CdShort -Text $Info.Detail -Length 400).TrimEnd()) -Color DarkGray }
}

function Write-CdResult {
    # Renders one command result (success with a check mark, failure with code and hint).
    param([Parameter(Mandatory)][object]$Result)
    if ($Result.Success) { Write-CdOk -Text $Result.Message; return }
    Write-CdFail -Text $Result.Message
    if ($Result.Code -and $Result.Code -ne 'CD-4006') {
        $title = Get-CdText "error.$($Result.Code).title"
        $fix = Get-CdText "error.$($Result.Code).fix"
        Write-Host ('      ' + $Result.Code + ': ' + $title) -ForegroundColor Red
        if (-not $fix.StartsWith('[')) { Write-Host ('      ' + $fix) -ForegroundColor Yellow }
    }
}

function Write-CdStatusTable {
    param([object[]]$StatusList)
    Complete-CdProgress
    if (-not $StatusList -or $StatusList.Count -eq 0) {
        Write-CdInfo -Text (Get-CdText 'status.noDrives')
        return
    }
    foreach ($status in $StatusList) {
        $dot = $script:CdDotOff
        $color = [ConsoleColor]::DarkGray
        $stateText = Get-CdText 'status.disconnected'
        if ($status.Mounted) {
            $dot = $script:CdDotOn
            $color = [ConsoleColor]::Green
            $stateText = Get-CdText 'status.connected'
        }
        $name = $status.Drive.label
        if ($status.Drive.encrypted) { $name = $name + ' ' + (Get-CdText 'status.encryptedTag') }
        Write-Host ('  ' + $dot + ' ') -ForegroundColor $color -NoNewline
        Write-Host (($status.MountPoint.PadRight(4)) + (Format-CdShort -Text $name -Length 28) + ' ') -NoNewline
        Write-Host ($stateText.PadRight(12)) -ForegroundColor $color -NoNewline
        $extra = ''
        if ($status.Quota -and $null -ne $status.Quota.used) {
            if ($status.Quota.total) { $extra = Get-CdText 'status.quota' (Format-CdSize $status.Quota.used), (Format-CdSize $status.Quota.total) }
            else { $extra = Get-CdText 'status.quotaUsed' (Format-CdSize $status.Quota.used) }
        }
        Write-Host $extra -NoNewline -ForegroundColor Gray
        if ($status.PendingUploads -gt 0) { Write-Host ('  ' + (Get-CdText 'status.pending' $status.PendingUploads)) -ForegroundColor Yellow -NoNewline }
        Write-Host ''
    }
}

function Read-CdChoice {
    # Single-key choice in a real console, line input elsewhere. Esc maps to "0" when "0" is valid.
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string[]]$Valid,
        [string]$Default
    )
    Complete-CdProgress
    while ($true) {
        Write-Host ''
        Write-Host ('  ' + $Prompt + ' ') -ForegroundColor White -NoNewline
        $answer = ''
        if (Test-CdSingleKeyInput) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Escape) { $answer = 'ESC' }
            elseif ($key.Key -eq [ConsoleKey]::Enter) { $answer = $Default }
            else { $answer = [string]$key.KeyChar }
            Write-Host $answer
        }
        else {
            $answer = Read-Host
            if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
        }
        if ($answer -eq 'ESC' -and $Valid -contains '0') { return '0' }
        foreach ($option in $Valid) { if ($answer -and $option -ieq $answer.Trim()) { return $option } }
        Write-Host ('  ' + (Get-CdText 'ui.invalidChoice')) -ForegroundColor Yellow
    }
}

function Read-CdText {
    param([Parameter(Mandatory)][string]$Prompt, [string]$Default)
    Complete-CdProgress
    Write-Host ''
    Write-Host ('  ' + $Prompt) -ForegroundColor White -NoNewline
    if ($Default) { Write-Host (' [' + $Default + ']') -ForegroundColor DarkGray -NoNewline }
    Write-Host ': ' -NoNewline
    $answer = Read-Host
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    $answer.Trim()
}

function Read-CdSecretText {
    param([Parameter(Mandatory)][string]$Prompt)
    Complete-CdProgress
    Write-Host ''
    Write-Host ('  ' + $Prompt + ': ') -ForegroundColor White -NoNewline
    $secure = Read-Host -AsSecureString
    (New-Object System.Management.Automation.PSCredential('clouddrives', $secure)).GetNetworkCredential().Password
}

function Read-CdSecureText {
    # Hidden input that stays a SecureString, e.g. a password that goes on to rclone.
    param([Parameter(Mandatory)][string]$Prompt)
    Complete-CdProgress
    Write-Host ''
    Write-Host ('  ' + $Prompt + ': ') -ForegroundColor White -NoNewline
    Read-Host -AsSecureString
}

function Read-CdYesNo {
    param([Parameter(Mandatory)][string]$Prompt, [bool]$Default = $true)
    $yes = Get-CdText 'ui.yesKey'
    $no = Get-CdText 'ui.noKey'
    $hint = "$($yes.ToUpper())/$no"
    $defaultKey = $yes
    if (-not $Default) { $hint = "$yes/$($no.ToUpper())"; $defaultKey = $no }
    $answer = Read-CdChoice -Prompt "$Prompt ($hint)" -Valid @($yes, $no, '0') -Default $defaultKey
    $answer -ieq $yes
}

function Wait-CdKeyPress {
    Complete-CdProgress
    Write-Host ''
    Write-Host ('  ' + (Get-CdText 'ui.pressAnyKey')) -ForegroundColor DarkGray -NoNewline
    if (Test-CdSingleKeyInput) { [void][Console]::ReadKey($true) } else { [void](Read-Host) }
    Write-Host ''
}

function Test-CdEscapePressed {
    if (-not (Test-CdSingleKeyInput)) { return $false }
    try {
        while ([Console]::KeyAvailable) {
            if ([Console]::ReadKey($true).Key -eq [ConsoleKey]::Escape) { return $true }
        }
    }
    catch { return $false }
    $false
}

function Clear-CdScreen {
    Complete-CdProgress
    try { Clear-Host } catch { Write-Host '' }
}
