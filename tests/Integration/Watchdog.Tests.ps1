# The watchdog against the real engine: the engine is killed while a drive is mounted and the watchdog must
# bring both back (with the data); a drive the user disconnected must stay disconnected. Finally the real
# scheduled task is registered, run once in the user's session and removed. No cloud account is needed.

BeforeDiscovery {
    $script:CanRun = (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\WinFsp') -and [bool](Get-Command -Name 'Register-ScheduledTask' -ErrorAction SilentlyContinue)
}

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome
    Import-CdModuleForTest

    $rcloneSource = $env:CLOUDDRIVES_TEST_RCLONE
    if (-not $rcloneSource) { $rcloneSource = Join-Path $env:LOCALAPPDATA 'CloudDrives-dev\rclone\1.75.1\rclone.exe' }
    $script:Backing = Join-Path $script:TestHome 'backing'
    [void](New-Item -ItemType Directory -Path $script:Backing -Force)
    InModuleScope CloudDrives -Parameters @{ Source = $rcloneSource; Backing = $script:Backing } {
        Initialize-CdHome
        if (Test-Path -LiteralPath $Source) {
            $target = Join-Path (Get-CdContext).DepsDir 'rclone\1.75.1'
            [void](New-Item -ItemType Directory -Path $target -Force)
            Copy-Item -LiteralPath $Source -Destination $target -Force
        }
        else { [void](Install-CdRclone) }
        [void](Start-CdEngine)
        [void](Invoke-CdRc -Command 'config/create' -Body ([ordered]@{ name = 'cd-wdtest'; type = 'alias'; parameters = @{ remote = $Backing } }))
        $settings = Get-CdSettings
        $settings.accounts = Add-CdArrayItem -Array $settings.accounts -Item ([ordered]@{ id = 'wdtest'; provider = 'onedrive'; kind = 'personal'; label = 'Watchdog' })
        Save-CdSettings -Settings $settings
        $letter = Get-CdSuggestedDriveLetter -Preferred @('W', 'Y', 'X', 'U')
        [void](New-CdDrive -AccountId 'wdtest' -Letter $letter -Label 'Watchdog Test')
    }
}

AfterAll {
    InModuleScope CloudDrives {
        try { [void](Disable-CdWatchdog) } catch { Write-Warning $_ }
        try { Stop-CdEngine } catch { Write-Warning $_ }
        foreach ($drive in @((Get-CdSettings).drives)) { Remove-CdDriveLabel -Drive $drive }
        foreach ($name in @('config', 'rc')) { Remove-CdSecret -Name $name }
    }
    Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($script:TestHome) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'Watchdog with the real engine' -Skip:(-not $script:CanRun) {
    BeforeEach {
        # The watchdog asks for the internet before acting; the test drive is local.
        InModuleScope CloudDrives { Mock Test-CdInternet { $true } }
    }

    It 'brings the engine and the drive back after the engine crashed' {
        InModuleScope CloudDrives {
            $drive = @((Get-CdSettings).drives)[0]
            [void](Start-CdEngine)
            [void](Mount-CdDrive -Drive $drive)
            Add-CdWantedDrives -DriveIds @($drive.id)
            [IO.File]::WriteAllText("$($drive.letter):\before-crash.txt", 'still here')
            Start-Sleep -Seconds 7

            $crashed = (Get-CdEngine).ProcessId
            Stop-Process -Id $crashed -Force
            $deadline = (Get-Date).AddSeconds(15)
            while ((Test-Path -LiteralPath "$($drive.letter):\") -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }

            $cycle = Invoke-CdWatchdog
            $cycle.EngineRestarted | Should -BeTrue
            $cycle.Status | Should -Be 'ok'
            (Get-CdEngine).ProcessId | Should -Not -Be $crashed
            [IO.File]::ReadAllText("$($drive.letter):\before-crash.txt") | Should -Be 'still here'
            (Invoke-CdWatchdog).Results.Count | Should -Be 0
        }
    }

    It 'leaves a drive alone that the user disconnected' {
        InModuleScope CloudDrives {
            $drive = @((Get-CdSettings).drives)[0]
            Start-Sleep -Seconds 2
            [void](Invoke-CdDisconnect -Selection @($drive.id) -Force)
            (Invoke-CdWatchdog).Status | Should -Be 'idle'
            Test-Path -LiteralPath "$($drive.letter):\" | Should -BeFalse
        }
    }

    It 'registers the scheduled task, runs it in the user session and removes it' {
        InModuleScope CloudDrives {
            (Enable-CdWatchdog).Success | Should -BeTrue
            $task = Get-CdWatchdogTask
            $task | Should -Not -BeNullOrEmpty
            @($task.Triggers).Count | Should -Be 3
            $task.Principal.LogonType | Should -Be 'Interactive'
            $task.Actions[0].Arguments | Should -Match 'watchdog --silent'

            $task | Start-ScheduledTask
            $deadline = (Get-Date).AddSeconds(90)
            do {
                Start-Sleep -Seconds 2
                $task = Get-CdWatchdogTask
            } while ($task.State -eq 'Running' -and (Get-Date) -lt $deadline)
            ($task | Get-ScheduledTaskInfo).LastTaskResult | Should -Be 0

            [void](Disable-CdWatchdog)
            Get-CdWatchdogTask | Should -BeNullOrEmpty
        }
    }
}
