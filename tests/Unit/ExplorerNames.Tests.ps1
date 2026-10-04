# Drives renamed in Explorer keep their names: CloudDrives adopts them instead of overwriting them.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome
    Import-CdModuleForTest
    InModuleScope CloudDrives { Initialize-CdHome }
}

AfterAll {
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'Names given in Explorer' {
    BeforeEach {
        InModuleScope CloudDrives {
            $settings = Get-CdSettings
            $settings.accounts = @([ordered]@{ id = 'gw'; provider = 'drive'; kind = 'workspace'; label = 'GW'; clientId = 'own' })
            $settings.drives = @(
                [ordered]@{ id = 'gw'; account = 'gw'; label = 'GW'; letter = 'I'; path = ''; encrypted = $false; autoConnect = $true; readOnly = $false }
                [ordered]@{ id = 'docs'; account = 'gw'; label = 'Dokumente'; letter = 'K'; path = 'Docs'; encrypted = $false; autoConnect = $true; readOnly = $false }
            )
            Save-CdSettings -Settings $settings
        }
    }

    It 'are adopted into the settings' {
        InModuleScope CloudDrives {
            Mock Get-CdDriveLabel { if ($Drive.id -eq 'gw') { 'Google Work' } else { [string]$Drive.label } }
            $adopted = @(Sync-CdDriveLabels)
            $adopted.Count | Should -Be 1
            $adopted[0].Previous | Should -Be 'GW'
            (Get-CdSettings -Reload).drives[0].label | Should -Be 'Google Work'
            (Get-CdSettings).drives[1].label | Should -Be 'Dokumente'
        }
    }

    It 'change nothing when Explorer shows the same or no name' {
        InModuleScope CloudDrives {
            Mock Get-CdDriveLabel { if ($Drive.id -eq 'gw') { $null } else { [string]$Drive.label } }
            Mock Save-CdSettings { }
            @(Sync-CdDriveLabels).Count | Should -Be 0
            Should -Invoke Save-CdSettings -Times 0 -Exactly
        }
    }

    It 'are kept when a drive is connected' {
        InModuleScope CloudDrives {
            Mock Get-CdMountedDrives { @{} }
            Mock Get-CdUsedDriveLetters { @('A', 'B', 'C') }
            Mock Invoke-CdRc { } -ParameterFilter { $Command -eq 'mount/mount' }
            Mock Wait-CdDriveReady { $true }
            Mock Get-CdDriveLabel { if ($Drive.id -eq 'gw') { 'Google Work' } else { [string]$Drive.label } }
            Mock Set-CdDriveLabel { }
            $result = Mount-CdDrive -Drive (Get-CdDrive -Id 'gw')
            $result.Message | Should -Match 'Google Work'
            Should -Invoke Set-CdDriveLabel -Times 1 -Exactly -ParameterFilter { $Drive.label -eq 'Google Work' }
            Should -Invoke Set-CdDriveLabel -Times 0 -Exactly -ParameterFilter { $Drive.label -eq 'GW' }
        }
    }

    It 'are adopted by the watchdog even when it has nothing else to do' {
        InModuleScope CloudDrives {
            Mock Sync-CdDriveLabels { }
            (Invoke-CdWatchdog).Status | Should -Be 'idle'
            Should -Invoke Sync-CdDriveLabels -Times 1 -Exactly
        }
    }
}
