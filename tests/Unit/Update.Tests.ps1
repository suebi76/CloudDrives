# Updates: versions with a test label, which release counts, the regular look on GitHub and the three ways new
# versions arrive (notice, automatic, only on request).

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome
    Import-CdModuleForTest
    InModuleScope CloudDrives { Initialize-CdHome }

    function New-TestReleaseInfo {
        # A release as GitHub lists it, with the two assets an update needs.
        param([string]$Tag, [bool]$Prerelease = $false, [bool]$Draft = $false, [switch]$NoAssets)
        $version = $Tag.TrimStart('v')
        $assets = @(
            [pscustomobject]@{ name = "CloudDrives-$version.zip"; browser_download_url = "https://example.invalid/CloudDrives-$version.zip" },
            [pscustomobject]@{ name = 'SHA256SUMS.txt'; browser_download_url = "https://example.invalid/$version/SHA256SUMS.txt" }
        )
        if ($NoAssets) { $assets = @() }
        [pscustomobject]@{ tag_name = $Tag; prerelease = $Prerelease; draft = $Draft; assets = $assets }
    }
}

AfterAll {
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'Versions' {
    It 'orders versions like semantic versions' {
        InModuleScope CloudDrives {
            Compare-CdVersion '0.3.3' '0.3.2' | Should -Be 1
            Compare-CdVersion '0.3.2' '0.3.3' | Should -Be -1
            Compare-CdVersion 'v1.0.0' '1.0.0' | Should -Be 0
            # A test version comes before its release, but after the one before.
            Compare-CdVersion '0.3.3-preview.1' '0.3.3' | Should -Be -1
            Compare-CdVersion '0.3.3-preview.1' '0.3.2' | Should -Be 1
            Compare-CdVersion '0.3.3-preview.10' '0.3.3-preview.9' | Should -Be 1
            Compare-CdVersion '0.3.3-alpha' '0.3.3-beta' | Should -Be -1
            Compare-CdVersion '0.3.3-preview' '0.3.3-preview.1' | Should -Be -1
            Compare-CdVersion '0.3.3-1' '0.3.3-alpha' | Should -Be -1
            # Anything that is no version is the oldest.
            Compare-CdVersion 'Unsinn' '0.0.1' | Should -Be -1
            Compare-CdVersion '0.0.1' '' | Should -Be 1
        }
    }

    It 'reads a test version with its label from a module manifest' {
        InModuleScope CloudDrives {
            $file = Join-Path (Get-CdContext).Home 'version-test.psd1'
            [IO.File]::WriteAllText($file, "@{ ModuleVersion = '0.3.3'; PrivateData = @{ PSData = @{ Prerelease = 'preview.2' } } }")
            Get-CdManifestVersion -Path $file | Should -Be '0.3.3-preview.2'
            [IO.File]::WriteAllText($file, "@{ ModuleVersion = '0.3.3' }")
            Get-CdManifestVersion -Path $file | Should -Be '0.3.3'
        }
    }

    It 'knows its own version as the manifest names it' {
        InModuleScope CloudDrives {
            (Get-CdContext).Version | Should -Be (Get-CdManifestVersion -Path (Join-Path (Get-CdContext).SrcRoot 'CloudDrives.psd1'))
        }
    }
}

Describe 'Choosing a release' {
    BeforeAll {
        $script:Releases = @(
            (New-TestReleaseInfo -Tag 'v0.3.4-preview.1' -Prerelease $true),
            (New-TestReleaseInfo -Tag 'v0.3.3'),
            (New-TestReleaseInfo -Tag 'v0.3.2')
        )
    }

    It 'takes the newest regular release without test versions' {
        InModuleScope CloudDrives -Parameters @{ Releases = $script:Releases } {
            param($Releases)
            $release = Select-CdRelease -Releases $Releases
            $release.Version | Should -Be '0.3.3'
            $release.TestVersion | Should -BeFalse
            $release.PackageName | Should -Be 'CloudDrives-0.3.3.zip'
            $release.PackageUrl | Should -Be 'https://example.invalid/CloudDrives-0.3.3.zip'
        }
    }

    It 'takes the newest test version when test versions are received' {
        InModuleScope CloudDrives -Parameters @{ Releases = $script:Releases } {
            param($Releases)
            $release = Select-CdRelease -Releases $Releases -TestVersions
            $release.Version | Should -Be '0.3.4-preview.1'
            $release.TestVersion | Should -BeTrue
            $release.PackageName | Should -Be 'CloudDrives-0.3.4-preview.1.zip'
        }
    }

    It 'prefers the release over its own test versions' {
        $releases = @((New-TestReleaseInfo -Tag 'v0.3.4-preview.2' -Prerelease $true), (New-TestReleaseInfo -Tag 'v0.3.4'))
        InModuleScope CloudDrives -Parameters @{ Releases = $releases } {
            param($Releases)
            (Select-CdRelease -Releases $Releases -TestVersions).Version | Should -Be '0.3.4'
        }
    }

    It 'ignores drafts, tags without a version and pre-releases without a label' {
        $releases = @(
            (New-TestReleaseInfo -Tag 'v0.9.0' -Draft $true),
            (New-TestReleaseInfo -Tag 'nightly'),
            (New-TestReleaseInfo -Tag 'v0.3.5' -Prerelease $true),
            (New-TestReleaseInfo -Tag 'v0.3.3')
        )
        InModuleScope CloudDrives -Parameters @{ Releases = $releases } {
            param($Releases)
            (Select-CdRelease -Releases $Releases).Version | Should -Be '0.3.3'
            (Select-CdRelease -Releases $Releases -TestVersions).Version | Should -Be '0.3.5'
            Select-CdRelease -Releases @() | Should -BeNullOrEmpty
        }
    }

    It 'refuses a release without package or checksums' {
        $releases = @((New-TestReleaseInfo -Tag 'v0.3.3' -NoAssets))
        InModuleScope CloudDrives -Parameters @{ Releases = $releases } {
            param($Releases)
            try { [void](Select-CdRelease -Releases $Releases); throw 'expected an error' }
            catch { Get-CdErrorCode $_ | Should -Be 'CD-8005' }
        }
    }
}

Describe 'Looking for new versions' {
    BeforeEach {
        $script:Available = @((New-TestReleaseInfo -Tag 'v99.1.0-preview.1' -Prerelease $true), (New-TestReleaseInfo -Tag 'v99.0.0'))
        InModuleScope CloudDrives -Parameters @{ Available = $script:Available } {
            param($Available)
            $script:TestReleases = $Available
            $settings = Get-CdSettings
            $settings.updates = 'notify'
            $settings.testVersions = $false
            $settings.notifications = 'errors'
            Save-CdSettings -Settings $settings
            Reset-CdUpdateCheck
            Mock Test-CdInstalled { $true }
            Mock Get-CdReleaseList { $script:TestReleases }
            Mock Show-CdNotification { $true }
            Mock Test-CdTrayRunning { $true }
            Mock Test-CdWindowOpen { $false }
            Mock Install-CdUpdate { New-CdResult -Message 'installiert' -Data ([pscustomobject]@{ Version = '99.0.0' }) }
            Mock Test-CdEngineRunning { $false }
        }
    }

    It 'tells about a new version once and offers it in the menu and the symbol' {
        InModuleScope CloudDrives {
            Invoke-CdBackgroundUpdateCheck | Should -Be 'announced'
            Should -Invoke Show-CdNotification -Times 1 -Exactly -ParameterFilter { $Message -eq (Get-CdText 'update.notifyTray' '99.0.0') }
            Get-CdPendingUpdate | Should -Be '99.0.0'
            (Get-CdTrayState).Update | Should -Be '99.0.0'
            # The next look is only due in a few hours; the version has been announced already.
            Invoke-CdBackgroundUpdateCheck | Should -Be 'none'
            Should -Invoke Get-CdReleaseList -Times 1 -Exactly
            Should -Invoke Show-CdNotification -Times 1 -Exactly
            Should -Invoke Install-CdUpdate -Times 0 -Exactly
        }
    }

    It 'names the menu when no symbol is shown, and stays quiet when notifications are off' {
        InModuleScope CloudDrives {
            Mock Test-CdTrayRunning { $false }
            Invoke-CdBackgroundUpdateCheck | Should -Be 'announced'
            Should -Invoke Show-CdNotification -Times 1 -Exactly -ParameterFilter { $Message -eq (Get-CdText 'update.notify' '99.0.0') }
            Reset-CdUpdateCheck
            $settings = Get-CdSettings
            $settings.notifications = 'off'
            Save-CdSettings -Settings $settings
            Invoke-CdBackgroundUpdateCheck | Should -Be 'announced'
            Should -Invoke Show-CdNotification -Times 1 -Exactly
        }
    }

    It 'receives test versions only when asked to' {
        InModuleScope CloudDrives {
            $settings = Get-CdSettings
            $settings.testVersions = $true
            Save-CdSettings -Settings $settings
            Invoke-CdBackgroundUpdateCheck | Should -Be 'announced'
            Get-CdPendingUpdate | Should -Be '99.1.0-preview.1'
        }
    }

    It 'looks again only after a few hours' {
        InModuleScope CloudDrives {
            Save-CdUpdateCheck -Record ([ordered]@{ checkedTicks = (Get-Date).ToUniversalTime().AddHours(-1).Ticks; latest = ''; announced = '' })
            Test-CdUpdateCheckDue | Should -BeFalse
            Invoke-CdBackgroundUpdateCheck | Should -Be 'none'
            Should -Invoke Get-CdReleaseList -Times 0 -Exactly
            Save-CdUpdateCheck -Record ([ordered]@{ checkedTicks = (Get-Date).ToUniversalTime().AddHours(-7).Ticks; latest = ''; announced = '' })
            Test-CdUpdateCheckDue | Should -BeTrue
            # A look noted in the future (the clock was put back) does not stop the looks.
            Save-CdUpdateCheck -Record ([ordered]@{ checkedTicks = (Get-Date).ToUniversalTime().AddDays(3).Ticks; latest = ''; announced = '' })
            Test-CdUpdateCheckDue | Should -BeTrue
        }
    }

    It 'never looks on its own with "only when I check", nor in a copy that is not installed' {
        InModuleScope CloudDrives {
            $settings = Get-CdSettings
            $settings.updates = 'manual'
            Save-CdSettings -Settings $settings
            Invoke-CdBackgroundUpdateCheck | Should -Be 'none'
            Test-CdUpdateCheckDue | Should -BeFalse
            $settings.updates = 'notify'
            Save-CdSettings -Settings $settings
            Mock Test-CdInstalled { $false }
            Invoke-CdBackgroundUpdateCheck | Should -Be 'none'
            Get-CdPendingUpdate | Should -BeNullOrEmpty
            Should -Invoke Get-CdReleaseList -Times 0 -Exactly
        }
    }

    It 'installs automatically, but only when no CloudDrives window is open' {
        InModuleScope CloudDrives {
            $settings = Get-CdSettings
            $settings.updates = 'automatic'
            Save-CdSettings -Settings $settings
            Mock Test-CdWindowOpen { $true }
            Invoke-CdBackgroundUpdateCheck | Should -Be 'waiting'
            Should -Invoke Install-CdUpdate -Times 0 -Exactly
            # The symbol starts the hidden check again once the window is closed.
            Test-CdTrayUpdateCheckDue | Should -BeFalse
            Mock Test-CdWindowOpen { $false }
            Test-CdTrayUpdateCheckDue | Should -BeTrue
            Invoke-CdBackgroundUpdateCheck | Should -Be 'installed'
            Should -Invoke Install-CdUpdate -Times 1 -Exactly
            Should -Invoke Get-CdReleaseList -Times 1 -Exactly
            # Installed quietly: notifications only when every event is wanted.
            Should -Invoke Show-CdNotification -Times 0 -Exactly
        }
    }

    It 'forgets a version whose automatic installation failed until the next regular look' {
        InModuleScope CloudDrives {
            $settings = Get-CdSettings
            $settings.updates = 'automatic'
            Save-CdSettings -Settings $settings
            Mock Install-CdUpdate { throw (New-CdException -Code 'CD-5001' -Detail 'offline') }
            Invoke-CdBackgroundUpdateCheck | Should -Be 'none'
            Get-CdPendingUpdate | Should -BeNullOrEmpty
            Test-CdUpdateCheckDue | Should -BeFalse
        }
    }

    It 'lets only one process look at a time' {
        InModuleScope CloudDrives {
            Mock Enter-CdLock { throw (New-CdException -Code 'CD-9002' -Detail 'busy') } -ParameterFilter { $Name -eq 'update' }
            Invoke-CdBackgroundUpdateCheck | Should -Be 'none'
            Should -Invoke Get-CdReleaseList -Times 0 -Exactly
        }
    }

    It 'notes what a look on request found' {
        InModuleScope CloudDrives {
            $state = Get-CdUpdateState
            $state.Available | Should -BeTrue
            $state.Latest | Should -Be '99.0.0'
            (Read-CdUpdateCheck).latest | Should -Be '99.0.0'
            Test-CdUpdateCheckDue | Should -BeFalse
        }
    }
}

Describe 'Command line' {
    BeforeEach {
        InModuleScope CloudDrives {
            Mock Show-CdNotification { $true }
            Mock Invoke-CdBackgroundUpdateCheck { 'none' }
        }
    }

    It 'looks in the background for the autostart and the symbol' {
        InModuleScope CloudDrives {
            Invoke-CdCommandLineUpdate -Parsed (ConvertFrom-CdCliArguments -Arguments @('update', '--background', '--silent')) | Should -Be 0
            Should -Invoke Invoke-CdBackgroundUpdateCheck -Times 1 -Exactly
        }
    }

    It 'installs with one click and reports the outcome by notification' {
        InModuleScope CloudDrives {
            Mock Install-CdUpdate { New-CdResult -Message (Get-CdText 'update.done' '99.0.0') -Data ([pscustomobject]@{ Version = '99.0.0' }) }
            Invoke-CdCommandLineUpdate -Parsed (ConvertFrom-CdCliArguments -Arguments @('update', '--silent')) | Should -Be 0
            Should -Invoke Show-CdNotification -Times 1 -Exactly -ParameterFilter { $Message -eq (Get-CdText 'update.done' '99.0.0') }
            Mock Install-CdUpdate { throw (New-CdException -Code 'CD-1006' -Detail 'checksum') }
            { Invoke-CdCommandLineUpdate -Parsed (ConvertFrom-CdCliArguments -Arguments @('update', '--silent')) } | Should -Throw
            Should -Invoke Show-CdNotification -Times 1 -Exactly -ParameterFilter { $Title -eq (Get-CdText 'update.failedTitle') -and $Message -eq (Get-CdText 'error.CD-1006.title') }
            Should -Invoke Invoke-CdBackgroundUpdateCheck -Times 0 -Exactly
        }
    }
}

Describe 'Settings menu' {
    It 'changes how new versions arrive and whether test versions count, and looks again soon' {
        InModuleScope CloudDrives {
            $settings = Get-CdSettings
            $settings.updates = 'notify'
            $settings.testVersions = $false
            Save-CdSettings -Settings $settings
            Save-CdUpdateCheck -Record ([ordered]@{ checkedTicks = (Get-Date).ToUniversalTime().Ticks; latest = '99.0.0'; announced = '99.0.0' })
            $script:TestAnswers = New-Object System.Collections.Queue
            foreach ($answer in @('5', '5', '6', '0')) { $script:TestAnswers.Enqueue($answer) }
            $script:TestLines = New-Object System.Collections.Generic.List[string]
            Mock Read-CdChoice { $script:TestAnswers.Dequeue() }
            Mock Clear-CdScreen { }
            Mock Write-CdHeader { }
            Mock Write-CdInfo { $script:TestLines.Add($Text) }
            Mock Get-CdAutostart { [pscustomobject]@{ Enabled = $false } }
            Mock Get-CdWatchdog { [pscustomobject]@{ Enabled = $false } }
            Mock Get-CdTray { [pscustomobject]@{ Enabled = $false; Running = $false } }
            [void](Start-CdSettingsMenu)
            $settings = Get-CdSettings
            $settings.updates | Should -Be 'manual'
            $settings.testVersions | Should -BeTrue
            (Read-CdUpdateCheck).latest | Should -BeNullOrEmpty
            Test-CdUpdateCheckDue -Record (Read-CdUpdateCheck) | Should -BeFalse -Because 'never with "only when I check"'
            $script:TestLines | Should -Contain ('[5] ' + (Get-CdText 'settings.updates' (Get-CdText 'settings.updates.automatic')))
            $script:TestLines | Should -Contain ('    ' + ((Get-CdText 'settings.updatesHint.manual') -split "`n")[0])
            $script:TestLines | Should -Contain ('[6] ' + (Get-CdText 'settings.testVersions' (Get-CdText 'settings.on')))
        }
    }
}

Describe 'Open windows' {
    It 'knows while a CloudDrives window is open' {
        InModuleScope CloudDrives {
            Test-CdWindowOpen | Should -BeFalse
            Register-CdWindow
            try { Test-CdWindowOpen | Should -BeTrue }
            finally {
                $script:CdWindowMarker.Dispose()
                $script:CdWindowMarker = $null
            }
            Test-CdWindowOpen | Should -BeFalse
        }
    }
}

Describe 'Update settings' {
    It 'shows a notice by default and receives no test versions' {
        InModuleScope CloudDrives {
            $defaults = New-CdDefaultSettings
            $defaults.updates | Should -Be 'notify'
            $defaults.testVersions | Should -BeFalse
        }
    }

    It 'drops the day of the last look that versions up to 0.3.2 kept in the settings' {
        InModuleScope CloudDrives {
            $old = New-CdDefaultSettings
            $old.lastUpdateCheck = '2026-10-01'
            (Complete-CdSettings -Settings $old).Contains('lastUpdateCheck') | Should -BeFalse
        }
    }

    It 'rejects an unknown way of receiving updates' {
        InModuleScope CloudDrives {
            $settings = New-CdDefaultSettings
            $settings.updates = 'sometimes'
            (Test-CdSettings -Settings $settings) | Should -Contain "invalid updates 'sometimes'"
        }
    }
}
