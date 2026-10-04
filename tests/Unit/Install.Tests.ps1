BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome
    Import-CdModuleForTest
}

AfterAll {
    Remove-Item Env:\CLOUDDRIVES_INSTALL_DIR -ErrorAction SilentlyContinue
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'Install locations' {
    It 'installs to LOCALAPPDATA\Programs\CloudDrives by default' {
        InModuleScope CloudDrives {
            Remove-Item Env:\CLOUDDRIVES_INSTALL_DIR -ErrorAction SilentlyContinue
            Get-CdInstallDir | Should -Be (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\CloudDrives')
        }
    }

    It 'honours CLOUDDRIVES_INSTALL_DIR' {
        InModuleScope CloudDrives {
            $env:CLOUDDRIVES_INSTALL_DIR = 'C:\Temp\CD Test\'
            try { Get-CdInstallDir | Should -Be 'C:\Temp\CD Test' }
            finally { Remove-Item Env:\CLOUDDRIVES_INSTALL_DIR }
        }
    }

    It 'knows that the development copy is not installed' {
        InModuleScope CloudDrives { Test-CdInstalled | Should -BeFalse }
    }

    It 'points the autostart to a given program folder' {
        InModuleScope CloudDrives {
            $command = Get-CdAutostartCommand -SrcRoot 'C:\Programs Folder\CloudDrives\src'
            $command.Arguments | Should -Match ([regex]::Escape('"C:\Programs Folder\CloudDrives\src\CloudDrives.ps1"'))
            # Never the program folder: a running autostart would otherwise block updates.
            $command.WorkingDirectory | Should -Be ([Environment]::GetFolderPath('UserProfile'))
        }
    }
}

Describe 'Release metadata' {
    It 'reads the hash of a file from a checksum list' {
        InModuleScope CloudDrives {
            $hash = 'a' * 64
            $text = "$('b' * 64)  install.ps1`n$hash  CloudDrives-0.2.0.zip`n"
            Get-CdChecksumFromList -Text $text -FileName 'CloudDrives-0.2.0.zip' | Should -Be $hash
            Get-CdChecksumFromList -Text $text -FileName 'other.zip' | Should -BeNullOrEmpty
        }
    }

    It 'reads the version from a module manifest' {
        InModuleScope CloudDrives {
            Get-CdManifestVersion -Path (Join-Path (Get-CdContext).SrcRoot 'CloudDrives.psd1') | Should -Be ([version](Get-CdContext).Version)
        }
    }

    It 'packages only what users need' {
        InModuleScope CloudDrives {
            $items = @((Get-CdAppInfo).packageItems)
            $items | Should -Contain 'CloudDrives.bat'
            $items | Should -Contain 'src'
            $items | Should -Not -Contain 'tests'
            $items | Should -Not -Contain 'tools'
        }
    }
}
