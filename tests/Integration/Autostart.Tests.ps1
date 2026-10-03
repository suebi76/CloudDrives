# Registers a real (test-specific) autostart task, runs it once and removes it again.
# The task runs in the signed-in user's session exactly like the real autostart would.

BeforeDiscovery {
    $script:CanRun = [bool](Get-Command -Name 'Register-ScheduledTask' -ErrorAction SilentlyContinue)
}

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome
    Import-CdModuleForTest
}

AfterAll {
    InModuleScope CloudDrives { try { [void](Disable-CdAutostart) } catch { Write-Warning $_ } }
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'Autostart task' -Skip:(-not $script:CanRun) {
    It 'registers a logon task in the user session with sensible settings' {
        InModuleScope CloudDrives {
            $result = Enable-CdAutostart
            $result.Success | Should -BeTrue
            (Get-CdAutostart).Method | Should -Be 'task'
            $task = Get-CdAutostartTask
            $task.Principal.LogonType | Should -Be 'Interactive'
            $task.Triggers[0].Delay | Should -Be 'PT30S'
            $task.Settings.DisallowStartIfOnBatteries | Should -BeFalse
            $task.Settings.StopIfGoingOnBatteries | Should -BeFalse
            $task.Settings.ExecutionTimeLimit | Should -Be 'PT0S'
            $task.Actions[0].Arguments | Should -Match 'connect --silent --autostart'
        }
    }

    It 'runs the connect command successfully when started' {
        InModuleScope CloudDrives {
            Get-CdAutostartTask | Start-ScheduledTask
            $deadline = (Get-Date).AddSeconds(60)
            do {
                Start-Sleep -Seconds 2
                $task = Get-CdAutostartTask
            } while ($task.State -eq 'Running' -and (Get-Date) -lt $deadline)
            ($task | Get-ScheduledTaskInfo).LastTaskResult | Should -Be 0
            # The run wrote its log into the test home, which proves paths and quoting work.
            $log = Get-ChildItem -LiteralPath (Get-CdContext).LogDir -Filter 'clouddrives-*.log' | Select-Object -First 1
            [IO.File]::ReadAllText($log.FullName) | Should -Match "'connect'"
        }
    }

    It 'removes the task again' {
        InModuleScope CloudDrives {
            [void](Disable-CdAutostart)
            (Get-CdAutostart).Enabled | Should -BeFalse
            Get-CdAutostartTask | Should -BeNullOrEmpty
        }
    }
}
