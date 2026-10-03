BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome
    Import-CdModuleForTest
}

AfterAll {
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'Vault passwords' {
    It 'generates readable random passwords without look-alike characters' {
        InModuleScope CloudDrives {
            $password = New-CdVaultPassword
            $password | Should -MatchExactly '^([A-HJ-NP-Za-km-z2-9]{4}-){5}[A-HJ-NP-Za-km-z2-9]{4}$'
            New-CdVaultPassword | Should -Not -Be $password
        }
    }

    It 'draws from the whole alphabet' {
        InModuleScope CloudDrives {
            $sample = -join (1..150 | ForEach-Object { (New-CdVaultPassword).Replace('-', '') })
            @($sample.ToCharArray() | Sort-Object -CaseSensitive -Unique).Count | Should -Be 57
        }
    }
}

Describe 'Vault folders and encoding' {
    It 'normalises "<Raw>" to "<Expected>"' -ForEach @(
        @{ Raw = 'CloudDrives-Tresor'; Expected = 'CloudDrives-Tresor' }
        @{ Raw = '\Privat\Tresor\'; Expected = 'Privat/Tresor' }
        @{ Raw = ' //a//b/ '; Expected = 'a/b' }
    ) {
        InModuleScope CloudDrives -Parameters @{ Value = $Raw; Want = $Expected } {
            ConvertTo-CdVaultFolder -Folder $Value | Should -BeExactly $Want
        }
    }

    It 'rejects an empty folder with CD-6004' {
        InModuleScope CloudDrives {
            try { [void](ConvertTo-CdVaultFolder -Folder '  /  '); throw 'expected an error' }
            catch { Get-CdErrorCode $_ | Should -Be 'CD-6004' }
        }
    }

    It 'keeps encrypted names short on OneDrive' {
        InModuleScope CloudDrives {
            Get-CdVaultEncoding -Provider 'onedrive' | Should -Be 'base32768'
            Get-CdVaultEncoding -Provider 'drive' | Should -Be 'base32'
        }
    }

    It 'requires a folder for encrypted drives' {
        InModuleScope CloudDrives {
            $settings = New-CdDefaultSettings
            $settings.accounts = @([ordered]@{ id = 'acc'; provider = 'drive'; kind = 'personal'; label = 'Acc' })
            $settings.drives = @([ordered]@{ id = 'v'; account = 'acc'; label = 'V'; letter = 'V'; path = ''; encrypted = $true })
            (Test-CdSettings -Settings $settings) -join ';' | Should -Match 'no folder'
        }
    }
}

Describe 'Recovery kit' {
    BeforeAll {
        InModuleScope CloudDrives {
            Initialize-CdI18n -Language 'de'
            $script:KitDrive = [ordered]@{ id = 'google-tresor'; label = 'Google Tresor'; path = 'CloudDrives-Tresor'; letter = 'V'; vault = [ordered]@{ filenameEncoding = 'base32' } }
            $script:KitAccount = [ordered]@{ id = 'google-pro'; label = 'Google Pro'; provider = 'drive' }
        }
    }

    It 'contains everything needed to restore the vault' {
        InModuleScope CloudDrives {
            $text = Get-CdRecoveryKitText -Drive $script:KitDrive -Account $script:KitAccount -Password 'Abcd-Efgh-Jkmn' -Salt 'Pqrs-Tuvw-Xyz2'
            $text | Should -Match 'Abcd-Efgh-Jkmn'
            $text | Should -Match 'Pqrs-Tuvw-Xyz2'
            $text | Should -Match 'CloudDrives-Tresor'
            $text | Should -Match 'filename_encoding=base32'
            $text | Should -Match 'Google Pro'
            $text | Should -Not -Match '\{\d\}'
        }
    }

    It 'is saved as a Notepad-friendly file' {
        InModuleScope CloudDrives {
            $path = Join-Path (Get-CdContext).Home 'kit\recovery.txt'
            $saved = Save-CdRecoveryKit -Path $path -Text "Zeile 1`nZeile 2 $([char]0x00FC)"
            $bytes = [IO.File]::ReadAllBytes($saved)
            $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
            [IO.File]::ReadAllText($saved) | Should -Be "Zeile 1`r`nZeile 2 $([char]0x00FC)"
        }
    }

    It 'recognises folders that are synchronised to a cloud' {
        InModuleScope CloudDrives {
            $previous = $env:OneDrive
            $env:OneDrive = 'C:\FakeOneDrive'
            try {
                Test-CdPathInCloudFolder -Path 'C:\FakeOneDrive\Dokumente\kit.txt' | Should -BeTrue
                Test-CdPathInCloudFolder -Path 'C:\FakeOneDriveOther\kit.txt' | Should -BeFalse
            }
            finally { $env:OneDrive = $previous }
        }
    }

    It 'suggests a default location outside synchronised folders' {
        InModuleScope CloudDrives {
            $path = Get-CdRecoveryKitDefaultPath -Drive $script:KitDrive
            $path | Should -Match 'CloudDrives-Recovery-google-tresor\.txt$'
        }
    }
}
