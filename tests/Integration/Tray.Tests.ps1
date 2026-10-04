# The real symbol: it is started as a hidden background process (as the sign-in task does), only one runs per
# data folder, it closes on the exit signal, and its sign-in task can be registered and removed.

BeforeDiscovery {
    $script:CanRun = [bool](Get-Command -Name 'Register-ScheduledTask' -ErrorAction SilentlyContinue)
}

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome
    Import-CdModuleForTest
    InModuleScope CloudDrives { Initialize-CdHome }
}

AfterAll {
    InModuleScope CloudDrives {
        try { [void](Disable-CdTray) } catch { Write-Warning $_ }
    }
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'Tray symbol in the user session' -Skip:(-not $script:CanRun) {
    It 'starts once, shows the symbol and closes on request' {
        InModuleScope CloudDrives {
            Test-CdTrayRunning | Should -BeFalse
            Start-CdTrayProcess | Should -BeTrue
            $deadline = (Get-Date).AddSeconds(30)
            while (-not (Test-CdTrayRunning) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
            Test-CdTrayRunning | Should -BeTrue
            Start-CdTrayProcess | Should -BeFalse

            # The symbol logs once it is visible and its first status has been drawn.
            $log = Join-Path (Get-CdContext).LogDir ('clouddrives-{0}.log' -f (Get-Date).ToString('yyyy-MM-dd'))
            $deadline = (Get-Date).AddSeconds(30)
            while (-not ((Test-Path -LiteralPath $log) -and ([IO.File]::ReadAllText($log) -match 'Symbol shown')) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
            [IO.File]::ReadAllText($log) | Should -Match 'Symbol shown'

            Stop-CdTray
            Test-CdTrayRunning | Should -BeFalse
            [IO.File]::ReadAllText($log) | Should -Match 'Symbol closed'
            [IO.File]::ReadAllText($log) | Should -Not -Match '\[ERROR\]'
        }
    }

    It 'registers the sign-in task and removes it again' {
        InModuleScope CloudDrives {
            (Enable-CdTray -NoStart).Success | Should -BeTrue
            $task = Get-CdTrayTask
            $task.Actions[0].Arguments | Should -Match '-STA'
            $task.Actions[0].Arguments | Should -Match ' tray'
            $task.Triggers[0].Delay | Should -Be 'PT10S'
            $task.Settings.ExecutionTimeLimit | Should -Be 'PT0S'
            (Get-CdTray).Enabled | Should -BeTrue
            [void](Disable-CdTray)
            Get-CdTrayTask | Should -BeNullOrEmpty
        }
    }
}
