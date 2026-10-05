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

Describe 'Windows of its own' {
    It 'opens them in the classic console window and marks them as its own' {
        InModuleScope CloudDrives {
            $start = Get-CdWindowStart -AppRoot 'D:\Some Folder\CloudDrives' -Arguments @('doctor', '--pause')
            $start.FilePath | Should -Be (Join-Path $env:SystemRoot 'System32\conhost.exe')
            $start.ArgumentList | Should -Be '"D:\Some Folder\CloudDrives\CloudDrives.bat" doctor --pause --window'
            $start.WorkingDirectory | Should -Be ([Environment]::GetFolderPath('UserProfile'))
            (ConvertFrom-CdCliArguments -Arguments @('--window')).Command | Should -Be 'menu'
        }
    }

    It 'changes shortcuts of earlier versions to the console window, once' {
        InModuleScope CloudDrives -Parameters @{ Root = $TestDrive } {
            param($Root)
            $env:CLOUDDRIVES_SHORTCUT_DIR = Join-Path $Root 'Shortcuts'
            try {
                $app = Join-Path $Root 'Programs\CloudDrives'
                New-Item -ItemType Directory -Path $app -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $app 'CloudDrives.bat') -Value '@echo off'
                $paths = Get-CdShortcutPaths
                New-CdShortcut -Path $paths.StartMenu -Target (Join-Path $app 'CloudDrives.bat')
                Update-CdShortcuts
                $link = (New-Object -ComObject WScript.Shell).CreateShortcut($paths.StartMenu)
                $link.TargetPath | Should -Be (Join-Path $env:SystemRoot 'System32\conhost.exe')
                $link.Arguments | Should -Be ('"' + (Join-Path $app 'CloudDrives.bat') + '" --window')
                $link.IconLocation | Should -Match 'clouddrives\.ico,0$'
                # A desktop shortcut the user removed stays removed.
                Test-Path -LiteralPath $paths.Desktop | Should -BeFalse
            }
            finally { Remove-Item Env:\CLOUDDRIVES_SHORTCUT_DIR -ErrorAction SilentlyContinue }
        }
    }

    It 'gives its window the CloudDrives symbol only where it can' {
        InModuleScope CloudDrives {
            Initialize-CdNative | Should -BeTrue
            'CloudDrives.Native.ConsoleWindow' -as [type] | Should -Not -BeNullOrEmpty
            # Without a visible console window of its own (tests, Windows Terminal) nothing changes and nothing fails.
            { Set-CdConsoleIdentity } | Should -Not -Throw
        }
    }
}

Describe 'About CloudDrives' {
    It 'names version, author, licence and components' {
        InModuleScope CloudDrives {
            $script:Shown = New-Object System.Collections.Generic.List[string]
            Mock Write-CdInfo { $script:Shown.Add($Text) }
            Mock Write-CdHeader { }
            Show-CdAbout
            $text = $script:Shown -join "`n"
            $text | Should -Match ([regex]::Escape('CloudDrives ' + (Get-CdContext).Version))
            $text | Should -Match ([regex]::Escape([string][char]0x00A9 + ' 2026 Steffen Schwabe'))
            $text | Should -Match 'MIT'
            $text | Should -Match 'https://github\.com/suebi76/CloudDrives'
            $text | Should -Match 'rclone'
            $text | Should -Match 'WinFsp'
            (ConvertFrom-CdCliArguments -Arguments @('info')).Command | Should -Be 'about'
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
            Get-CdManifestVersion -Path (Join-Path (Get-CdContext).SrcRoot 'CloudDrives.psd1') | Should -Be (Get-CdContext).Version
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
