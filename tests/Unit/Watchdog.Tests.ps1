# Watchdog: which drives are wanted, what one cycle does in each situation, back-off and notifications,
# the scheduled task definition, the diagnosis and the command line.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome
    Import-CdModuleForTest
    InModuleScope CloudDrives { Initialize-CdHome }
}

AfterAll {
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'Watchdog' {
    BeforeEach {
        InModuleScope CloudDrives {
            $settings = Get-CdSettings
            $settings.notifications = 'errors'
            $settings.accounts = @(
                [ordered]@{ id = 'gw'; provider = 'drive'; kind = 'workspace'; label = 'Schule'; clientId = 'own' }
                [ordered]@{ id = 'od'; provider = 'onedrive'; kind = 'personal'; label = 'OneDrive' }
            )
            $settings.drives = @(
                [ordered]@{ id = 'gw'; account = 'gw'; label = 'Schule'; letter = 'I'; path = ''; encrypted = $false; autoConnect = $true; readOnly = $false }
                [ordered]@{ id = 'tresor'; account = 'gw'; label = 'Tresor'; letter = 'J'; path = 'Tresor'; encrypted = $true; autoConnect = $true; readOnly = $false }
                [ordered]@{ id = 'od'; account = 'od'; label = 'OneDrive'; letter = 'M'; path = ''; encrypted = $false; autoConnect = $true; readOnly = $false }
            )
            Save-CdSettings -Settings $settings
            foreach ($file in @((Get-CdWantedStateFile), (Get-CdWatchdogStateFile))) {
                if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
            }
            Mock Get-CdLastBootTime { (Get-Date).AddHours(-1) }
            Mock Test-CdInternet { $true }
            Mock Get-CdEngine { [pscustomobject]@{ ProcessId = 1; Alive = $true; Healthy = $true } }
            Mock Start-CdEngine { }
            Mock Get-CdMountedDrives { @{} }
            Mock Mount-CdDrive { New-CdResult -Message "$($Drive.letter): connected" -Data $Drive }
            Mock Show-CdNotification { $true }
            Mock Start-Sleep { }
        }
    }

    Context 'Wanted drives' {
        It 'remembers drives that are connected and forgets drives that are disconnected' {
            InModuleScope CloudDrives {
                Add-CdWantedDrives -DriveIds @('gw', 'tresor')
                Add-CdWantedDrives -DriveIds @('gw')
                @(Get-CdWantedDrives) | Should -Be @('gw', 'tresor')
                Remove-CdWantedDrives -DriveIds @('gw')
                @(Get-CdWantedDrives) | Should -Be @('tresor')
            }
        }

        It 'forgets the list after a Windows restart' {
            InModuleScope CloudDrives {
                Add-CdWantedDrives -DriveIds @('gw')
                Mock Get-CdLastBootTime { (Get-Date).AddMinutes(5) }
                @(Get-CdWantedDrives).Count | Should -Be 0
            }
        }

        It 'follows connecting and disconnecting' {
            InModuleScope CloudDrives {
                Mock Wait-CdNetwork { $true }
                Mock Update-CdAccountIdentities { }
                [void](Invoke-CdConnect -Selection @('gw'))
                @(Get-CdWantedDrives) | Should -Contain 'gw'

                Mock Test-CdEngineRunning { $true }
                Mock Dismount-CdDrive { New-CdResult -Data $Drive }
                Mock Stop-CdEngine { }
                [void](Invoke-CdDisconnect -Selection @('gw'))
                @(Get-CdWantedDrives) | Should -Not -Contain 'gw'
            }
        }

        It 'keeps a drive that stays connected because of pending uploads' {
            InModuleScope CloudDrives {
                Add-CdWantedDrives -DriveIds @('gw')
                Mock Test-CdEngineRunning { $true }
                Mock Dismount-CdDrive { New-CdResult -Success $false -Code 'CD-4006' -Data ([pscustomobject]@{ Drive = $Drive; Pending = 2 }) }
                Mock Get-CdMountedDrives { @{ 'I:' = [pscustomobject]@{ Fs = 'cd-gw:' } } }
                [void](Invoke-CdDisconnect -Selection @('gw'))
                @(Get-CdWantedDrives) | Should -Contain 'gw'
            }
        }
    }

    Context 'One cycle' {
        It 'does nothing when no drive is wanted' {
            InModuleScope CloudDrives {
                (Invoke-CdWatchdog).Status | Should -Be 'idle'
                Should -Invoke Get-CdEngine -Times 0 -Exactly
            }
        }

        It 'waits while there is no internet connection' {
            InModuleScope CloudDrives {
                Add-CdWantedDrives -DriveIds @('gw')
                Mock Test-CdInternet { $false }
                (Invoke-CdWatchdog).Status | Should -Be 'offline'
                Should -Invoke Mount-CdDrive -Times 0 -Exactly
            }
        }

        It 'steps aside while a connect or disconnect is running' {
            InModuleScope CloudDrives {
                Add-CdWantedDrives -DriveIds @('gw')
                Mock Enter-CdLock { throw (New-CdException -Code 'CD-9002') } -ParameterFilter { $Name -eq 'connect' }
                (Invoke-CdWatchdog).Status | Should -Be 'busy'
            }
        }

        It 'reconnects only the wanted drives that are missing' {
            InModuleScope CloudDrives {
                Add-CdWantedDrives -DriveIds @('gw', 'tresor')
                Mock Get-CdMountedDrives { @{ 'I:' = [pscustomobject]@{ Fs = 'cd-gw:' } } }
                $cycle = Invoke-CdWatchdog
                $cycle.Status | Should -Be 'ok'
                $cycle.EngineRestarted | Should -BeFalse
                Should -Invoke Mount-CdDrive -Times 1 -Exactly -ParameterFilter { $Drive.id -eq 'tresor' }
            }
        }

        It 'restarts a crashed engine and reconnects the drives' {
            InModuleScope CloudDrives {
                Add-CdWantedDrives -DriveIds @('gw', 'od')
                Mock Get-CdEngine { $null }
                $cycle = Invoke-CdWatchdog
                $cycle.EngineRestarted | Should -BeTrue
                Should -Invoke Start-CdEngine -Times 1 -Exactly
                Should -Invoke Mount-CdDrive -Times 2 -Exactly
            }
        }

        It 'gives a busy engine a second chance' {
            InModuleScope CloudDrives {
                Add-CdWantedDrives -DriveIds @('gw')
                $script:TestEngineCalls = 0
                Mock Get-CdEngine {
                    $script:TestEngineCalls++
                    [pscustomobject]@{ ProcessId = 1; Alive = $true; Healthy = ($script:TestEngineCalls -gt 1) }
                }
                (Invoke-CdWatchdog).EngineRestarted | Should -BeFalse
                Should -Invoke Start-CdEngine -Times 0 -Exactly
            }
        }

        It 'restarts an engine that keeps not responding' {
            InModuleScope CloudDrives {
                Add-CdWantedDrives -DriveIds @('gw')
                Mock Get-CdEngine { [pscustomobject]@{ ProcessId = 1; Alive = $true; Healthy = $false } }
                (Invoke-CdWatchdog).EngineRestarted | Should -BeTrue
                Should -Invoke Start-CdEngine -Times 1 -Exactly
            }
        }

        It 'reports an engine that cannot be restarted once' {
            InModuleScope CloudDrives {
                Add-CdWantedDrives -DriveIds @('gw')
                Mock Get-CdEngine { $null }
                Mock Start-CdEngine { throw (New-CdException -Code 'CD-2004') }
                (Invoke-CdWatchdog).Status | Should -Be 'failed'
                (Invoke-CdWatchdog).Status | Should -Be 'failed'
                Should -Invoke Show-CdNotification -Times 1 -Exactly
            }
        }
    }

    Context 'Persistent problems' {
        It 'retries less and less often and reports the problem once' {
            InModuleScope CloudDrives {
                Add-CdWantedDrives -DriveIds @('od')
                Mock Mount-CdDrive { throw (New-CdException -Code 'CD-3001' -Detail 'invalid_grant') }
                (Invoke-CdWatchdog).Status | Should -Be 'failed'
                [void](Invoke-CdWatchdog)
                [void](Invoke-CdWatchdog)
                # 1st failure: retried in the next cycle; 2nd failure: waits 15 minutes.
                Should -Invoke Mount-CdDrive -Times 2 -Exactly
                Should -Invoke Show-CdNotification -Times 1 -Exactly -ParameterFilter { $Message -like ('*' + (Get-CdText 'notify.reloginHint')) }
                $record = (Read-CdWatchdogState)['od']
                $record.failures | Should -Be 2
                $record.code | Should -Be 'CD-3001'
            }
        }

        It 'reports a different problem of the same drive again' {
            InModuleScope CloudDrives {
                Add-CdWantedDrives -DriveIds @('od')
                Mock Mount-CdDrive { throw (New-CdException -Code 'CD-3001') }
                [void](Invoke-CdWatchdog)
                Mock Mount-CdDrive { throw (New-CdException -Code 'CD-4001') }
                [void](Invoke-CdWatchdog)
                Should -Invoke Show-CdNotification -Times 2 -Exactly
            }
        }

        It 'forgets the problem once the drive works again' {
            InModuleScope CloudDrives {
                Add-CdWantedDrives -DriveIds @('od')
                Mock Mount-CdDrive { throw (New-CdException -Code 'CD-5001') }
                [void](Invoke-CdWatchdog)
                Mock Mount-CdDrive { New-CdResult -Data $Drive }
                (Invoke-CdWatchdog).Status | Should -Be 'ok'
                (Read-CdWatchdogState).ContainsKey('od') | Should -BeFalse
            }
        }

        It 'waits 0, 15, 60 and then 360 minutes' {
            InModuleScope CloudDrives {
                @(1, 2, 3, 4, 9 | ForEach-Object { Get-CdWatchdogBackoff -Failures $_ }) | Should -Be @(0, 15, 60, 360, 360)
            }
        }
    }

    Context 'Scheduled task' {
        It 'runs the hidden watchdog every 5 minutes, after waking up and after network changes' {
            InModuleScope CloudDrives {
                [xml]$xml = Get-CdWatchdogTaskXml -SrcRoot 'C:\Program Files Test\CloudDrives\src'
                $ns = @{ t = 'http://schemas.microsoft.com/windows/2004/02/mit/task' }
                (Select-Xml -Xml $xml -XPath '//t:TimeTrigger/t:Repetition/t:Interval' -Namespace $ns).Node.InnerText | Should -Be 'PT5M'
                $subscriptions = @(Select-Xml -Xml $xml -XPath '//t:EventTrigger/t:Subscription' -Namespace $ns | ForEach-Object { $_.Node.InnerText })
                $subscriptions.Count | Should -Be 2
                ($subscriptions -join ' ') | Should -Match 'Power-Troubleshooter'
                ($subscriptions -join ' ') | Should -Match 'NetworkProfile'
                (Select-Xml -Xml $xml -XPath '//t:Exec/t:Command' -Namespace $ns).Node.InnerText | Should -Match 'conhost\.exe$'
                $arguments = (Select-Xml -Xml $xml -XPath '//t:Exec/t:Arguments' -Namespace $ns).Node.InnerText
                $arguments | Should -Match ([regex]::Escape('"C:\Program Files Test\CloudDrives\src\CloudDrives.ps1" watchdog --silent'))
                (Select-Xml -Xml $xml -XPath '//t:Exec/t:WorkingDirectory' -Namespace $ns).Node.InnerText | Should -Be ([Environment]::GetFolderPath('UserProfile'))
                (Select-Xml -Xml $xml -XPath '//t:MultipleInstancesPolicy' -Namespace $ns).Node.InnerText | Should -Be 'IgnoreNew'
                (Select-Xml -Xml $xml -XPath '//t:DisallowStartIfOnBatteries' -Namespace $ns).Node.InnerText | Should -Be 'false'
            }
        }
    }

    Context 'Diagnosis' {
        It 'recommends the watchdog when only the autostart is on' {
            InModuleScope CloudDrives {
                Mock Get-CdWatchdog { [pscustomobject]@{ Enabled = $false; Detail = $null } }
                Mock Get-CdAutostart { [pscustomobject]@{ Enabled = $true; Method = 'task'; Detail = 'x' } }
                $check = Get-CdWatchdogChecks
                $check.Status | Should -Be 'warn'
                $check.Fix | Should -Be 'enable-watchdog'
            }
        }

        It 'names the drives the watchdog is waiting for' {
            InModuleScope CloudDrives {
                $script = Join-Path (Get-CdContext).SrcRoot 'CloudDrives.ps1'
                Mock Get-CdWatchdog { [pscustomobject]@{ Enabled = $true; Detail = 'x' } }
                Mock Get-CdWatchdogTask { [pscustomobject]@{ Actions = @([pscustomobject]@{ Arguments = "-File `"$script`" watchdog --silent" }) } }
                Mock Get-CdPreferredSrcRoot { (Get-CdContext).SrcRoot }
                Save-CdWatchdogState -State @{ od = @{ failures = 2; code = 'CD-3001'; nextTicks = 0; notified = $true } }
                $check = Get-CdWatchdogChecks
                $check.Status | Should -Be 'warn'
                $check.Message | Should -Match 'M:'
            }
        }
    }

    Context 'Command line' {
        It 'switches the watchdog on and runs one cycle without arguments' {
            InModuleScope CloudDrives {
                Mock Enable-CdWatchdog { New-CdResult -Message 'on' }
                Invoke-CdCommandLineWatchdog -Parsed (ConvertFrom-CdCliArguments -Arguments @('watchdog', 'an')) | Should -Be 0
                Should -Invoke Enable-CdWatchdog -Times 1 -Exactly
                Mock Invoke-CdWatchdog { [pscustomobject]@{ Status = 'failed'; EngineRestarted = $false; Results = @() } }
                Invoke-CdCommandLineWatchdog -Parsed (ConvertFrom-CdCliArguments -Arguments @('watchdog', '--silent')) | Should -Be 1
            }
        }
    }
}
