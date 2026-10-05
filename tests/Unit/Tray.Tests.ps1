# Tray symbol: the status it shows, the icons, how actions are started, the diagnosis and the command line.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome
    Import-CdModuleForTest
    InModuleScope CloudDrives { Initialize-CdHome }
}

AfterAll {
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'Tray symbol' {
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
            foreach ($file in @((Get-CdWantedStateFile), (Get-CdWatchdogStateFile))) {
                if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
            }
            Mock Get-CdLastBootTime { (Get-Date).AddHours(-1) }
            Mock Test-CdEngineRunning { $true }
            Mock Get-CdMountedDrives { @{} }
        }
    }

    Context 'Status' {
        It 'is grey when nothing is connected' {
            InModuleScope CloudDrives {
                $state = Get-CdTrayState
                $state.Level | Should -Be 'idle'
                $state.Text | Should -Be (Get-CdText 'tray.idle')
                @($state.Drives).Count | Should -Be 2
            }
        }

        It 'is green when the wanted drives are connected' {
            InModuleScope CloudDrives {
                Add-CdWantedDrives -DriveIds @('gw')
                Mock Get-CdMountedDrives { @{ 'I:' = [pscustomobject]@{ Fs = 'cd-gw:' } } }
                $state = Get-CdTrayState
                $state.Level | Should -Be 'ok'
                $state.Text | Should -Be (Get-CdText 'tray.connected' 'I:')
                ($state.Drives | Where-Object { $_.Id -eq 'gw' }).Connected | Should -BeTrue
            }
        }

        It 'is yellow while a wanted drive is being reconnected' {
            InModuleScope CloudDrives {
                Add-CdWantedDrives -DriveIds @('gw', 'od')
                Mock Get-CdMountedDrives { @{ 'I:' = [pscustomobject]@{ Fs = 'cd-gw:' } } }
                $state = Get-CdTrayState
                $state.Level | Should -Be 'warn'
                $state.Text | Should -Be (Get-CdText 'tray.reconnecting' 'M:')
            }
        }

        It 'is red when a drive needs the user and offers the new sign-in' {
            InModuleScope CloudDrives {
                Add-CdWantedDrives -DriveIds @('od')
                Save-CdWatchdogState -State @{ od = @{ failures = 1; code = 'CD-3001'; nextTicks = 0; notified = $true } }
                $state = Get-CdTrayState
                $state.Level | Should -Be 'error'
                $state.Text | Should -Be (Get-CdText 'tray.problem' 'M:', (Get-CdText 'error.CD-3001.title'))
                @($state.ReloginAccounts) | Should -Be @('od')
            }
        }

        It 'is red when the engine cannot be restarted' {
            InModuleScope CloudDrives {
                Save-CdWatchdogState -State @{ '#engine' = @{ failures = 1; code = 'CD-2004'; nextTicks = 0; notified = $true } }
                Mock Test-CdEngineRunning { $false }
                (Get-CdTrayState).Level | Should -Be 'error'
            }
        }

        It 'notices settings changed by another CloudDrives window' {
            InModuleScope CloudDrives {
                [void](Get-CdTrayState)
                $file = (Get-CdContext).SettingsFile
                $text = [IO.File]::ReadAllText($file).Replace('"OneDrive"', '"OneDrive Family"')
                [IO.File]::WriteAllText($file, $text)
                (Get-Item -LiteralPath $file).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddSeconds(5)
                ((Get-CdTrayState).Drives | Where-Object { $_.Id -eq 'od' }).Label | Should -Be 'OneDrive Family'
            }
        }
    }

    Context 'Icons' {
        It 'has one icon per status in the size of the notification area' {
            InModuleScope CloudDrives {
                $icons = New-CdTrayIcons
                @($icons.Keys | Sort-Object) | Should -Be @('error', 'idle', 'ok', 'warn')
                $size = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
                foreach ($icon in $icons.Values) { $icon.Width | Should -Be $size }
            }
        }
    }

    Context 'Actions' {
        It 'runs background actions hidden and the menu in a window' {
            InModuleScope CloudDrives {
                Mock Start-CdDetachedProcess { 4711 }
                Mock Start-Process { }
                Start-CdTrayAction -Arguments @('connect', 'all', '--silent')
                Should -Invoke Start-CdDetachedProcess -Times 1 -Exactly -ParameterFilter { $FilePath -match 'conhost\.exe$' -and $RawArguments -match 'connect all --silent' }
                Start-CdTrayAction -Arguments @('doctor', '--pause') -Visible
                Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -match 'CloudDrives\.bat$' -and $ArgumentList -match 'doctor --pause' }
            }
        }

        It 'finds CloudDrive-Sync only when it is installed for the user' {
            InModuleScope CloudDrives -Parameters @{ Root = $TestDrive } {
                param($Root)
                Get-CdSyncAppPath -LocalAppData $Root | Should -BeNullOrEmpty
                $folder = Join-Path $Root 'Programs\CloudDrive-Sync'
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $folder 'CloudDrive-Sync.exe') -Value 'x'
                Get-CdSyncAppPath -LocalAppData $Root | Should -Be (Join-Path $folder 'CloudDrive-Sync.exe')
            }
        }
    }

    Context 'Diagnosis and command line' {
        It 'offers to show a symbol that is switched on but not shown' {
            InModuleScope CloudDrives {
                $script = Join-Path (Get-CdContext).SrcRoot 'CloudDrives.ps1'
                Mock Get-CdTray { [pscustomobject]@{ Enabled = $true; Running = $false } }
                Mock Get-CdTrayTask { [pscustomobject]@{ Actions = @([pscustomobject]@{ Arguments = "-STA -File `"$script`" tray" }) } }
                Mock Get-CdPreferredSrcRoot { (Get-CdContext).SrcRoot }
                $check = Get-CdTrayChecks
                $check.Status | Should -Be 'warn'
                $check.Fix | Should -Be 'start-tray'
            }
        }

        It 'switches the symbol on' {
            InModuleScope CloudDrives {
                Mock Enable-CdTray { New-CdResult -Message 'on' }
                Invoke-CdCommandLineTray -Parsed (ConvertFrom-CdCliArguments -Arguments @('tray', 'an')) | Should -Be 0
                Should -Invoke Enable-CdTray -Times 1 -Exactly
            }
        }

        It 'starts the symbol hidden and in its own apartment' {
            InModuleScope CloudDrives {
                $command = Get-CdAutostartCommand -Command @('tray') -Sta
                $command.Arguments | Should -Match '-STA'
                $command.Arguments | Should -Match '--headless'
                $command.Arguments | Should -Match ' tray'
            }
        }
    }
}
