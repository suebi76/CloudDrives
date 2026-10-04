# The CloudDrives symbol in the notification area: a status dot (green = connected, yellow = reconnecting,
# red = needs attention, grey = nothing connected), the drives, connect/disconnect, the menu and the diagnosis.
# Deliberately lean: actions run as separate CloudDrives processes, so the symbol itself never blocks.

$script:CdTrayColors = @{ ok = '#22C55E'; warn = '#F59E0B'; error = '#EF4444'; idle = '#9CA3AF' }

function New-CdTrayIcons {
    # The app icon with a coloured dot, one per level, in the size Windows uses for the notification area.
    Add-Type -AssemblyName System.Drawing, System.Windows.Forms
    $size = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
    $source = Join-Path (Get-CdContext).ResourcesDir 'icons\clouddrives.ico'
    $icons = @{}
    foreach ($level in @($script:CdTrayColors.Keys)) {
        $bitmap = [System.Drawing.Bitmap]::new($size, $size)
        $g = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $base = [System.Drawing.Icon]::new($source, $size, $size)
            try { $g.DrawIcon($base, [System.Drawing.Rectangle]::new(0, 0, $size, $size)) } finally { $base.Dispose() }
            $dot = [Math]::Max(6, [int][Math]::Round($size * 0.5))
            $ring = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
            $fill = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml($script:CdTrayColors[$level]))
            try {
                $g.FillEllipse($ring, $size - $dot, $size - $dot, $dot, $dot)
                $g.FillEllipse($fill, $size - $dot + 1, $size - $dot + 1, $dot - 2, $dot - 2)
            }
            finally {
                $ring.Dispose()
                $fill.Dispose()
            }
        }
        finally { $g.Dispose() }
        $icons[$level] = [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
        $bitmap.Dispose()
    }
    $icons
}

function Start-CdTrayAction {
    # Runs a CloudDrives command as its own process: hidden for background work, in a window for the menu.
    param([AllowEmptyCollection()][string[]]$Arguments = @(), [switch]$Visible)
    $ctx = Get-CdContext
    if ($Visible) {
        $all = @($Arguments)
        if (-not $ctx.IsDefaultHome) { $all += "--home=$($ctx.Home)" }
        $parameters = @{ FilePath = (Join-Path $ctx.AppRoot 'CloudDrives.bat'); WorkingDirectory = (Get-CdNeutralDirectory) }
        if ($all.Count -gt 0) { $parameters.ArgumentList = ConvertTo-CdArgumentString -ArgumentList $all }
        Start-Process @parameters
        return
    }
    $command = Get-CdAutostartCommand -Command $Arguments
    [void](Start-CdDetachedProcess -FilePath $command.Execute -RawArguments $command.Arguments -WorkingDirectory $command.WorkingDirectory)
    # Show the outcome soon instead of after the regular interval.
    $script:CdTrayTicks = 6
}

function Add-CdTrayMenuItem {
    param([Parameter(Mandatory)][System.Windows.Forms.ContextMenuStrip]$Menu, [Parameter(Mandatory)][string]$Text, [scriptblock]$OnClick, [object]$Tag, [bool]$Enabled = $true)
    $item = New-Object System.Windows.Forms.ToolStripMenuItem($Text)
    $item.Tag = $Tag
    $item.Enabled = $Enabled
    if ($OnClick) { $item.add_Click($OnClick) }
    [void]$Menu.Items.Add($item)
    $item
}

function Update-CdTray {
    # Refreshes symbol, tooltip and menu. The menu is only rebuilt when something changed and it is closed.
    $state = Get-CdTrayState
    $notify = $script:CdTrayNotify
    $notify.Icon = $script:CdTrayIcons[$state.Level]
    $tip = 'CloudDrives - ' + $state.Text
    # Windows Forms rejects tooltips longer than 63 characters.
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 62) + [char]0x2026 }
    $notify.Text = $tip

    $signature = $state.Level + '|' + $state.Text + '|' + ((@($state.Drives) | ForEach-Object { '{0}{1}{2}' -f $_.Letter, $_.Connected, $_.Problem }) -join ',')
    $menu = $notify.ContextMenuStrip
    if ($signature -eq $script:CdTraySignature -or $menu.Visible) { return }
    $script:CdTraySignature = $signature

    $menu.Items.Clear()
    [void](Add-CdTrayMenuItem -Menu $menu -Text $state.Text -Enabled $false)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    foreach ($drive in @($state.Drives)) {
        $text = '{0}  {1}' -f $drive.Letter, $drive.Label
        if (-not $drive.Connected) { $text += '  (' + (Get-CdText 'tray.notConnected') + ')' }
        [void](Add-CdTrayMenuItem -Menu $menu -Text $text -Tag "$($drive.Letter)\" -Enabled $drive.Connected -OnClick { Start-Process -FilePath 'explorer.exe' -ArgumentList @([string]$this.Tag) })
    }
    foreach ($accountId in @($state.ReloginAccounts)) {
        $account = Get-CdAccount -Id $accountId
        if ($account) { [void](Add-CdTrayMenuItem -Menu $menu -Text (Get-CdText 'tray.relogin' $account.label) -Tag $accountId -OnClick { Start-CdTrayAction -Arguments @('relogin', [string]$this.Tag) -Visible }) }
    }
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void](Add-CdTrayMenuItem -Menu $menu -Text (Get-CdText 'tray.connectAll') -OnClick { Start-CdTrayAction -Arguments @('connect', 'all', '--silent') })
    [void](Add-CdTrayMenuItem -Menu $menu -Text (Get-CdText 'tray.disconnectAll') -OnClick { Start-CdTrayAction -Arguments @('disconnect') })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void](Add-CdTrayMenuItem -Menu $menu -Text (Get-CdText 'tray.open') -OnClick { Start-CdTrayAction -Visible })
    [void](Add-CdTrayMenuItem -Menu $menu -Text (Get-CdText 'tray.diagnose') -OnClick { Start-CdTrayAction -Arguments @('doctor', '--pause') -Visible })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void](Add-CdTrayMenuItem -Menu $menu -Text (Get-CdText 'tray.hide') -OnClick { $script:CdTrayContext.ExitThread() })
}

function Start-CdTray {
    # Shows the symbol until "hide" is chosen or the symbol is switched off. One per user and data folder.
    $created = $false
    $single = New-Object System.Threading.Mutex($true, (Get-CdTrayMutexName), [ref]$created)
    if (-not $created) {
        $single.Dispose()
        Write-CdLog -Level DEBUG -Component 'Tray' -Message 'The symbol is already shown.'
        return 0
    }
    $exit = Get-CdTrayExitEvent
    [void]$exit.Reset()
    $timer = $null
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        [System.Windows.Forms.Application]::EnableVisualStyles()
        $script:CdTrayIcons = New-CdTrayIcons
        $script:CdTraySignature = $null
        $script:CdTrayTicks = 0
        $script:CdTrayExit = $exit
        $script:CdTrayContext = New-Object System.Windows.Forms.ApplicationContext
        $script:CdTrayNotify = New-Object System.Windows.Forms.NotifyIcon
        $script:CdTrayNotify.Icon = $script:CdTrayIcons['idle']
        $script:CdTrayNotify.Text = 'CloudDrives'
        $script:CdTrayNotify.ContextMenuStrip = New-Object System.Windows.Forms.ContextMenuStrip
        $script:CdTrayNotify.add_DoubleClick({ Start-CdTrayAction -Visible })

        # One tick per second: react quickly to the exit signal, refresh the status every 10 seconds.
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 1000
        $timer.add_Tick({
                try {
                    if ($script:CdTrayExit.WaitOne(0)) {
                        $script:CdTrayContext.ExitThread()
                        return
                    }
                    $script:CdTrayTicks++
                    if ($script:CdTrayTicks -ge 10) {
                        $script:CdTrayTicks = 0
                        Update-CdTray
                    }
                }
                catch { Write-CdLog -Level WARN -Component 'Tray' -Message "Refresh failed: $($_.Exception.Message)" }
            })
        $script:CdTrayNotify.Visible = $true
        Update-CdTray
        $timer.Start()
        Write-CdLog -Component 'Tray' -Message 'Symbol shown.'
        [System.Windows.Forms.Application]::Run($script:CdTrayContext)
    }
    finally {
        if ($timer) {
            $timer.Stop()
            $timer.Dispose()
        }
        if ($script:CdTrayNotify) {
            $script:CdTrayNotify.Visible = $false
            $script:CdTrayNotify.Dispose()
            $script:CdTrayNotify = $null
        }
        $exit.Dispose()
        $single.ReleaseMutex()
        $single.Dispose()
        Write-CdLog -Component 'Tray' -Message 'Symbol closed.'
    }
    0
}
