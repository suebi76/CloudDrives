# Signing in again against the real rclone engine: the new sign-in must reach the account's remote without
# rclone's configuration dialog (no browser, no network), and the encrypted configuration must stay
# encrypted. Only the browser sign-in and the provider's "who am I" request are simulated.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome
    Import-CdModuleForTest

    $rcloneSource = $env:CLOUDDRIVES_TEST_RCLONE
    if (-not $rcloneSource) { $rcloneSource = Join-Path $env:LOCALAPPDATA 'CloudDrives-dev\rclone\1.75.1\rclone.exe' }
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
        [void](Start-CdEngine)
    }
}

AfterAll {
    InModuleScope CloudDrives {
        try { Stop-CdEngine } catch { Write-Warning $_ }
        foreach ($name in @('config', 'rc')) { Remove-CdSecret -Name $name }
    }
    Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($script:TestHome) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'Signing in again with the real engine' {
    BeforeEach {
        InModuleScope CloudDrives {
            foreach ($name in @(Get-CdRemoteNames)) { Remove-CdRemote -Name $name }
            $remotes = @(
                @{ name = 'cd-gpro'; type = 'drive'; parameters = [ordered]@{ scope = 'drive'; client_id = 'old-client'; client_secret = 'old-secret'; token = '{"access_token":"tok-a1"}' } }
                @{ name = 'cd-od'; type = 'onedrive'; parameters = [ordered]@{ drive_id = 'abc123'; drive_type = 'personal'; token = '{"access_token":"tok-o1"}' } }
            )
            foreach ($remote in $remotes) {
                [void](Invoke-CdRc -Command 'config/create' -Body @{ name = $remote.name; type = $remote.type; parameters = $remote.parameters; opt = @{ nonInteractive = $true; noObscure = $true } })
            }
            $settings = Get-CdSettings
            $settings.accounts = @(
                [ordered]@{ id = 'gpro'; provider = 'drive'; kind = 'personal'; label = 'Google Pro'; clientId = 'own'; identity = [ordered]@{ id = '111'; name = 'a@example.com' } }
                [ordered]@{ id = 'od'; provider = 'onedrive'; kind = 'personal'; label = 'OneDrive' }
            )
            $settings.drives = @()
            Save-CdSettings -Settings $settings
            $script:TestSignIn = @{ token = '{"access_token":"tok-a2"}' }

            # The browser sign-in: rclone receives the token like after a real OAuth flow.
            Mock Invoke-CdOAuthRemoteCreate {
                $values = [ordered]@{}
                foreach ($key in $Parameters.Keys) { $values[$key] = [string]$Parameters[$key] }
                foreach ($key in $script:TestSignIn.Keys) { $values[$key] = $script:TestSignIn[$key] }
                [void](Invoke-CdRc -Command 'config/create' -Body @{ name = $RemoteName; type = $RcloneType; parameters = $values; opt = @{ nonInteractive = $true; noObscure = $true } })
            }
            # No real cloud: storage and "who am I" answers come from here.
            Mock Get-CdRemoteAbout { [pscustomobject]@{ total = 100; used = 1 } }
            Mock Invoke-CdApiGet {
                $users = @{ 'tok-a1' = '111'; 'tok-a2' = '111'; 'tok-b' = '222' }
                [pscustomobject]@{ user = [pscustomobject]@{ permissionId = $users[$AccessToken]; emailAddress = "user$($users[$AccessToken])@example.com" } }
            }
        }
    }

    It 'stores the new sign-in in the account remote and removes the temporary one' {
        InModuleScope CloudDrives {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            (Update-CdAccountLogin -AccountId 'gpro').Success | Should -BeTrue
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 10
            $config = Invoke-CdRc -Command 'config/get' -Body @{ name = 'cd-gpro' }
            $config.token | Should -Be '{"access_token":"tok-a2"}'
            $config.client_id | Should -Be 'old-client'
            $config.scope | Should -Be 'drive'
            @(Get-CdRemoteNames) | Should -Not -Contain 'cd-signin.gpro'
            Test-CdRcloneConfigEncrypted | Should -BeTrue
        }
    }

    It 'leaves the account remote untouched when another account signed in' {
        InModuleScope CloudDrives {
            $script:TestSignIn = @{ token = '{"access_token":"tok-b"}' }
            try { [void](Update-CdAccountLogin -AccountId 'gpro'); throw 'expected an error' }
            catch { Get-CdErrorCode $_ | Should -Be 'CD-3009' }
            (Invoke-CdRc -Command 'config/get' -Body @{ name = 'cd-gpro' }).token | Should -Be '{"access_token":"tok-a1"}'
            @(Get-CdRemoteNames) | Should -Not -Contain 'cd-signin.gpro'
        }
    }

    It 'switches the client ID together with the sign-in' {
        InModuleScope CloudDrives {
            (Update-CdAccountLogin -AccountId 'gpro' -ClientId 'new-client' -ClientSecret 'new-secret').Data.ClientChanged | Should -BeTrue
            $config = Invoke-CdRc -Command 'config/get' -Body @{ name = 'cd-gpro' }
            $config.client_id | Should -Be 'new-client'
            $config.client_secret | Should -Be 'new-secret'
            $config.token | Should -Be '{"access_token":"tok-a2"}'
        }
    }

    It 'keeps the drive of a OneDrive account and learns its identity from it' {
        InModuleScope CloudDrives {
            $script:TestSignIn = @{ token = '{"access_token":"tok-o2"}'; drive_id = 'abc123'; drive_type = 'personal' }
            Mock Invoke-CdApiGet { [pscustomobject]@{ id = 'abc123'; owner = [pscustomobject]@{ user = [pscustomobject]@{ displayName = 'Test User' } } } }
            $result = Update-CdAccountLogin -AccountId 'od'
            $result.Data.Identity.Id | Should -Be 'abc123'
            $config = Invoke-CdRc -Command 'config/get' -Body @{ name = 'cd-od' }
            $config.token | Should -Be '{"access_token":"tok-o2"}'
            $config.drive_id | Should -Be 'abc123'
            $config.drive_type | Should -Be 'personal'
            (Get-CdAccount -Id 'od').identity.name | Should -Be 'Test User'
        }
    }

    It 'refuses another OneDrive although the previous sign-in is unusable' {
        InModuleScope CloudDrives {
            # Without a stored identity the previous drive ID still identifies the account.
            $script:TestSignIn = @{ token = '{"access_token":"tok-o3"}'; drive_id = 'fff999'; drive_type = 'personal' }
            Mock Get-CdRemoteAbout { throw (New-CdException -Code 'CD-3001' -Detail 'invalid_grant') } -ParameterFilter { $RemoteName -eq 'cd-od' }
            Mock Invoke-CdApiGet { [pscustomobject]@{ id = 'fff999'; owner = [pscustomobject]@{ user = [pscustomobject]@{ displayName = 'Someone Else' } } } }
            try { [void](Update-CdAccountLogin -AccountId 'od' -ConfirmIdentity { throw 'must not ask' }); throw 'expected an error' }
            catch { Get-CdErrorCode $_ | Should -Be 'CD-3009' }
            (Invoke-CdRc -Command 'config/get' -Body @{ name = 'cd-od' }).drive_id | Should -Be 'abc123'
        }
    }
}
