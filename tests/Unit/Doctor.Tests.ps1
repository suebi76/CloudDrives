# Diagnosis: each area with simulated findings, the summary, automatic fixes and the text report.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome
    Import-CdModuleForTest
    InModuleScope CloudDrives { Initialize-CdHome }
}

AfterAll {
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'Diagnosis' {
    BeforeEach {
        InModuleScope CloudDrives {
            $settings = Get-CdSettings
            $settings.accounts = @(
                [ordered]@{ id = 'gw'; provider = 'drive'; kind = 'workspace'; label = 'Schule'; clientId = 'own'; identity = [ordered]@{ id = '111'; name = 'a@example.com' } }
                [ordered]@{ id = 'gpro'; provider = 'drive'; kind = 'personal'; label = 'Google Pro'; clientId = 'default' }
            )
            $settings.drives = @(
                [ordered]@{ id = 'gw'; account = 'gw'; label = 'Schule'; letter = 'I'; path = ''; encrypted = $false; autoConnect = $true; readOnly = $false }
                [ordered]@{ id = 'gpro'; account = 'gpro'; label = 'Google Pro'; letter = 'K'; path = ''; encrypted = $false; autoConnect = $true; readOnly = $false }
            )
            Save-CdSettings -Settings $settings
            $script:CdQuotaCache = @{}
        }
    }

    Context 'Summary' {
        It 'derives the exit code and the fixable problems' {
            InModuleScope CloudDrives {
                $checks = @(
                    New-CdCheck -Area 'system' -Name 'a'
                    New-CdCheck -Area 'drives' -Name 'b' -Status 'warn' -Fix 'connect' -Target 'gw'
                    New-CdCheck -Area 'drives' -Name 'c' -Status 'info' -Fix 'labels'
                )
                $summary = Get-CdDoctorSummary -Checks $checks
                $summary.ExitCode | Should -Be 1
                @($summary.Fixable).Count | Should -Be 1
                (Get-CdDoctorSummary -Checks @($checks + (New-CdCheck -Area 'x' -Name 'd' -Status 'fail'))).ExitCode | Should -Be 2
                (Get-CdDoctorSummary -Checks @($checks[0])).ExitCode | Should -Be 0
            }
        }

        It 'writes a plain-text report with the status of every check' {
            InModuleScope CloudDrives {
                $text = Format-CdDoctorReport -Checks @(
                    New-CdCheck -Area 'drives' -Name 'I: Schule' -Status 'fail' -Code 'CD-4001' -Message 'taken'
                )
                $text | Should -Match ([regex]::Escape("[$(Get-CdText 'doctor.status.fail')] I: Schule: taken (CD-4001)"))
                $text | Should -Match ([regex]::Escape((Get-CdText 'doctor.summary' 1, 0)))
            }
        }
    }

    Context 'Components and settings' {
        It 'reports a missing rclone and WinFsp with an automatic fix' {
            InModuleScope CloudDrives {
                Mock Find-CdRclone { $null }
                Mock Get-CdWinFsp { $null }
                $checks = @(Get-CdComponentChecks)
                ($checks | Where-Object { $_.Name -eq 'rclone' }).Fix | Should -Be 'install-rclone'
                ($checks | Where-Object { $_.Name -eq 'WinFsp' }).Code | Should -Be 'CD-1002'
            }
        }

        It 'accepts valid settings' {
            InModuleScope CloudDrives {
                $check = @(Get-CdSettingsChecks) | Where-Object { $_.Name -eq (Get-CdText 'doctor.settings') }
                $check.Status | Should -Be 'ok'
                $check.Message | Should -Be (Get-CdText 'doctor.settingsOk' 2, 2)
            }
        }
    }

    Context 'Accounts' {
        BeforeEach {
            InModuleScope CloudDrives {
                Mock Test-CdEngineRunning { $true }
                Mock Get-CdRemoteNames { @('cd-gw', 'cd-gpro') }
                Mock Get-CdRemoteAbout { [pscustomobject]@{ total = 2TB; used = 1TB } }
            }
        }

        It 'offers a new sign-in when a sign-in has expired' {
            InModuleScope CloudDrives {
                Mock Get-CdRemoteAbout { throw (New-CdException -Code 'CD-3001' -Detail 'invalid_grant') } -ParameterFilter { $RemoteName -eq 'cd-gw' }
                $check = @(Get-CdAccountChecks) | Where-Object { $_.Target -eq 'gw' }
                $check.Status | Should -Be 'fail'
                $check.Fix | Should -Be 'relogin'
            }
        }

        It 'reports a missing sign-in' {
            InModuleScope CloudDrives {
                Mock Get-CdRemoteNames { @('cd-gpro') }
                $check = @(Get-CdAccountChecks) | Where-Object { $_.Target -eq 'gw' }
                $check.Status | Should -Be 'fail'
                $check.Fix | Should -Be 'relogin'
            }
        }

        It 'explains the 15 GB per-user limit of Google Workspace' {
            InModuleScope CloudDrives {
                Mock Get-CdRemoteAbout { [pscustomobject]@{ total = 16106127360; used = 63333990 } } -ParameterFilter { $RemoteName -eq 'cd-gw' }
                $check = @(Get-CdAccountChecks) | Where-Object { $_.Target -eq 'gw' }
                $check.Status | Should -Be 'warn'
                $check.Message | Should -Match ([regex]::Escape((Get-CdText 'doctor.workspaceLimit')))
                $check.Message | Should -Match 'a@example\.com'
            }
        }

        It 'warns when the storage is almost full' {
            InModuleScope CloudDrives {
                Mock Get-CdRemoteAbout { [pscustomobject]@{ total = 100GB; used = 97GB } } -ParameterFilter { $RemoteName -eq 'cd-gw' }
                (@(Get-CdAccountChecks) | Where-Object { $_.Target -eq 'gw' }).Code | Should -Be 'CD-3006'
            }
        }

        It 'recommends an own client ID for accounts on the shared rclone client' {
            InModuleScope CloudDrives {
                $checks = @(Get-CdAccountChecks | Where-Object { $_.Target -eq 'gpro' })
                $checks.Count | Should -Be 2
                ($checks | Where-Object { $_.Fix -eq 'change-client' }).Status | Should -Be 'warn'
            }
        }

        It 'skips the accounts when the engine cannot start' {
            InModuleScope CloudDrives {
                Mock Test-CdEngineRunning { $false }
                Mock Start-CdEngine { throw (New-CdException -Code 'CD-2004') }
                $check = @(Get-CdAccountChecks)
                $check.Count | Should -Be 1
                $check[0].Status | Should -Be 'skip'
                $check[0].Code | Should -Be 'CD-2004'
            }
        }
    }

    Context 'Drives' {
        BeforeEach {
            InModuleScope CloudDrives {
                Mock Get-CdMountedDrives { @{ 'I:' = [pscustomobject]@{ MountPoint = 'I:'; Fs = 'cd-gw:' } } }
                Mock Get-CdUsedDriveLetters { @('A', 'B', 'C', 'I') }
                Mock Get-CdDriveLabel { [string]$Drive.label }
                Mock Invoke-CdRc { [pscustomobject]@{ list = @() } } -ParameterFilter { $Command -eq 'operations/list' }
                Mock Invoke-CdRc { [pscustomobject]@{ diskCache = [pscustomobject]@{ uploadsInProgress = 1; uploadsQueued = 1; erroredFiles = 0; outOfSpace = $false } } } -ParameterFilter { $Command -eq 'vfs/stats' }
            }
        }

        It 'reads from connected drives and offers to connect the others' {
            InModuleScope CloudDrives {
                $checks = @(Get-CdDriveChecks)
                $gw = $checks | Where-Object { $_.Target -eq 'gw' }
                $gw.Status | Should -Be 'ok'
                $gw.Message | Should -Match ([regex]::Escape((Get-CdText 'doctor.uploadsPending' 2)))
                $gpro = $checks | Where-Object { $_.Target -eq 'gpro' }
                $gpro.Status | Should -Be 'warn'
                $gpro.Fix | Should -Be 'connect'
            }
        }

        It 'reports a drive letter taken by something else' {
            InModuleScope CloudDrives {
                Mock Get-CdUsedDriveLetters { @('A', 'B', 'C', 'I', 'K') }
                (@(Get-CdDriveChecks) | Where-Object { $_.Target -eq 'gpro' }).Code | Should -Be 'CD-4001'
            }
        }

        It 'reports files that could not be uploaded' {
            InModuleScope CloudDrives {
                Mock Invoke-CdRc { [pscustomobject]@{ diskCache = [pscustomobject]@{ uploadsInProgress = 0; uploadsQueued = 0; erroredFiles = 3; outOfSpace = $false } } } -ParameterFilter { $Command -eq 'vfs/stats' }
                $gw = @(Get-CdDriveChecks) | Where-Object { $_.Target -eq 'gw' }
                $gw.Status | Should -Be 'warn'
                $gw.Code | Should -Be 'CD-7002'
            }
        }

        It 'shows both names when Explorer shows another name' {
            InModuleScope CloudDrives {
                Mock Get-CdDriveLabel { 'GW-Tresor' }
                $label = @(Get-CdDriveChecks) | Where-Object { $_.Target -eq 'gw' -and $_.Fix -eq 'labels' }
                $label.Message | Should -Be (Get-CdText 'doctor.driveLabelDiffers' 'GW-Tresor', 'Schule')
            }
        }
    }

    Context 'Logs' {
        It 'ignores rclone noise and reports real rclone errors' {
            InModuleScope CloudDrives {
                # rclone writes slashes regardless of the culture ('/' in a .NET format is the culture's separator).
                $now = (Get-Date).ToString('yyyy/MM/dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
                $log = Join-Path (Get-CdContext).LogDir 'rclone.log'
                $noise = @(
                    "$now ERROR : symlinks not supported without the --links flag: /"
                    "$now ERROR : rc: ""operations/list"": error: error in ListJSON: directory not found"
                    "$now ERROR : rc: ""operations/about"": error: about call failed: context canceled"
                )
                [IO.File]::WriteAllLines($log, $noise)
                (@(Get-CdEngineChecks) | Where-Object { $_.Name -eq (Get-CdText 'doctor.rcloneLog') }).Status | Should -Be 'ok'

                [IO.File]::AppendAllLines($log, [string[]]@("$now ERROR : Akte.pdf: Failed to copy: googleapi: Error 403: The user's Drive storage quota has been exceeded., storageQuotaExceeded"))
                $check = @(Get-CdEngineChecks) | Where-Object { $_.Name -eq (Get-CdText 'doctor.rcloneLog') }
                $check.Status | Should -Be 'warn'
                $check.Code | Should -Be 'CD-3006'
                $check.Message | Should -Match ([regex]::Escape((Get-CdText 'doctor.rcloneLogErrors' 1, 'x').Split(',')[0]))
            }
        }

        It 'groups recent CloudDrives errors by code and ignores old ones' {
            InModuleScope CloudDrives {
                $log = Join-Path (Get-CdContext).LogDir ('clouddrives-{0}.log' -f (Get-Date).ToString('yyyy-MM-dd'))
                $recent = (Get-Date).AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
                $old = (Get-Date).AddDays(-30).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
                [IO.File]::WriteAllLines($log, [string[]]@(
                        "$recent [ERROR] [abc] [Connect] Drive 'gw' failed: CD-3001 invalid_grant"
                        "$recent [ERROR] [abc] [Connect] Drive 'gw' failed: CD-3001 invalid_grant"
                        "$recent [WARN ] [abc] [Accounts] Quota of 'gw' unavailable: CD-5003"
                        "$old [ERROR] [abc] [Connect] Drive 'gw' failed: CD-4001 taken"
                    ))
                $checks = @(Get-CdLogChecks)
                $checks.Count | Should -Be 1
                $checks[0].Code | Should -Be 'CD-3001'
                $checks[0].Message | Should -Match '^2'
            }
        }
    }

    Context 'Autostart' {
        It 'finds an autostart that points to a deleted program folder' {
            InModuleScope CloudDrives {
                Mock Get-CdAutostart { [pscustomobject]@{ Enabled = $true; Method = 'task'; Detail = '\CloudDrives\CloudDrives Autostart' } }
                Mock Get-CdAutostartTask { [pscustomobject]@{ Actions = @([pscustomobject]@{ Arguments = '--headless powershell.exe -File "C:\Deleted Folder\src\CloudDrives.ps1" connect --silent' }) } }
                $check = Get-CdAutostartChecks
                $check.Status | Should -Be 'fail'
                $check.Fix | Should -Be 'enable-autostart'
                $check.Message | Should -Match 'Deleted Folder'
            }
        }
    }

    Context 'Running all checks' {
        It 'keeps going when one area fails' {
            InModuleScope CloudDrives {
                Mock Get-CdSystemChecks { throw 'broken' }
                Mock Get-CdComponentChecks { New-CdCheck -Area 'components' -Name 'rclone' }
                Mock Get-CdSettingsChecks { }
                Mock Get-CdNetworkChecks { }
                Mock Get-CdUpdateChecks { }
                Mock Get-CdEngineChecks { }
                Mock Get-CdAccountChecks { }
                Mock Get-CdDriveChecks { }
                Mock Get-CdLogChecks { }
                Mock Get-CdAutostartChecks { }
                Mock Test-CdEngineRunning { $true }
                $visited = New-Object System.Collections.Generic.List[string]
                $checks = @(Invoke-CdDoctor -OnArea { param($Area) $visited.Add($Area) })
                $visited.Count | Should -Be 10
                ($checks | Where-Object { $_.Area -eq 'system' }).Status | Should -Be 'fail'
                ($checks | Where-Object { $_.Area -eq 'components' }).Status | Should -Be 'ok'
            }
        }
    }

    Context 'Automatic fixes' {
        It 'connects a drive' {
            InModuleScope CloudDrives {
                Mock Invoke-CdConnect { New-CdResult -Message 'connected' }
                $result = @(Invoke-CdDoctorFix -Check (New-CdCheck -Area 'drives' -Name 'K:' -Status 'warn' -Fix 'connect' -Target 'gpro'))
                $result[0].Success | Should -BeTrue
                Should -Invoke Invoke-CdConnect -Times 1 -Exactly -ParameterFilter { $Selection -contains 'gpro' }
            }
        }

        It 'sets the Explorer name' {
            InModuleScope CloudDrives {
                Mock Set-CdDriveLabel { }
                (Invoke-CdDoctorFix -Check (New-CdCheck -Area 'drives' -Name 'I:' -Status 'warn' -Fix 'labels' -Target 'gw')).Success | Should -BeTrue
                Should -Invoke Set-CdDriveLabel -Times 1 -Exactly -ParameterFilter { $Drive.id -eq 'gw' }
            }
        }

        It 'leaves sign-ins to the user' {
            InModuleScope CloudDrives {
                Test-CdFixInteractive -Fix 'relogin' | Should -BeTrue
                Test-CdFixInteractive -Fix 'connect' | Should -BeFalse
                { Invoke-CdDoctorFix -Check (New-CdCheck -Area 'accounts' -Name 'x' -Status 'fail' -Fix 'relogin') } | Should -Throw
            }
        }
    }
}
