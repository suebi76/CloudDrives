BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome
    Import-CdModuleForTest
}

AfterAll {
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'Autostart command' {
    It 'runs Windows PowerShell invisibly with "connect --silent"' {
        InModuleScope CloudDrives {
            $command = Get-CdAutostartCommand
            $command.Execute | Should -Match '\\System32\\conhost\.exe$'
            $command.Arguments | Should -Match '^--headless '
            $command.Arguments | Should -Match 'WindowsPowerShell\\v1\.0\\powershell\.exe'
            $command.Arguments | Should -Match '-ExecutionPolicy Bypass -File '
            $command.Arguments | Should -Match 'connect --silent --autostart'
        }
    }

    It 'quotes paths with spaces and passes a custom home' {
        InModuleScope CloudDrives {
            $command = Get-CdAutostartCommand
            $script = Join-Path (Get-CdContext).SrcRoot 'CloudDrives.ps1'
            if ($script -match '\s') { $command.Arguments | Should -Match ([regex]::Escape('"' + $script + '"')) }
            $command.Arguments | Should -Match ([regex]::Escape('--home=' + (Get-CdContext).Home))
        }
    }

    It 'uses a separate task name for test homes' {
        InModuleScope CloudDrives {
            Get-CdAutostartName | Should -Match '^CloudDrives Autostart - [0-9a-f]{8}$'
        }
    }
}

Describe 'Notifications' {
    It 'escapes text for the toast XML' {
        InModuleScope CloudDrives {
            $xml = Get-CdToastXml -Title 'A & B' -Message '<K:> "quoted"'
            $xml | Should -Match 'A &amp; B'
            $xml | Should -Match '&lt;K:&gt; &quot;quoted&quot;'
            { [xml]$xml } | Should -Not -Throw
        }
    }

    It 'notifies <Expected> time(s) for mode "<Mode>" with failures=<HasFailure>' -ForEach @(
        @{ Mode = 'errors'; HasFailure = $false; Expected = 0 }
        @{ Mode = 'errors'; HasFailure = $true; Expected = 1 }
        @{ Mode = 'all'; HasFailure = $false; Expected = 1 }
        @{ Mode = 'off'; HasFailure = $true; Expected = 0 }
    ) {
        InModuleScope CloudDrives -Parameters @{ Mode = $Mode; HasFailure = $HasFailure; Expected = $Expected } {
            Mock Show-CdNotification { $true }
            (Get-CdSettings).notifications = $Mode
            $results = @(New-CdResult -Message 'ok' -Data ([ordered]@{ letter = 'K' }))
            if ($HasFailure) { $results += New-CdResult -Success $false -Code 'CD-3001' -Message 'GW (I:) failed' }
            Send-CdConnectSummary -Results $results
            Should -Invoke Show-CdNotification -Times $Expected -Exactly
        }
    }
}

Describe 'Command line options' {
    It 'reads a custom home with spaces' {
        InModuleScope CloudDrives {
            $parsed = ConvertFrom-CdCliArguments -Arguments @('connect', '--silent', '--home=C:\Some Folder\Home')
            $parsed.Command | Should -Be 'connect'
            $parsed.Flags['home'] | Should -Be 'C:\Some Folder\Home'
            $parsed.Flags['silent'] | Should -BeTrue
        }
    }
}
