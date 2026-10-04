# Windows notifications for background runs (autostart): a toast in Windows PowerShell, otherwise a
# balloon tip from the notification area. Notifications never throw - they are a convenience.

$script:CdPowerShellAppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'

function ConvertTo-CdXmlText {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    [Security.SecurityElement]::Escape([string]$Text)
}

function Get-CdToastXml {
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Message)
    "<toast><visual><binding template=`"ToastGeneric`"><text>$(ConvertTo-CdXmlText $Title)</text><text>$(ConvertTo-CdXmlText $Message)</text></binding></visual></toast>"
}

function Show-CdNotification {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')][string]$Kind = 'Info'
    )
    try {
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
            [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
            $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
            $xml.LoadXml((Get-CdToastXml -Title $Title -Message $Message))
            $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
            [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($script:CdPowerShellAppId).Show($toast)
            return $true
        }
    }
    catch { Write-CdLog -Level DEBUG -Component 'Notify' -Message "Toast failed, using balloon tip: $($_.Exception.Message)" }
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $icon = New-Object System.Windows.Forms.NotifyIcon
        $icon.Icon = [System.Drawing.SystemIcons]::Information
        $icon.BalloonTipTitle = $Title
        $icon.BalloonTipText = $Message
        $icon.BalloonTipIcon = $Kind
        $icon.Visible = $true
        $icon.ShowBalloonTip(10000)
        Start-Sleep -Seconds 6
        $icon.Dispose()
        return $true
    }
    catch {
        Write-CdLog -Level WARN -Component 'Notify' -Message "Notification failed: $($_.Exception.Message)"
        return $false
    }
}

function Send-CdConnectSummary {
    # Notifies about the outcome of a background connect, honouring the "notifications" setting.
    param([object[]]$Results)
    $mode = [string](Get-CdSettings).notifications
    if ($mode -eq 'off' -or -not $Results) { return }
    $failed = @($Results | Where-Object { -not $_.Success })
    if ($failed.Count -eq 0) {
        if ($mode -ne 'all') { return }
        $letters = (@($Results | Where-Object { $_.Data -and $_.Data.letter } | ForEach-Object { "$($_.Data.letter):" }) -join ', ')
        [void](Show-CdNotification -Title 'CloudDrives' -Message (Get-CdText 'notify.connected' $letters))
        return
    }
    $lines = foreach ($item in $failed) { '{0} - {1}' -f $item.Message, (Get-CdText "error.$($item.Code).title") }
    # An expired sign-in needs the user; say where to renew it.
    $hint = Get-CdText 'notify.openHint'
    $signInExpired = @($failed | Where-Object { $entry = Get-CdErrorEntry -Code ([string]$_.Code); $entry -and $entry.action -eq 'reconnect-account' })
    if ($signInExpired.Count -gt 0) { $hint = Get-CdText 'notify.reloginHint' }
    [void](Show-CdNotification -Title (Get-CdText 'notify.problemTitle') -Message ((@($lines) -join "`n") + "`n" + $hint) -Kind 'Warning')
}
