# The status line of long operations (connecting, disconnecting, signing in, diagnosis, update): how it is drawn,
# that any other output and every question remove it first, and what the operations report.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome
    Import-CdModuleForTest
    InModuleScope CloudDrives { Initialize-CdHome }
}

AfterAll {
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'Status line' {
    AfterEach {
        InModuleScope CloudDrives {
            Complete-CdProgress
            if (Test-CdStatusLineNative) { [CloudDrives.Native.StatusLine]::Clear() }
        }
    }

    It 'shows seconds, and minutes from a minute on' {
        InModuleScope CloudDrives {
            Test-CdStatusLineNative | Should -BeTrue
            Format-CdElapsed -Elapsed ([TimeSpan]::FromSeconds(5.7)) | Should -Be '5 s'
            Format-CdElapsed -Elapsed ([TimeSpan]::FromSeconds(65)) | Should -Be '1:05 min'
            [CloudDrives.Native.StatusLine]::FormatElapsed([TimeSpan]::FromSeconds(5.7)) | Should -Be '5 s'
            [CloudDrives.Native.StatusLine]::FormatElapsed([TimeSpan]::FromSeconds(125)) | Should -Be '2:05 min'
        }
    }

    It 'draws a frame: bar, text, the time from the first second on, cut to the window width' {
        InModuleScope CloudDrives {
            Test-CdStatusLineNative | Should -BeTrue
            [CloudDrives.Native.StatusLine]::Render('Verbinde M: …', 0, [TimeSpan]::FromMilliseconds(300), 80) | Should -Be '  | Verbinde M: …'
            [CloudDrives.Native.StatusLine]::Render('Verbinde M: …', 1, [TimeSpan]::FromSeconds(3), 80) | Should -Be '  / Verbinde M: … 3 s'
            [CloudDrives.Native.StatusLine]::Render('Verbinde M: …', 3, [TimeSpan]::FromSeconds(3), 80) | Should -Be '  \ Verbinde M: … 3 s'
            [CloudDrives.Native.StatusLine]::Render(('x' * 100), 0, [TimeSpan]::Zero, 40).Length | Should -Be 39
        }
    }

    It 'redraws itself in a console window until the next output removes it' {
        InModuleScope CloudDrives {
            Mock Test-CdLiveConsole { $true }
            Mock Write-Host { }
            Write-CdProgress -Text 'Verbinde M: …'
            [CloudDrives.Native.StatusLine]::Visible | Should -BeTrue
            Write-CdProgress -Text 'Lese den Speicherplatz …'
            [CloudDrives.Native.StatusLine]::Visible | Should -BeTrue
            Write-CdInfo -Text 'done'
            [CloudDrives.Native.StatusLine]::Visible | Should -BeFalse
            Should -Invoke Write-Host -Times 1 -Exactly
        }
    }

    # The actions are text: as script blocks they would run outside the module and not see its functions.
    It 'is removed before <Name>' -ForEach @(
        @{ Name = 'a question'; Action = "[void](Read-CdText -Prompt 'Letter')" }
        @{ Name = 'a yes/no question'; Action = "[void](Read-CdYesNo -Prompt 'Connect?')" }
        @{ Name = 'a secret'; Action = "[void](Read-CdSecretText -Prompt 'Password')" }
        @{ Name = 'waiting for a key'; Action = 'Wait-CdKeyPress' }
        @{ Name = 'a result'; Action = "Write-CdResult -Result (New-CdResult -Message 'ok')" }
        @{ Name = 'an error'; Action = "Write-CdErrorInfo -Info ([pscustomobject]@{ Code = 'CD-3011'; Title = 't'; Fix = 'f'; Detail = '' })" }
        @{ Name = 'a new screen'; Action = 'Clear-CdScreen' }
    ) {
        InModuleScope CloudDrives -Parameters @{ Action = $Action } {
            Mock Test-CdLiveConsole { $true }
            Mock Test-CdSingleKeyInput { $false }
            Mock Write-Host { }
            # Answers in the current language; a secret comes as SecureString.
            Mock Read-Host {
                if ($AsSecureString) { $secret = New-Object System.Security.SecureString; $secret.AppendChar('x'); return $secret }
                Get-CdText 'ui.yesKey'
            }
            Mock Clear-Host { }
            Write-CdProgress -Text 'Verbinde M: …'
            [CloudDrives.Native.StatusLine]::Visible | Should -BeTrue
            & ([scriptblock]::Create($Action))
            [CloudDrives.Native.StatusLine]::Visible | Should -BeFalse
        }
    }

    It 'redraws one line on each call where the native line is not available' {
        InModuleScope CloudDrives {
            $script:TestHost = New-Object System.Collections.Generic.List[string]
            Mock Test-CdLiveConsole { $true }
            Mock Test-CdStatusLineNative { $false }
            Mock Write-Host { $script:TestHost.Add([string]$Object) }
            Write-CdProgress -Text 'Step one'
            Write-CdProgress
            Write-CdProgress -Text 'Two'
            $script:TestHost.Count | Should -Be 3
            foreach ($line in $script:TestHost) { $line | Should -Match '^\r  [|/\\-] ' }
            $script:TestHost[0] | Should -Match 'Step one'
            # A shorter text overwrites the rest of the longer one.
            $script:TestHost[2] | Should -Match 'Two\s{5,}$'
            Complete-CdProgress
            $script:TestHost[3] | Should -Match '^\r\s+\r$'
            Write-CdProgress
            $script:TestHost.Count | Should -Be 4
        }
    }

    It 'writes each step as a line of its own where a line cannot be redrawn' {
        InModuleScope CloudDrives {
            Mock Test-CdLiveConsole { $false }
            Mock Write-CdInfo { }
            Mock Write-Host { }
            Write-CdProgress -Text 'Step one'
            Write-CdProgress
            Write-CdProgress
            Write-CdProgress -Text 'Step two'
            Complete-CdProgress
            Should -Invoke Write-CdInfo -Times 2 -Exactly
            Should -Invoke Write-Host -Times 0 -Exactly
            [CloudDrives.Native.StatusLine]::Visible | Should -BeFalse
        }
    }
}

Describe 'Progress of connecting and disconnecting' {
    BeforeEach {
        InModuleScope CloudDrives {
            $settings = Get-CdSettings
            $settings.accounts = @(
                [ordered]@{ id = 'gw'; provider = 'drive'; kind = 'workspace'; label = 'Schule'; clientId = 'own' }
                [ordered]@{ id = 'od'; provider = 'onedrive'; kind = 'personal'; label = 'OneDrive' }
            )
            $settings.drives = @(
                [ordered]@{ id = 'gw'; account = 'gw'; label = 'Schule'; letter = 'I'; path = ''; encrypted = $false; autoConnect = $true; readOnly = $false }
                [ordered]@{ id = 'od'; account = 'od'; label = 'OneDrive'; letter = 'M'; path = ''; encrypted = $false; autoConnect = $true; readOnly = $false }
            )
            Save-CdSettings -Settings $settings
            $script:TestProgress = New-Object System.Collections.Generic.List[string]
            $script:TestOnProgress = { param([string]$Status) $script:TestProgress.Add($Status) }
            Mock Test-CdInternet { $true }
            Mock Test-CdEngineRunning { $false }
            Mock Start-CdEngine { }
            Mock Mount-CdDrive { New-CdResult -Message "$($Drive.letter): connected" -Data $Drive }
            Mock Update-CdAccountIdentities { }
            Mock Start-Sleep { }
        }
    }

    It 'names the engine start and each drive while connecting' {
        InModuleScope CloudDrives {
            [void](Invoke-CdConnect -Selection @('all') -OnProgress $script:TestOnProgress)
            $script:TestProgress.ToArray() | Should -Be @(
                (Get-CdText 'progress.engine'), (Get-CdText 'progress.connect' 'Schule (I:)'), (Get-CdText 'progress.connect' 'OneDrive (M:)'))
        }
    }

    It 'says so once when it has to wait for the network' {
        InModuleScope CloudDrives {
            $script:TestOnline = 0
            Mock Test-CdInternet { $script:TestOnline++; $script:TestOnline -gt 2 }
            Mock Test-CdEngineRunning { $true }
            [void](Invoke-CdConnect -Selection @('gw') -OnProgress $script:TestOnProgress)
            $script:TestProgress.ToArray() | Should -Be @((Get-CdText 'progress.network'), (Get-CdText 'progress.connect' 'Schule (I:)'))
        }
    }

    It 'names each drive while disconnecting' {
        InModuleScope CloudDrives {
            Mock Test-CdEngineRunning { $true }
            Mock Dismount-CdDrive { New-CdResult -Message 'disconnected' -Data $Drive }
            Mock Get-CdMountedDrives { @{} }
            Mock Stop-CdEngine { }
            [void](Invoke-CdDisconnect -Selection @('od') -OnProgress $script:TestOnProgress)
            $script:TestProgress.ToArray() | Should -Be @((Get-CdText 'progress.disconnect' 'OneDrive (M:)'))
        }
    }

    It 'works without a progress display' {
        InModuleScope CloudDrives {
            @(Invoke-CdConnect -Selection @('od')).Count | Should -Be 1
        }
    }
}
