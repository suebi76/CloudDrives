# Signing accounts in again, changing the Google client ID and remembering who is signed in. The engine is
# simulated by an in-memory remote store; the "cloud" maps access tokens to accounts.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome
    Import-CdModuleForTest
}

AfterAll {
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'Accounts' {
    BeforeEach {
        InModuleScope CloudDrives {
            $script:CdQuotaCache = @{}
            $script:TestRemotes = @{
                'cd-gpro' = @{ type = 'drive'; scope = 'drive'; client_id = 'old-client'; client_secret = 'old-secret'; token = '{"access_token":"tok-a1"}' }
            }
            # What the next browser sign-in produces.
            $script:TestSignIn = @{ token = '{"access_token":"tok-a2"}' }
            $script:TestUpdates = New-Object System.Collections.Generic.List[object]

            $settings = Get-CdSettings
            $settings.notifications = 'errors'
            $settings.accounts = @([ordered]@{ id = 'gpro'; provider = 'drive'; kind = 'personal'; label = 'Google Pro'; clientId = 'own'; identity = [ordered]@{ id = '111'; name = 'a@example.com' } })
            $settings.drives = @([ordered]@{ id = 'gpro'; account = 'gpro'; label = 'Google Pro'; letter = 'K'; path = ''; encrypted = $false; autoConnect = $true; readOnly = $false })
            Save-CdSettings -Settings $settings

            Mock Start-CdEngine { }
            Mock Get-CdMountedDrives { @{} }
            Mock Get-CdRemoteNames { @($script:TestRemotes.Keys) }
            Mock Invoke-CdOAuthRemoteCreate {
                $remote = @{ type = $RcloneType }
                foreach ($key in $Parameters.Keys) { $remote[$key] = [string]$Parameters[$key] }
                foreach ($key in $script:TestSignIn.Keys) { $remote[$key] = $script:TestSignIn[$key] }
                $script:TestRemotes[$RemoteName] = $remote
            }
            Mock Invoke-CdRc {
                switch ($Command) {
                    'config/get' { return [pscustomobject]$script:TestRemotes[$Body.name] }
                    'config/update' {
                        $script:TestUpdates.Add($Body)
                        foreach ($key in $Body.parameters.Keys) { $script:TestRemotes[$Body.name][$key] = $Body.parameters[$key] }
                        return $null
                    }
                    'config/create' {
                        $remote = @{ type = $Body.type }
                        foreach ($key in $Body.parameters.Keys) { $remote[$key] = $Body.parameters[$key] }
                        $script:TestRemotes[$Body.name] = $remote
                        return $null
                    }
                    'config/delete' { $script:TestRemotes.Remove($Body.name); return $null }
                    'operations/about' { return [pscustomobject]@{ total = 100; used = 1 } }
                    'fscache/clear' { return $null }
                    default { throw "unexpected RC call $Command" }
                }
            }
            # The cloud: tok-a1 and tok-a2 belong to account 111, tok-b to account 222.
            Mock Invoke-CdApiGet {
                $users = @{ 'tok-a1' = @('111', 'a@example.com'); 'tok-a2' = @('111', 'a@example.com'); 'tok-b' = @('222', 'b@example.com') }
                $user = $users[$AccessToken]
                [pscustomobject]@{ user = [pscustomobject]@{ permissionId = $user[0]; emailAddress = $user[1] } }
            }
        }
    }

    Context 'Signing an account in again' {
        It 'takes over a new sign-in of the same account without asking' {
            InModuleScope CloudDrives {
                $result = Update-CdAccountLogin -AccountId 'gpro' -ConfirmIdentity { throw 'must not ask' }
                $result.Success | Should -BeTrue
                $result.Data.ClientChanged | Should -BeFalse
                $script:TestUpdates.Count | Should -Be 1
                $update = $script:TestUpdates[0]
                $update.name | Should -Be 'cd-gpro'
                $update.opt.nonInteractive | Should -BeTrue
                $update.parameters.token | Should -Be '{"access_token":"tok-a2"}'
                $update.parameters.client_id | Should -Be 'old-client'
                $script:TestRemotes.ContainsKey('cd-signin.gpro') | Should -BeFalse
                (Get-CdAccount -Id 'gpro').identity.name | Should -Be 'a@example.com'
            }
        }

        It 'keeps the previous sign-in when the browser sign-in is cancelled' {
            InModuleScope CloudDrives {
                Mock Invoke-CdOAuthRemoteCreate { throw (New-CdException -Code 'CD-3004') }
                try { [void](Update-CdAccountLogin -AccountId 'gpro'); throw 'expected an error' }
                catch { Get-CdErrorCode $_ | Should -Be 'CD-3004' }
                $script:TestUpdates.Count | Should -Be 0
                $script:TestRemotes['cd-gpro'].token | Should -Be '{"access_token":"tok-a1"}'
            }
        }

        It 'refuses a sign-in with another account and changes nothing' {
            InModuleScope CloudDrives {
                $script:TestSignIn = @{ token = '{"access_token":"tok-b"}' }
                try { [void](Update-CdAccountLogin -AccountId 'gpro'); throw 'expected an error' }
                catch {
                    Get-CdErrorCode $_ | Should -Be 'CD-3009'
                    Get-CdErrorDetail $_ | Should -Match 'b@example\.com'
                }
                $script:TestUpdates.Count | Should -Be 0
                $script:TestRemotes.ContainsKey('cd-signin.gpro') | Should -BeFalse
                $script:TestRemotes['cd-gpro'].token | Should -Be '{"access_token":"tok-a1"}'
            }
        }

        It 'asks who signed in when the previous account is unknown and its sign-in has expired' {
            InModuleScope CloudDrives {
                $settings = Get-CdSettings
                $settings.accounts[0].Remove('identity')
                Save-CdSettings -Settings $settings
                Mock Invoke-CdRc { throw (New-CdException -Code 'CD-3001' -Detail 'invalid_grant') } -ParameterFilter { $Command -eq 'operations/about' -and $Body.fs -eq 'cd-gpro:' }

                $script:TestAsked = $null
                try { [void](Update-CdAccountLogin -AccountId 'gpro' -ConfirmIdentity { param($Identity, $Account) $script:TestAsked = '{0} / {1}' -f $Identity.Name, $Account.label; $false }); throw 'expected an error' }
                catch { Get-CdErrorCode $_ | Should -Be 'CD-3004' }
                $script:TestAsked | Should -Be 'a@example.com / Google Pro'
                $script:TestUpdates.Count | Should -Be 0

                (Update-CdAccountLogin -AccountId 'gpro' -ConfirmIdentity { $true }).Success | Should -BeTrue
                (Get-CdAccount -Id 'gpro').identity.id | Should -Be '111'
            }
        }

        It 'switches to another client ID' {
            InModuleScope CloudDrives {
                $result = Update-CdAccountLogin -AccountId 'gpro' -ClientId 'new-client' -ClientSecret 'new-secret'
                $result.Data.ClientChanged | Should -BeTrue
                Should -Invoke Invoke-CdOAuthRemoteCreate -Times 1 -Exactly -ParameterFilter { $RemoteName -eq 'cd-signin.gpro' -and $Parameters.client_id -eq 'new-client' }
                $script:TestUpdates[0].parameters.client_id | Should -Be 'new-client'
                $script:TestUpdates[0].parameters.client_secret | Should -Be 'new-secret'
                (Get-CdAccount -Id 'gpro').clientId | Should -Be 'own'
            }
        }

        It 'moves an account from the shared rclone client to an own client ID' {
            InModuleScope CloudDrives {
                $script:TestRemotes['cd-gpro'].Remove('client_id')
                $script:TestRemotes['cd-gpro'].Remove('client_secret')
                $settings = Get-CdSettings
                $settings.accounts[0].clientId = 'default'
                Save-CdSettings -Settings $settings
                $result = Update-CdAccountLogin -AccountId 'gpro' -ClientId 'new-client' -ClientSecret 'new-secret'
                $result.Data.ClientChanged | Should -BeTrue
                $script:TestRemotes['cd-gpro'].client_id | Should -Be 'new-client'
                (Get-CdAccount -Id 'gpro').clientId | Should -Be 'own'
            }
        }

        It 'reconnects only the mounted drives of this account' {
            InModuleScope CloudDrives {
                $settings = Get-CdSettings
                $settings.accounts = @($settings.accounts) + @([ordered]@{ id = 'od'; provider = 'onedrive'; kind = 'personal'; label = 'OneDrive' })
                $settings.drives = @($settings.drives) + @(
                    [ordered]@{ id = 'tresor'; account = 'gpro'; label = 'Tresor'; letter = 'V'; path = 'Tresor'; encrypted = $true; autoConnect = $true; readOnly = $false },
                    [ordered]@{ id = 'od'; account = 'od'; label = 'OneDrive'; letter = 'M'; path = ''; encrypted = $false; autoConnect = $true; readOnly = $false })
                Save-CdSettings -Settings $settings
                Mock Get-CdMountedDrives { @{ 'K:' = [pscustomobject]@{ Fs = 'cd-gpro:' }; 'M:' = [pscustomobject]@{ Fs = 'cd-od:' } } }
                Mock Dismount-CdDrive { New-CdResult }
                Mock Wait-CdDriveLetterFree { $true }
                Mock Mount-CdDrive { New-CdResult -Data $Drive }

                $result = Update-CdAccountLogin -AccountId 'gpro'
                @($result.Data.Drives).Count | Should -Be 1
                Should -Invoke Dismount-CdDrive -Times 1 -Exactly -ParameterFilter { $Drive.letter -eq 'K' -and $Force }
                Should -Invoke Mount-CdDrive -Times 1 -Exactly -ParameterFilter { $Drive.letter -eq 'K' }
            }
        }

        It 'restores a missing account remote from the new sign-in' {
            InModuleScope CloudDrives {
                $script:TestRemotes.Remove('cd-gpro')
                (Update-CdAccountLogin -AccountId 'gpro').Success | Should -BeTrue
                $script:TestRemotes['cd-gpro'].type | Should -Be 'drive'
                $script:TestRemotes['cd-gpro'].scope | Should -Be 'drive'
                $script:TestRemotes['cd-gpro'].token | Should -Be '{"access_token":"tok-a2"}'
            }
        }
    }

    Context 'Adding an account' {
        It 'remembers who signed in' {
            InModuleScope CloudDrives {
                $script:TestSignIn = @{ token = '{"access_token":"tok-b"}' }
                $result = Add-CdAccount -Provider 'drive' -Label 'Schule' -Kind 'workspace' -ClientId 'old-client' -ClientSecret 'old-secret'
                $result.Data.Identity.Name | Should -Be 'b@example.com'
                (Get-CdAccount -Id 'schule').identity.id | Should -Be '222'
            }
        }

        It 'refuses the same cloud account a second time' {
            InModuleScope CloudDrives {
                try { [void](Add-CdAccount -Provider 'drive' -Label 'Nochmal Google' -ClientId 'old-client' -ClientSecret 'old-secret'); throw 'expected an error' }
                catch {
                    Get-CdErrorCode $_ | Should -Be 'CD-3010'
                    Get-CdErrorDetail $_ | Should -Match 'Google Pro'
                }
                $script:TestRemotes.ContainsKey('cd-nochmal-google') | Should -BeFalse
                @((Get-CdSettings).accounts).Count | Should -Be 1
            }
        }
    }

    Context 'Accounts added before the identity check' {
        It 'learn who is signed in while their sign-in works, once' {
            InModuleScope CloudDrives {
                $settings = Get-CdSettings
                $settings.accounts[0].Remove('identity')
                Save-CdSettings -Settings $settings
                Update-CdAccountIdentities -AccountIds @('gpro')
                (Get-CdAccount -Id 'gpro').identity.name | Should -Be 'a@example.com'
                Update-CdAccountIdentities -AccountIds @('gpro')
                Should -Invoke Invoke-CdApiGet -Times 1 -Exactly
            }
        }
    }

    Context 'OneDrive identity' {
        It 'comes from the stored drive ID, even when the sign-in has expired' {
            InModuleScope CloudDrives {
                $identity = & (Get-CdProvider -Id 'onedrive').GetIdentity ([pscustomobject]@{ Config = [pscustomobject]@{ drive_id = 'ABC123' }; AccessToken = $null })
                $identity.Id | Should -Be 'abc123'
                $identity.Name | Should -BeNullOrEmpty
                Should -Invoke Invoke-CdApiGet -Times 0 -Exactly
            }
        }

        It 'shows the owner when the sign-in works' {
            InModuleScope CloudDrives {
                Mock Invoke-CdApiGet { [pscustomobject]@{ id = 'abc123'; owner = [pscustomobject]@{ user = [pscustomobject]@{ displayName = 'Test User' } } } }
                $identity = & (Get-CdProvider -Id 'onedrive').GetIdentity ([pscustomobject]@{ Config = [pscustomobject]@{ drive_id = 'abc123' }; AccessToken = 'tok' })
                $identity.Name | Should -Be 'Test User'
            }
        }
    }

    Context 'Cloud API errors' {
        It 'maps HTTP <Status> to <Code>' -ForEach @(
            @{ Status = 401; Code = 'CD-3001' }
            @{ Status = 403; Code = 'CD-3008' }
            @{ Status = 500; Code = 'CD-3008' }
            @{ Status = 0; Code = 'CD-5001' }
        ) {
            InModuleScope CloudDrives -Parameters @{ Status = $Status; Code = $Code } {
                ConvertTo-CdApiErrorCode -Status $Status | Should -Be $Code
            }
        }
    }

    Context 'Command line' {
        It 'finds an account by id, name or drive letter' {
            InModuleScope CloudDrives {
                (Resolve-CdAccountArgument -Value 'gpro').id | Should -Be 'gpro'
                (Resolve-CdAccountArgument -Value 'google pro').id | Should -Be 'gpro'
                (Resolve-CdAccountArgument -Value 'K:').id | Should -Be 'gpro'
                { Resolve-CdAccountArgument -Value 'unknown' } | Should -Throw
            }
        }

        It 'knows the German command names' {
            InModuleScope CloudDrives {
                (ConvertFrom-CdCliArguments -Arguments @('neu-anmelden', 'K')).Command | Should -Be 'relogin'
                (ConvertFrom-CdCliArguments -Arguments @('client-id')).Command | Should -Be 'change-client'
            }
        }
    }

    Context 'Notifications' {
        It 'tell where to sign in again when a sign-in has expired' {
            InModuleScope CloudDrives {
                Mock Show-CdNotification { $true }
                Send-CdConnectSummary -Results @(New-CdResult -Success $false -Code 'CD-3001' -Message 'Google Pro (K:)')
                Should -Invoke Show-CdNotification -Times 1 -Exactly -ParameterFilter { $Message -like ('*' + (Get-CdText 'notify.reloginHint')) }
            }
        }
    }
}
