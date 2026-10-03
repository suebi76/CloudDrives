BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome
    Import-CdModuleForTest
}

AfterAll {
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'Settings' {
    BeforeEach {
        InModuleScope CloudDrives {
            $file = (Get-CdContext).SettingsFile
            foreach ($f in @($file, "$file.bak")) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
            [void](Get-CdSettings -Reload)
        }
    }

    It 'starts with valid defaults' {
        InModuleScope CloudDrives {
            $settings = Get-CdSettings
            $settings.schemaVersion | Should -Be 1
            $settings.securityMode | Should -Be 'dpapi'
            @(Test-CdSettings -Settings $settings) | Should -BeNullOrEmpty
        }
    }

    It 'keeps single accounts and drives as JSON arrays after a round trip' {
        InModuleScope CloudDrives {
            $settings = Get-CdSettings
            $settings.accounts = Add-CdArrayItem -Array $settings.accounts -Item ([ordered]@{ id = 'gpro'; provider = 'drive'; kind = 'personal'; label = 'Google Pro'; clientId = 'default' })
            $settings.drives = Add-CdArrayItem -Array $settings.drives -Item ([ordered]@{ id = 'gpro'; account = 'gpro'; label = 'Google Pro'; letter = 'K'; path = ''; encrypted = $false; autoConnect = $true; readOnly = $false })
            Save-CdSettings -Settings $settings

            $raw = [IO.File]::ReadAllText((Get-CdContext).SettingsFile)
            $raw | Should -Match '"accounts":\s*\['
            $raw | Should -Match '"drives":\s*\['

            $loaded = Get-CdSettings -Reload
            @($loaded.accounts).Count | Should -Be 1
            $loaded.accounts[0].label | Should -Be 'Google Pro'
            $loaded.drives[0].letter | Should -Be 'K'
            (Get-CdDrive -Id 'K:').id | Should -Be 'gpro'
        }
    }

    It 'never writes secrets into settings.json' {
        InModuleScope CloudDrives {
            Save-CdSettings -Settings (Get-CdSettings)
            [IO.File]::ReadAllText((Get-CdContext).SettingsFile) | Should -Not -Match '(?i)token|secret|password'
        }
    }

    It 'rejects <Name>' -ForEach @(
        @{ Name = 'duplicate drive letters'; Drives = @(@{ id = 'a'; account = 'acc'; label = 'A'; letter = 'K' }, @{ id = 'b'; account = 'acc'; label = 'B'; letter = 'K' }) }
        @{ Name = 'unknown accounts'; Drives = @(@{ id = 'a'; account = 'missing'; label = 'A'; letter = 'K' }) }
        @{ Name = 'invalid letters'; Drives = @(@{ id = 'a'; account = 'acc'; label = 'A'; letter = 'C' }) }
        @{ Name = 'invalid ids'; Drives = @(@{ id = 'Not Valid'; account = 'acc'; label = 'A'; letter = 'K' }) }
    ) {
        InModuleScope CloudDrives -Parameters @{ Drives = $Drives } {
            $settings = New-CdDefaultSettings
            $settings.accounts = @([ordered]@{ id = 'acc'; provider = 'onedrive'; kind = 'personal'; label = 'Acc' })
            $settings.drives = $Drives
            @(Test-CdSettings -Settings $settings).Count | Should -BeGreaterThan 0
            { Save-CdSettings -Settings $settings } | Should -Throw
        }
    }

    It 'completes settings written by an older version' {
        InModuleScope CloudDrives {
            [IO.File]::WriteAllText((Get-CdContext).SettingsFile, '{ "schemaVersion": 1, "accounts": [], "drives": [] }')
            $settings = Get-CdSettings -Reload
            $settings.cache.maxSizePerDrive | Should -Be '10G'
            $settings.profile | Should -Be 'standard'
        }
    }

    It 'refuses settings from a newer version' {
        InModuleScope CloudDrives {
            [IO.File]::WriteAllText((Get-CdContext).SettingsFile, '{ "schemaVersion": 99 }')
            { Get-CdSettings -Reload } | Should -Throw
            try { Get-CdSettings -Reload } catch { Get-CdErrorCode $_ | Should -Be 'CD-2005' }
        }
    }

    It 'reports damaged settings with code CD-2001' {
        InModuleScope CloudDrives {
            [IO.File]::WriteAllText((Get-CdContext).SettingsFile, '{ this is not json')
            try { [void](Get-CdSettings -Reload); throw 'expected an error' } catch { Get-CdErrorCode $_ | Should -Be 'CD-2001' }
        }
    }
}

Describe 'Drive letters and mount options' {
    BeforeAll {
        InModuleScope CloudDrives {
            $settings = New-CdDefaultSettings
            $settings.accounts = @([ordered]@{ id = 'od'; provider = 'onedrive'; kind = 'personal'; label = 'OneDrive' })
            $settings.drives = @([ordered]@{ id = 'od'; account = 'od'; label = 'OneDrive'; letter = 'M'; path = ''; encrypted = $false; autoConnect = $true; readOnly = $false })
            $script:CdSettings = $settings
        }
    }

    It 'never offers A-C, used letters or letters reserved by other drives' {
        InModuleScope CloudDrives {
            Mock Get-CdUsedDriveLetters { @('A', 'B', 'C', 'D', 'E', 'G', 'H') }
            $free = Get-CdFreeDriveLetters
            $free | Should -Not -Contain 'C'
            $free | Should -Not -Contain 'G'
            $free | Should -Not -Contain 'M'
            $free | Should -Contain 'K'
            $free[0] | Should -Be 'F'
        }
    }

    It 'suggests the first free preferred letter' {
        InModuleScope CloudDrives {
            Mock Get-CdUsedDriveLetters { @('A', 'B', 'C', 'K') }
            Get-CdSuggestedDriveLetter -Preferred @('K', 'J', 'L') | Should -Be 'J'
            Get-CdSuggestedDriveLetter -Preferred @('M') | Should -Be 'D'
        }
    }

    It 'builds the rclone path for plain and encrypted drives' {
        InModuleScope CloudDrives {
            Get-CdDriveFs -Drive ([ordered]@{ id = 'od'; account = 'od'; path = ''; encrypted = $false }) | Should -Be 'cd-od:'
            Get-CdDriveFs -Drive ([ordered]@{ id = 'od'; account = 'od'; path = '/Fotos/'; encrypted = $false }) | Should -Be 'cd-od:Fotos'
            Get-CdDriveFs -Drive ([ordered]@{ id = 'tresor'; account = 'od'; path = 'Tresor'; encrypted = $true }) | Should -Be 'cd-vault-tresor:'
        }
    }

    It 'mounts as network drive with full VFS cache and provider options' {
        InModuleScope CloudDrives {
            $settings = Get-CdSettings
            $options = Get-CdMountOptions -Drive $settings.drives[0] -Account $settings.accounts[0] -Settings $settings
            $options.network_mode | Should -BeTrue
            $options.volname | Should -Be '\\CloudDrives\od'
            $options.vfs_cache_mode | Should -Be 'full'
            $options.vfs_cache_max_size | Should -Be '10G'
            $options.poll_interval | Should -Be '1m'
        }
    }

    It 'applies the lean profile' {
        InModuleScope CloudDrives {
            $settings = Get-CdSettings
            $settings.profile = 'lean'
            try {
                $options = Get-CdMountOptions -Drive $settings.drives[0] -Account $settings.accounts[0] -Settings $settings
                $options.vfs_cache_max_size | Should -Be '2G'
            }
            finally { $settings.profile = 'standard' }
        }
    }
}

Describe 'Command line' {
    It 'parses <Arguments> as command <Command>' -ForEach @(
        @{ Arguments = @(); Command = 'menu'; Targets = @(); Flag = $null }
        @{ Arguments = @('verbinden', 'K'); Command = 'connect'; Targets = @('K'); Flag = $null }
        @{ Arguments = @('connect', '--silent'); Command = 'connect'; Targets = @(); Flag = 'silent' }
        @{ Arguments = @('status', '--json'); Command = 'status'; Targets = @(); Flag = 'json' }
        @{ Arguments = @('trennen', 'all', '--force'); Command = 'disconnect'; Targets = @('all'); Flag = 'force' }
        @{ Arguments = @('/?'); Command = 'help'; Targets = @(); Flag = $null }
        @{ Arguments = @('connect', '-h'); Command = 'help'; Targets = @(); Flag = 'h' }
    ) {
        InModuleScope CloudDrives -Parameters @{ Arguments = $Arguments; Command = $Command; Targets = $Targets; Flag = $Flag } {
            $parsed = ConvertFrom-CdCliArguments -Arguments $Arguments
            $parsed.Command | Should -Be $Command
            @($parsed.Targets) | Should -Be @($Targets)
            if ($Flag) { $parsed.Flags.ContainsKey($Flag) | Should -BeTrue }
        }
    }

    It 'extracts the exit code from mixed output' {
        InModuleScope CloudDrives {
            Get-CdLastInt @('noise', 1, 'more noise', 2) | Should -Be 2
            Get-CdLastInt @('noise') -Default 0 | Should -Be 0
        }
    }
}
