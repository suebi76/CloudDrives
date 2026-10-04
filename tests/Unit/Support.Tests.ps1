# Support bundle: redaction of personal data, contents and the final search for known secrets.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome
    Import-CdModuleForTest
    InModuleScope CloudDrives { Initialize-CdHome }
}

AfterAll {
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'Support bundle' {
    Context 'Redaction' {
        It 'removes e-mail addresses, the profile path, the user name and the computer name' {
            InModuleScope CloudDrives {
                $text = "a@b.example $env:USERPROFILE\x $env:USERNAME on $env:COMPUTERNAME token=abc12345"
                $redacted = Protect-CdSupportText $text
                $redacted | Should -Not -Match 'a@b\.example'
                $redacted | Should -Match '%USERPROFILE%\\x'
                $redacted | Should -Match '<user> on <pc>'
                $redacted | Should -Match 'token=\*\*\*'
            }
        }

        It 'replaces the user name only as a whole word' {
            InModuleScope CloudDrives {
                $name = $env:USERNAME
                Protect-CdSupportText "x$($name)y and $name" | Should -Be "x$($name)y and <user>"
            }
        }
    }

    Context 'Bundle' {
        BeforeEach {
            InModuleScope CloudDrives {
                $settings = Get-CdSettings
                $settings.accounts = @([ordered]@{ id = 'gw'; provider = 'drive'; kind = 'workspace'; label = 'Schule'; clientId = 'own'; identity = [ordered]@{ id = '111'; name = 'teacher@school.example' } })
                $settings.drives = @([ordered]@{ id = 'gw'; account = 'gw'; label = 'Schule'; letter = 'I'; path = ''; encrypted = $false; autoConnect = $true; readOnly = $false })
                Save-CdSettings -Settings $settings
                $log = Join-Path (Get-CdContext).LogDir ('clouddrives-{0}.log' -f (Get-Date).ToString('yyyy-MM-dd'))
                [IO.File]::WriteAllLines($log, [string[]]@("$((Get-Date).ToString('o')) [INFO ] [abc] [Cli] started for teacher@school.example in $env:USERPROFILE\Documents"))
                Mock Test-CdEngineRunning { $false }
                Mock Find-CdRclone { $null }
                Mock Get-CdWinFsp { $null }
                Mock Get-CdEngine { $null }
                Mock Get-CdKnownSecretValues { 'planted-secret-value-123' }
            }
        }

        It 'contains the diagnosis, the settings without user names and the logs' {
            InModuleScope CloudDrives {
                $zip = Join-Path (Get-CdContext).Home 'bundle.zip'
                $checks = @(New-CdCheck -Area 'accounts' -Name 'Schule' -Message 'teacher@school.example')
                (New-CdSupportBundle -Checks $checks -Path $zip).Success | Should -BeTrue
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $archive = [IO.Compression.ZipFile]::OpenRead($zip)
                try {
                    $names = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
                    $all = foreach ($entry in $archive.Entries) {
                        $reader = New-Object IO.StreamReader($entry.Open())
                        try { $reader.ReadToEnd() } finally { $reader.Dispose() }
                    }
                }
                finally { $archive.Dispose() }
                foreach ($expected in @('README.txt', 'report.txt', 'report.json', 'system.txt', 'settings.json', 'engine.txt')) { $names | Should -Contain $expected }
                @($names | Where-Object { $_ -like 'logs/clouddrives-*.log' }).Count | Should -Be 1
                $text = $all -join "`n"
                $text | Should -Not -Match 'teacher@school\.example'
                $text | Should -Not -Match ([regex]::Escape($env:USERPROFILE))
                $text | Should -Match 'Schule'
            }
        }

        It 'is discarded when a known secret slipped into a log' {
            InModuleScope CloudDrives {
                $log = Join-Path (Get-CdContext).LogDir ('clouddrives-{0}.log' -f (Get-Date).ToString('yyyy-MM-dd'))
                [IO.File]::AppendAllLines($log, [string[]]@('debug dump planted-secret-value-123'))
                $zip = Join-Path (Get-CdContext).Home 'leaky.zip'
                try { [void](New-CdSupportBundle -Checks @(New-CdCheck -Area 'system' -Name 'x') -Path $zip); throw 'expected an error' }
                catch { Get-CdErrorCode $_ | Should -Be 'CD-9003' }
                Test-Path -LiteralPath $zip | Should -BeFalse
            }
        }
    }

    Context 'Known secrets' {
        It 'are collected from the engine as separate values' {
            InModuleScope CloudDrives {
                Mock Test-CdEngineRunning { $true }
                Mock Get-CdSecret { 'config-key-0123456789' } -ParameterFilter { $Name -eq 'config' }
                Mock Get-CdSecret { $null } -ParameterFilter { $Name -eq 'rc' }
                Mock Get-CdRemoteNames { @('cd-gw', 'cd-vault-x') }
                Mock Invoke-CdRc {
                    if ($Body.name -eq 'cd-gw') { return [pscustomobject]@{ type = 'drive'; client_secret = 'client-secret-0123'; token = '{"access_token":"access-0123456789","refresh_token":"rt-012345"}' } }
                    [pscustomobject]@{ type = 'crypt'; password = 'obscured-password-1'; password2 = 'obscured-salt-22' }
                } -ParameterFilter { $Command -eq 'config/get' }
                $values = @(Get-CdKnownSecretValues)
                foreach ($expected in @('config-key-0123456789', 'client-secret-0123', 'access-0123456789', 'rt-012345', 'obscured-password-1', 'obscured-salt-22')) {
                    $values | Should -Contain $expected
                }
            }
        }
    }
}
