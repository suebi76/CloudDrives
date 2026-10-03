# Integration tests with the real rclone engine and WinFsp - no cloud account needed:
# the "account" is an rclone alias pointing to a local temp folder. A free drive letter is mounted.
# rclone is taken from $env:CLOUDDRIVES_TEST_RCLONE or the dev cache (%LOCALAPPDATA%\CloudDrives-dev\rclone).

BeforeDiscovery {
    $script:CanRun = (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\WinFsp')
}

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome
    Import-CdModuleForTest

    $rcloneSource = $env:CLOUDDRIVES_TEST_RCLONE
    if (-not $rcloneSource) { $rcloneSource = Join-Path $env:LOCALAPPDATA 'CloudDrives-dev\rclone\1.75.1\rclone.exe' }
    $script:Backing = Join-Path $script:TestHome 'backing'
    [void](New-Item -ItemType Directory -Path $script:Backing -Force)

    InModuleScope CloudDrives -Parameters @{ Source = $rcloneSource } {
        Initialize-CdHome
        if (Test-Path -LiteralPath $Source) {
            $target = Join-Path (Get-CdContext).DepsDir 'rclone\1.75.1'
            [void](New-Item -ItemType Directory -Path $target -Force)
            Copy-Item -LiteralPath $Source -Destination $target -Force
        }
        else {
            [void](Install-CdRclone)
        }
    }
}

AfterAll {
    InModuleScope CloudDrives {
        try { Stop-CdEngine } catch { Write-Warning $_ }
        foreach ($drive in @((Get-CdSettings).drives)) { Remove-CdDriveLabel -Drive $drive }
        foreach ($name in @('config', 'rc')) { Remove-CdSecret -Name $name }
    }
    # Safety net: never leave an engine of this test run behind, even if a test failed half-way.
    Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($script:TestHome) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'Engine and mounts' -Skip:(-not $script:CanRun) {
    It 'starts the engine with an encrypted configuration' {
        InModuleScope CloudDrives {
            $engine = Start-CdEngine
            $engine.Healthy | Should -BeTrue
            Test-CdRcloneConfigEncrypted | Should -BeTrue
            (Get-CdEngine).ProcessId | Should -Be $engine.ProcessId
        }
    }

    It 'refuses requests without credentials' {
        InModuleScope CloudDrives {
            $engine = Get-CdEngine
            $bad = [pscustomobject]@{ Port = $engine.Port; ProcessId = $engine.ProcessId; AuthToken = 'aW52YWxpZDppbnZhbGlk' }
            try { [void](Invoke-CdRc -Command 'core/version' -Connection $bad); throw 'expected an error' }
            catch { Get-CdErrorCode $_ | Should -Be 'CD-5003' }
        }
    }

    It 'reuses the running engine instead of starting a second one' {
        InModuleScope CloudDrives {
            $first = Get-CdEngine
            (Start-CdEngine).ProcessId | Should -Be $first.ProcessId
            @(Get-Process -Name rclone -ErrorAction SilentlyContinue | Where-Object { $_.Id -eq $first.ProcessId }).Count | Should -Be 1
        }
    }

    It 'mounts a drive, writes through it and uploads to the remote' {
        InModuleScope CloudDrives -Parameters @{ Backing = $script:Backing } {
            [void](Invoke-CdRc -Command 'config/create' -Body ([ordered]@{ name = 'cd-itest'; type = 'alias'; parameters = @{ remote = $Backing } }))
            $settings = Get-CdSettings
            $settings.accounts = Add-CdArrayItem -Array $settings.accounts -Item ([ordered]@{ id = 'itest'; provider = 'onedrive'; kind = 'personal'; label = 'Integration' })
            Save-CdSettings -Settings $settings
            $letter = Get-CdSuggestedDriveLetter -Preferred @('X', 'Y', 'V', 'U')
            $drive = New-CdDrive -AccountId 'itest' -Letter $letter -Label 'Integration Test'

            $result = Mount-CdDrive -Drive $drive
            $result.Success | Should -BeTrue
            Test-Path -LiteralPath "${letter}:\" | Should -BeTrue

            $content = 'CloudDrives ' + [char]0x00FC + 'ber alles'
            [IO.File]::WriteAllText("${letter}:\hello.txt", $content, [Text.Encoding]::UTF8)
            [IO.File]::ReadAllText("${letter}:\hello.txt", [Text.Encoding]::UTF8) | Should -Be $content

            $deadline = (Get-Date).AddSeconds(30)
            while (-not (Test-Path -LiteralPath (Join-Path $Backing 'hello.txt')) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
            [IO.File]::ReadAllText((Join-Path $Backing 'hello.txt'), [Text.Encoding]::UTF8) | Should -Be $content
        }
    }

    It 'reports the drive as connected' {
        InModuleScope CloudDrives {
            $status = @(Get-CdDriveStatusList)
            $status.Count | Should -Be 1
            $status[0].Mounted | Should -BeTrue
        }
    }

    It 'warns about pending uploads instead of disconnecting' {
        InModuleScope CloudDrives {
            $drive = @((Get-CdSettings).drives)[0]
            [IO.File]::WriteAllText("$($drive.letter):\pending.txt", 'pending upload')
            # Windows reports the file close to the file system slightly later; uploads wait 5 s (write-back).
            Start-Sleep -Seconds 2
            $result = Dismount-CdDrive -Drive $drive
            $result.Code | Should -Be 'CD-4006'
            $result.Data.Pending | Should -BeGreaterThan 0
            (Get-CdMountedDrives).ContainsKey("$($drive.letter):") | Should -BeTrue
        }
    }

    It 'refuses a drive letter that is already in use' {
        InModuleScope CloudDrives {
            $drive = [ordered]@{ id = 'clash'; account = 'itest'; label = 'Clash'; letter = 'C'; path = ''; encrypted = $false; autoConnect = $true; readOnly = $false }
            try { [void](Mount-CdDrive -Drive $drive); throw 'expected an error' }
            catch { Get-CdErrorCode $_ | Should -Be 'CD-4001' }
        }
    }

    It 'disconnects with -Force and stops the engine when nothing is mounted' {
        InModuleScope CloudDrives {
            $drive = @((Get-CdSettings).drives)[0]
            [IO.File]::WriteAllText("$($drive.letter):\resume.txt", 'uploaded after the restart')
            Start-Sleep -Seconds 2
            $results = @(Invoke-CdDisconnect -Force)
            $results[0].Success | Should -BeTrue
            Test-Path -LiteralPath "$($drive.letter):\" | Should -BeFalse
            Get-CdEngine | Should -BeNullOrEmpty
        }
    }

    It 'resumes the interrupted upload on the next start' {
        InModuleScope CloudDrives -Parameters @{ Backing = $script:Backing } {
            $results = @(Invoke-CdConnect -Selection @('all'))
            $results[0].Success | Should -BeTrue
            $deadline = (Get-Date).AddSeconds(30)
            while (-not (Test-Path -LiteralPath (Join-Path $Backing 'resume.txt')) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
            Test-Path -LiteralPath (Join-Path $Backing 'resume.txt') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $Backing 'pending.txt') | Should -BeTrue
            [void](Invoke-CdDisconnect -Force)
        }
    }
}

Describe 'Encrypted vaults' -Skip:(-not $script:CanRun) {
    AfterAll {
        InModuleScope CloudDrives { try { [void](Invoke-CdDisconnect -Force) } catch { Write-Warning $_ } }
    }

    It 'creates a new vault whose file names and contents are encrypted in the cloud' {
        InModuleScope CloudDrives -Parameters @{ Backing = $script:Backing } {
            $letter = Get-CdSuggestedDriveLetter -Preferred @('V', 'W', 'Y', 'U')
            $result = Add-CdVaultDrive -AccountId 'itest' -Folder 'Tresor' -Letter $letter -Label 'Test Tresor' -Password 'correct horse battery' -Salt 'pepper-salt-1234'
            $result.Data.State | Should -Be 'new'
            $drive = $result.Data.Drive
            $drive.encrypted | Should -BeTrue
            $drive.vault.filenameEncoding | Should -Be 'base32768'

            (Mount-CdDrive -Drive $drive).Success | Should -BeTrue
            [IO.File]::WriteAllText("$($drive.letter):\geheim.txt", 'streng geheimer Inhalt')
            [IO.File]::ReadAllText("$($drive.letter):\geheim.txt") | Should -Be 'streng geheimer Inhalt'
            Start-Sleep -Seconds 2
            $fs = [string](Get-CdMountedDrives)["$($drive.letter):"].Fs
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-CdPendingUploadCount -Fs $fs) -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }

            $files = @(Get-ChildItem -LiteralPath (Join-Path $Backing 'Tresor') -File -Recurse -Force)
            $files.Count | Should -Be 2
            $files.Name | Should -Not -Contain 'geheim.txt'
            $files.Name | Should -Not -Contain '.clouddrives-tresor'
            foreach ($file in $files) { [IO.File]::ReadAllText($file.FullName) | Should -Not -Match 'geheim|CloudDrives vault' }
            (Dismount-CdDrive -Drive $drive -Force).Success | Should -BeTrue
        }
    }

    It 'refuses a wrong password and leaves nothing behind' {
        InModuleScope CloudDrives {
            $remotesBefore = @(Get-CdRemoteNames)
            $drivesBefore = @((Get-CdSettings).drives).Count
            $letter = Get-CdSuggestedDriveLetter -Preferred @('W', 'Y', 'U')
            try {
                [void](Add-CdVaultDrive -AccountId 'itest' -Folder 'Tresor' -Letter $letter -Label 'Falsch' -Password 'wrong password!!' -Salt 'pepper-salt-1234')
                throw 'expected an error'
            }
            catch { Get-CdErrorCode $_ | Should -Be 'CD-6001' }
            @(Get-CdRemoteNames) | Should -Be $remotesBefore
            @((Get-CdSettings).drives).Count | Should -Be $drivesBefore
        }
    }

    It 'connects an existing vault with the right password' {
        InModuleScope CloudDrives {
            $letter = Get-CdSuggestedDriveLetter -Preferred @('W', 'Y', 'U')
            $result = Add-CdVaultDrive -AccountId 'itest' -Folder '\Tresor\' -Letter $letter -Label 'Zweiter PC' -Password 'correct horse battery' -Salt 'pepper-salt-1234'
            $result.Data.State | Should -Be 'existing'
            (Remove-CdDrive -Id $result.Data.Drive.id).Success | Should -BeTrue
            [void](Start-CdEngine)
            @(Get-CdRemoteNames) | Should -Not -Contain (Get-CdVaultRemoteName -DriveId $result.Data.Drive.id)
        }
    }

    It 'adopts a vault that was created with plain rclone' {
        InModuleScope CloudDrives {
            [void](Start-CdEngine)
            $body = [ordered]@{
                name = 'cd-plain-crypt'; type = 'crypt'; opt = @{ obscure = $true }
                parameters = [ordered]@{ remote = 'cd-itest:Altbestand'; filename_encryption = 'standard'; directory_name_encryption = 'true'; filename_encoding = 'base32768'; password = 'old vault pass'; password2 = 'old salt value' }
            }
            [void](Invoke-CdRc -Command 'config/create' -Body $body)
            $source = Join-Path (Get-CdContext).Home 'plain-source'
            [void](New-Item -ItemType Directory -Path $source -Force)
            [IO.File]::WriteAllText((Join-Path $source 'alt.txt'), 'old data')
            [void](Invoke-CdRc -Command 'operations/copyfile' -Body ([ordered]@{ srcFs = $source; srcRemote = 'alt.txt'; dstFs = 'cd-plain-crypt:'; dstRemote = 'alt.txt' }))
            Remove-CdRemote -Name 'cd-plain-crypt'

            $letter = Get-CdSuggestedDriveLetter -Preferred @('W', 'Y', 'U')
            $result = Add-CdVaultDrive -AccountId 'itest' -Folder 'Altbestand' -Letter $letter -Label 'Altbestand' -Password 'old vault pass' -Salt 'old salt value'
            $result.Data.State | Should -Be 'existing'
            Test-CdVaultKey -DriveId $result.Data.Drive.id | Should -BeTrue
            (Remove-CdDrive -Id $result.Data.Drive.id).Success | Should -BeTrue
        }
    }

    It 'never mounts a vault whose key is wrong' {
        InModuleScope CloudDrives {
            [void](Start-CdEngine)
            $drive = @((Get-CdSettings).drives) | Where-Object { $_.encrypted } | Select-Object -First 1
            $remote = Get-CdVaultRemoteName -DriveId $drive.id
            [void](Invoke-CdRc -Command 'config/update' -Body ([ordered]@{ name = $remote; parameters = @{ password = 'tampered password' }; opt = @{ obscure = $true } }))
            try { [void](Mount-CdDrive -Drive $drive); throw 'expected an error' }
            catch { Get-CdErrorCode $_ | Should -Be 'CD-6001' }
            (Get-CdMountedDrives).ContainsKey("$($drive.letter):") | Should -BeFalse
        }
    }

    It 'removes a vault drive and its key but keeps the encrypted files' {
        InModuleScope CloudDrives -Parameters @{ Backing = $script:Backing } {
            $drive = @((Get-CdSettings).drives) | Where-Object { $_.encrypted } | Select-Object -First 1
            (Remove-CdDrive -Id $drive.id).Success | Should -BeTrue
            [void](Start-CdEngine)
            @(Get-CdRemoteNames) | Should -Not -Contain (Get-CdVaultRemoteName -DriveId $drive.id)
            @(Get-ChildItem -LiteralPath (Join-Path $Backing 'Tresor') -File -Recurse -Force).Count | Should -Be 2
        }
    }
}
