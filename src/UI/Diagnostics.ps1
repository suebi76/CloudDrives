# Console screens for the diagnosis ("Diagnose & Hilfe") and the support bundle.

# Order in which automatic fixes run: components and engine first, then drives, sign-ins last.
$script:CdFixOrder = @('install-winfsp', 'install-rclone', 'protect-home', 'restart-engine', 'connect', 'labels', 'enable-autostart', 'enable-watchdog', 'relogin', 'change-client')

function Get-CdCheckStyle {
    param([string]$Status)
    switch ($Status) {
        'ok' { return @{ Symbol = $script:CdCheck; Color = [ConsoleColor]::Green } }
        'warn' { return @{ Symbol = '!'; Color = [ConsoleColor]::Yellow } }
        'fail' { return @{ Symbol = $script:CdCross; Color = [ConsoleColor]::Red } }
        'skip' { return @{ Symbol = '-'; Color = [ConsoleColor]::DarkGray } }
        default { return @{ Symbol = 'i'; Color = [ConsoleColor]::Cyan } }
    }
}

function Show-CdDoctorReport {
    # Traffic-light list grouped by area; problems also show how to solve them.
    param([AllowEmptyCollection()][object[]]$Checks = @())
    $area = $null
    foreach ($check in $Checks) {
        if ($check.Area -ne $area) {
            $area = $check.Area
            Write-CdStep -Text (Get-CdText "doctor.area.$area")
        }
        $style = Get-CdCheckStyle -Status $check.Status
        Write-Host ('  ' + $style.Symbol + ' ') -ForegroundColor $style.Color -NoNewline
        Write-Host ($check.Name + ': ') -ForegroundColor White -NoNewline
        $message = [string]$check.Message
        if ($check.Code) { $message += " ($($check.Code))" }
        Write-Host $message -ForegroundColor Gray
        if ($check.Code -and @('warn', 'fail') -contains $check.Status) {
            $fix = Get-CdText "error.$($check.Code).fix"
            if ($fix -and -not $fix.StartsWith('[')) {
                foreach ($line in ($fix -split "`n")) { Write-Host ('      ' + $line.TrimEnd("`r")) -ForegroundColor DarkYellow }
            }
        }
    }
    $summary = Get-CdDoctorSummary -Checks $Checks
    Write-Host ''
    if ($summary.Fail -eq 0 -and $summary.Warn -eq 0) { Write-CdOk -Text (Get-CdText 'doctor.summaryOk') }
    else { Write-CdInfo -Text (Get-CdText 'doctor.summary' $summary.Fail, $summary.Warn) -Color Yellow }
}

function Invoke-CdDoctorChecksUi {
    # Runs the diagnosis with a progress line per area.
    Write-CdInfo -Text (Get-CdText 'doctor.running') -Color DarkGray
    @(Invoke-CdDoctor -OnArea { param($Area) Write-Host ('    ' + (Get-CdText "doctor.area.$Area") + ' ...') -ForegroundColor DarkGray })
}

function Invoke-CdDoctorFixesUi {
    # Carries out all automatic fixes; sign-in problems open the sign-in assistant.
    param([object[]]$Checks)
    $ordered = @($Checks | Sort-Object -Property @{ Expression = { [array]::IndexOf($script:CdFixOrder, [string]$_.Fix) } })
    $done = @{}
    foreach ($check in $ordered) {
        $key = '{0}|{1}' -f $check.Fix, $check.Target
        if ($done.ContainsKey($key)) { continue }
        $done[$key] = $true
        Write-CdStep -Text (Get-CdText 'doctor.fixing' $check.Name, $check.Message)
        if (Test-CdFixInteractive -Fix $check.Fix) {
            $account = Get-CdAccount -Id $check.Target
            if ($account) { [void](Start-CdReloginWizard -Account $account -ChangeClient:($check.Fix -eq 'change-client') -Embedded) }
            continue
        }
        try { foreach ($result in @(Invoke-CdDoctorFix -Check $check)) { if ($result) { Write-CdResult -Result $result } } }
        catch { Write-CdErrorInfo -Info (Get-CdErrorInfo $_) }
    }
}

function Start-CdSupportBundleUi {
    param([object[]]$Checks)
    Write-CdStep -Text (Get-CdText 'support.title')
    Write-CdInfo -Text (Get-CdText 'support.explain') -Color DarkGray
    if (-not (Read-CdYesNo -Prompt (Get-CdText 'support.confirm') -Default $true)) { return }
    Write-CdInfo -Text (Get-CdText 'support.creating') -Color DarkGray
    try {
        $result = New-CdSupportBundle -Checks $Checks
        Write-CdResult -Result $result
        if (Read-CdYesNo -Prompt (Get-CdText 'support.openFolder') -Default $true) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $result.Data.Path)
        }
    }
    catch { Write-CdErrorInfo -Info (Get-CdErrorInfo $_) }
    Wait-CdKeyPress
}

function Start-CdDoctorUi {
    $checks = $null
    while ($true) {
        Clear-CdScreen
        Write-CdHeader -Subtitle (Get-CdText 'doctor.title')
        if (-not $checks) {
            $checks = Invoke-CdDoctorChecksUi
            Clear-CdScreen
            Write-CdHeader -Subtitle (Get-CdText 'doctor.title')
        }
        Show-CdDoctorReport -Checks $checks
        $summary = Get-CdDoctorSummary -Checks $checks
        Write-Host ''
        $valid = @('2', '3', '4', '0')
        if ($summary.Fixable.Count -gt 0) {
            Write-CdInfo -Text ('[1] ' + (Get-CdText 'doctor.fixAll' $summary.Fixable.Count)) -Color White
            $valid += '1'
        }
        Write-CdInfo -Text ('[2] ' + (Get-CdText 'doctor.bundle')) -Color White
        Write-CdInfo -Text ('[3] ' + (Get-CdText 'menu.openLogs')) -Color White
        Write-CdInfo -Text ('[4] ' + (Get-CdText 'doctor.again')) -Color White
        Write-CdInfo -Text ('[0] ' + (Get-CdText 'manage.back')) -Color White
        switch (Read-CdChoice -Prompt (Get-CdText 'ui.choose') -Valid $valid) {
            '1' {
                Invoke-CdDoctorFixesUi -Checks $summary.Fixable
                Wait-CdKeyPress
                $checks = $null
            }
            '2' { Start-CdSupportBundleUi -Checks $checks }
            '3' { Start-Process -FilePath 'explorer.exe' -ArgumentList @((Get-CdContext).LogDir) }
            '4' { $checks = $null }
            '0' { return }
        }
    }
}
