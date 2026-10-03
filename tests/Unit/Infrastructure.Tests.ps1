BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome
    Import-CdModuleForTest
}

AfterAll {
    InModuleScope CloudDrives { foreach ($name in @('unit-a', 'unit-b')) { Remove-CdSecret -Name $name } }
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'Command-line quoting' {
    It 'quotes <Raw> as <Expected>' -ForEach @(
        @{ Raw = 'simple'; Expected = 'simple' }
        @{ Raw = ''; Expected = '""' }
        @{ Raw = 'with space'; Expected = '"with space"' }
        @{ Raw = 'C:\Program Files\x\'; Expected = '"C:\Program Files\x\\"' }
        @{ Raw = 'say "hi"'; Expected = '"say \"hi\""' }
        @{ Raw = 'a\"b'; Expected = '"a\\\"b"' }
        @{ Raw = 'cmd /c echo %VAR%'; Expected = '"cmd /c echo %VAR%"' }
    ) {
        InModuleScope CloudDrives -Parameters @{ Value = $Raw; Want = $Expected } {
            ConvertTo-CdQuotedArgument $Value | Should -BeExactly $Want
        }
    }

    It 'passes arguments with spaces and quotes unchanged to a child process' {
        InModuleScope CloudDrives {
            $values = @('C:\Users\Example\Cloud Drives\00 - KI', 'say "hi"', 'trailing\', 'plain')
            $echo = Join-Path (Get-CdContext).Home 'args-echo.ps1'
            [IO.File]::WriteAllText($echo, '[Console]::Out.Write(([Environment]::GetCommandLineArgs() | Select-Object -Skip 4) -join [char]10)')
            $exe = (Get-Process -Id $PID).Path
            $run = Invoke-CdProcess -FilePath $exe -ArgumentList (@('-NoProfile', '-File', $echo) + $values) -TimeoutSec 60
            $run.ExitCode | Should -Be 0 -Because $run.StdErr
            ($run.StdOut -split "`n") | Should -Be $values
        }
    }
}

Describe 'Redaction' {
    It 'masks <Name>' -ForEach @(
        @{ Name = 'JSON tokens'; Text = '{"access_token":"ya29.abc","refresh_token":"1//0short"}'; Forbidden = 'short' }
        @{ Name = 'key=value secrets'; Text = 'client_secret=GOCSPX-verysecret password: hunter2'; Forbidden = 'hunter2' }
        @{ Name = 'bearer headers'; Text = 'Authorization: Bearer eyJhbGciOi.eyJzdWIiOi.c2lnbmF0dXJl'; Forbidden = 'c2lnbmF0dXJl' }
        @{ Name = 'Google access tokens'; Text = 'got ya29.a0FakeTok'; Forbidden = 'a0FakeTok' }
        @{ Name = 'rclone environment'; Text = 'RCLONE_CONFIG_PASS=abc123 RCLONE_RC_PASS=def456'; Forbidden = 'abc123' }
        @{ Name = 'Microsoft refresh tokens'; Text = 'got M.C540_BAY.0.U.-CsomethinglongAndSecret123'; Forbidden = 'somethinglong' }
    ) {
        InModuleScope CloudDrives -Parameters @{ Value = $Text; Bad = $Forbidden } {
            Protect-CdText $Value | Should -Not -Match ([regex]::Escape($Bad))
        }
    }

    It 'leaves harmless text unchanged' {
        InModuleScope CloudDrives {
            $text = 'Bypass ExecutionPolicy; passwordless mount of K: completed in 56 ms'
            Protect-CdText $text | Should -BeExactly $text
        }
    }
}

Describe 'Error classification' {
    It 'classifies "<Text>" as <Code>' -ForEach @(
        @{ Text = "mount failed: cgofuse: cannot find winfsp`nHint: Install WinFsp from https://winfsp.dev/rel/"; Code = 'CD-1002' }
        @{ Text = 'failed to mount FUSE fs: mountpoint path already exists: G:'; Code = 'CD-4001' }
        @{ Text = "Couldn't decrypt configuration, most likely wrong password."; Code = 'CD-2002' }
        @{ Text = 'oauth2: "invalid_grant" "Token has been expired or revoked."'; Code = 'CD-3001' }
        @{ Text = 'googleapi: Error 403: User Rate Limit Exceeded., userRateLimitExceeded'; Code = 'CD-3002' }
        @{ Text = 'Failed to start remote control: failed to init server: listen tcp 127.0.0.1:58999: bind: An attempt was made to access a socket in a way forbidden by its access permissions.'; Code = 'CD-5002' }
        @{ Text = "couldn't fetch token: Post `"https://oauth2.googleapis.com/token`": dial tcp: lookup oauth2.googleapis.com: no such host"; Code = 'CD-5001' }
        @{ Text = 'Error 400: admin_policy_enforced'; Code = 'CD-3003' }
        @{ Text = 'failed to start auth webserver: listen tcp 127.0.0.1:53682: bind: Only one usage of each socket address'; Code = 'CD-3007' }
        @{ Text = 'googleapi: Error 403: The user''s Drive storage quota has been exceeded., storageQuotaExceeded'; Code = 'CD-3006' }
        @{ Text = 'something completely different'; Code = 'CD-9000' }
    ) {
        InModuleScope CloudDrives -Parameters @{ Value = $Text; Want = $Code } {
            Resolve-CdErrorCode -Text $Value | Should -Be $Want
        }
    }

    It 'keeps the code of a CloudDrives exception, also when wrapped' {
        InModuleScope CloudDrives {
            $inner = New-CdException -Code 'CD-4002' -Detail 'test'
            $outer = New-Object System.Exception('outer', $inner)
            Get-CdErrorCode $outer | Should -Be 'CD-4002'
            Get-CdErrorDetail $outer | Should -Be 'test'
        }
    }

    It 'explains errors with localized title and fix' {
        InModuleScope CloudDrives {
            Initialize-CdI18n -Language 'de'
            $info = Get-CdErrorInfo (New-CdException -Code 'CD-1002')
            $info.Title | Should -Not -Match '^\['
            $info.Fix | Should -Not -Match '^\['
            $info.Action | Should -Be 'install-winfsp'
        }
    }
}

Describe 'Naming' {
    It 'creates the slug <Expected> from <Label>' -ForEach @(
        @{ Label = 'Schule (Workspace)'; Expected = 'schule-workspace' }
        @{ Label = 'Google Pro'; Expected = 'google-pro' }
        @{ Label = "Gr$([char]0x00FC)$([char]0x00DF)e $([char]0x00D6)l"; Expected = 'gruesse-oel' }
        @{ Label = "Caf$([char]0x00E9) & Co."; Expected = 'cafe-co' }
        @{ Label = '   '; Expected = '' }
    ) {
        InModuleScope CloudDrives -Parameters @{ Value = $Label; Want = $Expected } {
            ConvertTo-CdSlug -Text $Value | Should -BeExactly $Want
        }
    }

    It 'creates unique ids' {
        InModuleScope CloudDrives {
            New-CdUniqueId -Text 'OneDrive' -Existing @('onedrive', 'onedrive-2') | Should -Be 'onedrive-3'
            New-CdUniqueId -Text '!!!' -Existing @() -Fallback 'drive' | Should -Be 'drive'
        }
    }
}

Describe 'Secrets' {
    It 'stores, reads and deletes a secret in the <Backend> backend' -ForEach @(
        @{ Backend = 'credman' }
        @{ Backend = 'dpapi' }
    ) {
        InModuleScope CloudDrives -Parameters @{ Backend = $Backend } {
            if ($Backend -eq 'dpapi') { $env:CLOUDDRIVES_SECRET_BACKEND = 'dpapi' }
            try {
                Initialize-CdHome
                $value = New-CdRandomSecret
                Set-CdSecret -Name 'unit-a' -Value $value
                Get-CdSecret -Name 'unit-a' | Should -BeExactly $value
                Remove-CdSecret -Name 'unit-a'
                Get-CdSecret -Name 'unit-a' | Should -BeNullOrEmpty
            }
            finally { Remove-Item Env:\CLOUDDRIVES_SECRET_BACKEND -ErrorAction SilentlyContinue }
        }
    }

    It 'never stores DPAPI secrets in clear text' {
        InModuleScope CloudDrives {
            $env:CLOUDDRIVES_SECRET_BACKEND = 'dpapi'
            try {
                Set-CdSecret -Name 'unit-b' -Value 'clear-text-marker-123'
                [IO.File]::ReadAllText((Get-CdSecretFile -Name 'unit-b')) | Should -Not -Match 'clear-text-marker'
            }
            finally {
                Remove-CdSecret -Name 'unit-b'
                Remove-Item Env:\CLOUDDRIVES_SECRET_BACKEND -ErrorAction SilentlyContinue
            }
        }
    }

    It 'uses separate credential names for test homes' {
        InModuleScope CloudDrives {
            (Get-CdContext).IsDefaultHome | Should -BeFalse
            Get-CdSecretTarget -Name 'config' | Should -Match '^CloudDrives\[[0-9a-f]{8}\]:config$'
        }
    }

    It 'creates URL-safe random secrets' {
        InModuleScope CloudDrives {
            $secret = New-CdRandomSecret -Bytes 32
            $secret | Should -Match '^[A-Za-z0-9_-]{43}$'
            New-CdRandomSecret | Should -Not -Be $secret
        }
    }

    It 'derives the same configuration key from the same master password and salt' {
        InModuleScope CloudDrives {
            $salt = [Convert]::ToBase64String([byte[]](1..16))
            $a = ConvertTo-CdConfigKey -MasterPassword 'correct horse' -Salt $salt
            $a | Should -Be (ConvertTo-CdConfigKey -MasterPassword 'correct horse' -Salt $salt)
            $a | Should -Not -Be (ConvertTo-CdConfigKey -MasterPassword 'wrong horse' -Salt $salt)
            $a | Should -Match '^[A-Za-z0-9_-]{43}$'
        }
    }
}

Describe 'Formatting' {
    It 'formats sizes in German' {
        InModuleScope CloudDrives {
            Initialize-CdI18n -Language 'de'
            Format-CdSize 0 | Should -Be '0 B'
            Format-CdSize 1536 | Should -Be '1,5 KB'
            Format-CdSize ([double]2 * 1TB) | Should -Be '2,0 TB'
            Format-CdSize $null | Should -Be '-'
        }
    }
}
