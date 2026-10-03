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
