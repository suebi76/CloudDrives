# End-to-end test of packaging, installation, update, web installer and uninstall - all inside a sandbox
# folder (CLOUDDRIVES_INSTALL_DIR / CLOUDDRIVES_SHORTCUT_DIR), so the real installation is never touched.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome
    Import-CdModuleForTest
    $script:Sandbox = Join-Path $script:TestHome 'sandbox'
    $env:CLOUDDRIVES_INSTALL_DIR = Join-Path $script:Sandbox 'Programs\CloudDrives'
    $env:CLOUDDRIVES_SHORTCUT_DIR = Join-Path $script:Sandbox 'Shortcuts'
    $script:Release = Join-Path $script:Sandbox 'release-current'
    & (Join-Path $script:RepoRoot 'tools\Build-Release.ps1') -OutDir $script:Release -LocalSource | Out-Null
    $script:Version = [string](InModuleScope CloudDrives { (Get-CdContext).Version })

    function New-TestRelease {
        # Builds a release from a copy of the repository with another version number.
        param([string]$Version, [string]$Name)
        $root = Join-Path $script:Sandbox "source-$Name"
        foreach ($item in @('CloudDrives.bat', 'install.ps1', 'src', 'docs', 'LICENSE', 'README.md', 'PRIVACY.md', 'CHANGELOG.md')) {
            $path = Join-Path $script:RepoRoot $item
            if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination (New-Item -ItemType Directory -Path $root -Force) -Recurse -Force }
        }
        $manifest = Join-Path $root 'src\CloudDrives.psd1'
        $text = [IO.File]::ReadAllText($manifest) -replace "ModuleVersion\s*=\s*'[^']+'", "ModuleVersion        = '$Version'"
        [IO.File]::WriteAllText($manifest, $text, (New-Object Text.UTF8Encoding($true)))
        $out = Join-Path $script:Sandbox "release-$Name"
        & (Join-Path $script:RepoRoot 'tools\Build-Release.ps1') -OutDir $out -SourceRoot $root -LocalSource | Out-Null
        $out
    }
}

AfterAll {
    foreach ($name in @('CLOUDDRIVES_INSTALL_DIR', 'CLOUDDRIVES_SHORTCUT_DIR', 'CLOUDDRIVES_RELEASE_SOURCE', 'CLOUDDRIVES_INSTALL_NOSTART')) {
        Remove-Item "Env:\$name" -ErrorAction SilentlyContinue
    }
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'Release package' {
    It 'contains the application but no tests or tools' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $script:Release "CloudDrives-$($script:Version).zip"))
        try { $names = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') }) } finally { $zip.Dispose() }
        $names | Should -Contain 'CloudDrives.bat'
        $names | Should -Contain 'install.ps1'
        $names | Should -Contain 'src/CloudDrives.psd1'
        $names | Should -Contain 'src/Resources/icons/clouddrives.ico'
        @($names | Where-Object { $_ -match '^(tests|tools|\.github)/' }) | Should -BeNullOrEmpty
    }

    It 'lists correct SHA256 checksums' {
        $sums = [IO.File]::ReadAllText((Join-Path $script:Release 'SHA256SUMS.txt'))
        foreach ($file in @("CloudDrives-$($script:Version).zip", 'install.ps1')) {
            $hash = (Get-FileHash -LiteralPath (Join-Path $script:Release $file) -Algorithm SHA256).Hash.ToLowerInvariant()
            $sums | Should -Match ([regex]::Escape("$hash  $file"))
        }
    }
}

Describe 'Install, update and uninstall' {
    It 'installs the application with Start menu and desktop shortcuts' {
        InModuleScope CloudDrives {
            $result = Install-CdApplication -Desktop
            $result.Success | Should -BeTrue
            $dir = Get-CdInstallDir
            foreach ($item in @('CloudDrives.bat', 'src\CloudDrives.psd1', 'src\Resources\icons\clouddrives.ico', 'LICENSE')) {
                Test-Path -LiteralPath (Join-Path $dir $item) | Should -BeTrue -Because $item
            }
            Test-Path -LiteralPath (Join-Path $dir 'tests') | Should -BeFalse
            $shell = New-Object -ComObject WScript.Shell
            foreach ($link in @((Get-CdShortcutPaths).StartMenu, (Get-CdShortcutPaths).Desktop)) {
                Test-Path -LiteralPath $link | Should -BeTrue
                $shortcut = $shell.CreateShortcut($link)
                $shortcut.TargetPath | Should -Be (Join-Path $env:SystemRoot 'System32\conhost.exe')
                $shortcut.Arguments | Should -Be ('"' + (Join-Path $dir 'CloudDrives.bat') + '" --window')
                $shortcut.WorkingDirectory | Should -Be ([Environment]::GetFolderPath('UserProfile'))
            }
        }
    }

    It 'keeps a drive name given in Explorer when installing again' {
        InModuleScope CloudDrives {
            # A drive id no real drive uses: the Explorer key is per user, not per data folder.
            $drive = [ordered]@{ id = 'cd-install-names-test'; account = 'acc'; label = 'Alt'; letter = 'Z'; path = ''; encrypted = $false; autoConnect = $false; readOnly = $false }
            $settings = Get-CdSettings
            $settings.accounts = @([ordered]@{ id = 'acc'; provider = 'onedrive'; kind = 'personal'; label = 'Acc' })
            $settings.drives = @($drive)
            Save-CdSettings -Settings $settings
            $key = Get-CdExplorerKey -Drive $drive
            [void](New-Item -Path $key -Force)
            Set-ItemProperty -LiteralPath $key -Name '_LabelFromReg' -Value 'Im Explorer umbenannt'
            try {
                (Install-CdApplication).Success | Should -BeTrue
                (Get-CdSettings -Reload).drives[0].label | Should -Be 'Im Explorer umbenannt'
                Get-CdDriveLabel -Drive (Get-CdSettings).drives[0] | Should -Be 'Im Explorer umbenannt'
            }
            finally {
                Remove-CdDriveLabel -Drive $drive
                $settings = Get-CdSettings -Reload
                $settings.drives = @()
                $settings.accounts = @()
                Save-CdSettings -Settings $settings
            }
        }
    }

    It 'runs the installed copy' {
        $bat = Join-Path $env:CLOUDDRIVES_INSTALL_DIR 'CloudDrives.bat'
        $output = & $bat version "--home=$($script:TestHome)"
        $LASTEXITCODE | Should -Be 0
        ($output | Select-Object -Last 1) | Should -Be $script:Version
    }

    It 'updates to a newer release' {
        $newer = New-TestRelease -Version '9.9.1' -Name 'newer'
        $env:CLOUDDRIVES_RELEASE_SOURCE = $newer
        InModuleScope CloudDrives {
            $state = Get-CdUpdateState
            $state.Available | Should -BeTrue
            $state.Latest | Should -Be ([version]'9.9.1')
            $script:TestProgress = New-Object System.Collections.Generic.List[string]
            (Install-CdUpdate -OnProgress { param([string]$Status) $script:TestProgress.Add($Status) }).Success | Should -BeTrue
            Get-CdManifestVersion -Path (Join-Path (Get-CdInstallDir) 'src\CloudDrives.psd1') | Should -Be ([version]'9.9.1')
            $script:TestProgress.ToArray() | Should -Be @(
                (Get-CdText 'update.checking'), (Get-CdText 'progress.download' '9.9.1'), (Get-CdText 'progress.verify'), (Get-CdText 'progress.install' '9.9.1'))
        }
    }

    It 'rejects a tampered update and keeps the installed version' {
        $tampered = New-TestRelease -Version '9.9.2' -Name 'tampered'
        $zip = Join-Path $tampered 'CloudDrives-9.9.2.zip'
        $bytes = [IO.File]::ReadAllBytes($zip)
        [IO.File]::WriteAllBytes($zip, $bytes + [byte[]](1, 2, 3))
        $env:CLOUDDRIVES_RELEASE_SOURCE = $tampered
        InModuleScope CloudDrives {
            $script:TestProgress = New-Object System.Collections.Generic.List[string]
            try { [void](Install-CdUpdate -OnProgress { param([string]$Status) $script:TestProgress.Add($Status) }); throw 'expected an error' }
            catch { Get-CdErrorCode $_ | Should -Be 'CD-1006' }
            # The tampered package fails the check: nothing gets installed.
            $script:TestProgress.ToArray() | Should -Not -Contain (Get-CdText 'progress.install' '9.9.2')
            Get-CdManifestVersion -Path (Join-Path (Get-CdInstallDir) 'src\CloudDrives.psd1') | Should -Be ([version]'9.9.1')
        }
    }

    It 'installs through the web installer (irm | iex)' {
        $env:CLOUDDRIVES_RELEASE_SOURCE = $script:Release
        $env:CLOUDDRIVES_INSTALL_NOSTART = '1'
        $previous = $env:CLOUDDRIVES_INSTALL_DIR
        $env:CLOUDDRIVES_INSTALL_DIR = Join-Path $script:Sandbox 'Programs2\CloudDrives'
        try {
            $installer = Join-Path $script:Release 'install.ps1'
            $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $command = "Invoke-Expression ([IO.File]::ReadAllText('$installer'))"
            & $powershell -NoProfile -ExecutionPolicy Bypass -Command $command | Out-Null
            $LASTEXITCODE | Should -Be 0
            Test-Path -LiteralPath (Join-Path $env:CLOUDDRIVES_INSTALL_DIR 'src\CloudDrives.psd1') | Should -BeTrue
        }
        finally {
            Remove-Item -LiteralPath (Split-Path -Parent $env:CLOUDDRIVES_INSTALL_DIR) -Recurse -Force -ErrorAction SilentlyContinue
            $env:CLOUDDRIVES_INSTALL_DIR = $previous
            Remove-Item Env:\CLOUDDRIVES_INSTALL_NOSTART
        }
    }

    It 'uninstalls but keeps the local data unless asked otherwise' {
        InModuleScope CloudDrives {
            (Uninstall-CdApplication).Success | Should -BeTrue
            Test-Path -LiteralPath (Get-CdInstallDir) | Should -BeFalse
            Test-Path -LiteralPath (Get-CdShortcutPaths).StartMenu | Should -BeFalse
            Test-Path -LiteralPath (Get-CdShortcutPaths).Desktop | Should -BeFalse
            Test-Path -LiteralPath (Get-CdContext).Home | Should -BeTrue
        }
    }
}
