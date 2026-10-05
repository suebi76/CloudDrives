# WebDAV accounts: addresses from what the user types, Nextcloud's browser sign-in (Login Flow v2) against a
# simulated server, the remote with user and password, identities, error codes and mount options.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome
    Import-CdModuleForTest
}

AfterAll {
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'WebDAV addresses' {
    It '<Kind>: "<Address>" becomes server <Server> and address <Url>' -ForEach @(
        @{ Kind = 'nextcloud'; Address = 'https://cloud.example.org/remote.php/dav/files/Max%20Mustermann'; Server = 'https://cloud.example.org'; Url = 'https://cloud.example.org/remote.php/dav/files/Max%20Mustermann' }
        @{ Kind = 'nextcloud'; Address = 'https://example.com/nextcloud/remote.php/dav/files/Max%20Mustermann/Documents/'; Server = 'https://example.com/nextcloud'; Url = 'https://example.com/nextcloud/remote.php/dav/files/Max%20Mustermann' }
        @{ Kind = 'nextcloud'; Address = 'cloud.example.org'; Server = 'https://cloud.example.org'; Url = '' }
        @{ Kind = 'nextcloud'; Address = 'https://example.com/nextcloud/index.php/apps/files/?dir=/'; Server = 'https://example.com/nextcloud'; Url = '' }
        @{ Kind = 'nextcloud'; Address = 'https://example.com/nextcloud/remote.php/webdav/'; Server = 'https://example.com/nextcloud'; Url = '' }
        @{ Kind = 'iserv'; Address = 'schule.example.org'; Server = 'https://webdav.schule.example.org'; Url = 'https://webdav.schule.example.org/' }
        @{ Kind = 'iserv'; Address = 'https://webdav.schule.example.org'; Server = 'https://webdav.schule.example.org'; Url = 'https://webdav.schule.example.org/' }
        @{ Kind = 'iserv'; Address = 'https://schule.example.org/webdav'; Server = 'https://schule.example.org'; Url = 'https://schule.example.org/webdav/' }
        @{ Kind = 'iserv'; Address = 'https://schule.example.org/iserv/file/-/Groups'; Server = 'https://webdav.schule.example.org'; Url = 'https://webdav.schule.example.org/' }
        @{ Kind = 'other'; Address = 'https://server.example.com/remote dav/'; Server = 'https://server.example.com'; Url = 'https://server.example.com/remote%20dav/' }
        @{ Kind = 'other'; Address = 'http://127.0.0.1:8080/'; Server = 'http://127.0.0.1:8080'; Url = 'http://127.0.0.1:8080/' }
    ) {
        InModuleScope CloudDrives -Parameters @{ Kind = $Kind; Address = $Address; Server = $Server; Url = $Url } {
            $result = ConvertTo-CdWebDavAddress -Kind $Kind -Address $Address
            $result.Server | Should -Be $Server
            $result.Url | Should -Be $Url
        }
    }

    It 'refuses "<Address>" with CD-3013' -ForEach @(
        @{ Address = 'http://nas.local/webdav' }
        @{ Address = 'ftp://server.example.com/' }
        @{ Address = '' }
        @{ Address = 'https://' }
    ) {
        InModuleScope CloudDrives -Parameters @{ Address = $Address } {
            try { [void](ConvertTo-CdWebDavAddress -Kind 'other' -Address $Address); throw 'expected an error' }
            catch { Get-CdErrorCode $_ | Should -Be 'CD-3013' }
        }
    }

    It 'finds the server of a Nextcloud WebDAV address' {
        InModuleScope CloudDrives {
            Get-CdNextcloudServer -Url 'https://example.com/nextcloud/remote.php/dav/files/a%20b' | Should -Be 'https://example.com/nextcloud'
            Get-CdNextcloudServer -Url 'https://cloud.example.com/remote.php/dav/files/x' | Should -Be 'https://cloud.example.com'
        }
    }
}

Describe 'Signing in to Nextcloud in the browser' {
    BeforeEach {
        InModuleScope CloudDrives {
            $script:TestRequests = New-Object System.Collections.Generic.List[object]
            $script:TestPending = 2
            $script:TestUserAnswer = @{ Status = 200; Text = '{"ocs":{"meta":{"status":"ok"},"data":{"id":"Max Mustermann","display-name":"Max Mustermann"}}}' }
            $script:TestStart = @{ Status = 200; Text = '{"poll":{"token":"poll-token-1","endpoint":"https:\/\/cloud.example.com\/login\/v2\/poll"},"login":"https:\/\/cloud.example.com\/login\/v2\/flow\/abc"}' }
            Mock Invoke-CdHttpRequest {
                $script:TestRequests.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Headers = $Headers; Form = $Form; Credential = $Credential })
                if ($Uri -like '*/index.php/login/v2') { return [pscustomobject]$script:TestStart }
                if ($Uri -like '*/login/v2/poll') {
                    if ($script:TestPending -gt 0) { $script:TestPending--; return [pscustomobject]@{ Status = 404; Text = '' } }
                    return [pscustomobject]@{ Status = 200; Text = '{"server":"https:\/\/cloud.example.com","loginName":"max@example.com","appPassword":"app-password-1"}' }
                }
                if ($Uri -like '*/ocs/v1.php/cloud/user*') { return [pscustomobject]$script:TestUserAnswer }
                throw "unexpected request $Uri"
            }
            Mock Start-Sleep { }
            $script:TestUrls = New-Object System.Collections.Generic.List[string]
            $script:TestProgress = New-Object System.Collections.Generic.List[string]
        }
    }

    It 'gets an app password and builds the WebDAV address from the user ID' {
        InModuleScope CloudDrives {
            $credential = Invoke-CdNextcloudLogin -Server 'https://cloud.example.com' -OnAuthUrl { param([string]$Url) $script:TestUrls.Add($Url) } `
                -OnProgress { param([string]$Status) $script:TestProgress.Add($Status) }
            $credential.Url | Should -Be 'https://cloud.example.com/remote.php/dav/files/Max%20Mustermann'
            $credential.Kind | Should -Be 'nextcloud'
            $credential.Vendor | Should -Be 'nextcloud'
            $credential.User | Should -Be 'max@example.com'
            $credential.Password | Should -BeOfType [System.Security.SecureString]
            (New-Object System.Net.NetworkCredential('', $credential.Password)).Password | Should -Be 'app-password-1'
            $script:TestUrls.ToArray() | Should -Be @('https://cloud.example.com/login/v2/flow/abc')
            @($script:TestProgress | Where-Object { $_ }) | Should -Be @((Get-CdText 'progress.browser'), (Get-CdText 'progress.setup'))
        }
    }

    It 'names itself after this computer, polls with the token and asks for the user ID with the app password' {
        InModuleScope CloudDrives {
            [void](Invoke-CdNextcloudLogin -Server 'https://cloud.example.com/')
            $start = $script:TestRequests[0]
            $start.Method | Should -Be 'POST'
            $start.Uri | Should -Be 'https://cloud.example.com/index.php/login/v2'
            $start.Headers['User-Agent'] | Should -Be ('CloudDrives ({0})' -f $env:COMPUTERNAME)
            $polls = @($script:TestRequests | Where-Object { $_.Uri -like '*/poll' })
            $polls.Count | Should -Be 3
            foreach ($poll in $polls) { $poll.Form['token'] | Should -Be 'poll-token-1' }
            $user = @($script:TestRequests | Where-Object { $_.Uri -like '*/cloud/user*' })[0]
            $user.Credential.UserName | Should -Be 'max@example.com'
            $user.Credential.GetNetworkCredential().Password | Should -Be 'app-password-1'
            $user.Headers['OCS-APIRequest'] | Should -Be 'true'
        }
    }

    It 'uses the login name when Nextcloud does not tell the user ID' {
        InModuleScope CloudDrives {
            $script:TestUserAnswer = @{ Status = 500; Text = '' }
            (Invoke-CdNextcloudLogin -Server 'https://cloud.example.com').Url | Should -Be 'https://cloud.example.com/remote.php/dav/files/max%40example.com'
        }
    }

    It 'refuses a server without Nextcloud sign-in with CD-3014' {
        InModuleScope CloudDrives {
            $script:TestStart = @{ Status = 404; Text = '<html>Not Found</html>' }
            try { [void](Invoke-CdNextcloudLogin -Server 'https://cloud.example.com'); throw 'expected an error' }
            catch { Get-CdErrorCode $_ | Should -Be 'CD-3014' }
        }
    }

    It 'refuses to send the token to another server (CD-3014)' {
        InModuleScope CloudDrives {
            $script:TestStart = @{ Status = 200; Text = '{"poll":{"token":"t","endpoint":"https:\/\/evil.example.org\/poll"},"login":"https:\/\/cloud.example.com\/login\/v2\/flow\/abc"}' }
            try { [void](Invoke-CdNextcloudLogin -Server 'https://cloud.example.com'); throw 'expected an error' }
            catch { Get-CdErrorCode $_ | Should -Be 'CD-3014' }
            @($script:TestRequests | Where-Object { $_.Uri -like '*evil*' }).Count | Should -Be 0
        }
    }

    It 'stops when the user cancels (CD-3004) or the time is up (CD-3005)' {
        InModuleScope CloudDrives {
            try { [void](Invoke-CdNextcloudLogin -Server 'https://cloud.example.com' -ShouldCancel { $true }); throw 'expected an error' }
            catch { Get-CdErrorCode $_ | Should -Be 'CD-3004' }
            try { [void](Invoke-CdNextcloudLogin -Server 'https://cloud.example.com' -TimeoutSec -1); throw 'expected an error' }
            catch { Get-CdErrorCode $_ | Should -Be 'CD-3005' }
        }
    }
}

Describe 'Signing in to Nextcloud with an app password' {
    BeforeEach {
        InModuleScope CloudDrives {
            $script:TestRequests = New-Object System.Collections.Generic.List[object]
            $script:TestExchange = @{ Status = 200; Text = '{"ocs":{"meta":{"status":"ok"},"data":{"apppassword":"exchanged-app-password"}}}' }
            Mock Invoke-CdHttpRequest {
                $script:TestRequests.Add([pscustomobject]@{ Uri = $Uri; Headers = $Headers; Credential = $Credential })
                if ($Uri -like '*/core/getapppassword*') { return [pscustomobject]$script:TestExchange }
                if ($Uri -like '*/ocs/v1.php/cloud/user*') { return [pscustomobject]@{ Status = 200; Text = '{"ocs":{"data":{"id":"Max Mustermann"}}}' } }
                throw "unexpected request $Uri"
            }
            Mock Write-CdLog { }
        }
    }

    It 'exchanges a normal password for an app password of CloudDrives and stores only that' {
        InModuleScope CloudDrives {
            $credential = New-CdNextcloudCredential -Server 'https://cloud.example.com/' -Url '' -User 'max' -Password (ConvertTo-CdSecureString -Text 'normal-password')
            (New-Object System.Net.NetworkCredential('', $credential.Password)).Password | Should -Be 'exchanged-app-password'
            $credential.Url | Should -Be 'https://cloud.example.com/remote.php/dav/files/Max%20Mustermann'
            $exchange = $script:TestRequests[0]
            $exchange.Credential.GetNetworkCredential().Password | Should -Be 'normal-password'
            $exchange.Headers['User-Agent'] | Should -Be ('CloudDrives ({0})' -f $env:COMPUTERNAME)
            # The user ID is asked with the new app password.
            $script:TestRequests[1].Credential.GetNetworkCredential().Password | Should -Be 'exchanged-app-password'
        }
    }

    It 'keeps an app password as entered (Nextcloud answers 403) and takes over the given WebDAV address' {
        InModuleScope CloudDrives {
            $script:TestExchange = @{ Status = 403; Text = '' }
            $url = 'https://cloud.example.com/remote.php/dav/files/Max%20Mustermann'
            $credential = New-CdNextcloudCredential -Server 'https://cloud.example.com' -Url $url -User 'max' -Password (ConvertTo-CdSecureString -Text 'app-password-2')
            (New-Object System.Net.NetworkCredential('', $credential.Password)).Password | Should -Be 'app-password-2'
            $credential.Url | Should -Be $url
            $credential.Vendor | Should -Be 'nextcloud'
            $script:TestRequests.Count | Should -Be 1
        }
    }

    It 'stops at a refused password (CD-3012) without further attempts' {
        InModuleScope CloudDrives {
            $script:TestExchange = @{ Status = 401; Text = '' }
            try { [void](New-CdNextcloudCredential -Server 'https://cloud.example.com' -Url '' -User 'max' -Password (ConvertTo-CdSecureString -Text 'wrong')); throw 'expected an error' }
            catch { Get-CdErrorCode $_ | Should -Be 'CD-3012' }
            $script:TestRequests.Count | Should -Be 1
        }
    }
}

Describe 'WebDAV remotes' {
    BeforeEach {
        InModuleScope CloudDrives {
            $script:TestBodies = New-Object System.Collections.Generic.List[object]
            $script:TestLog = New-Object System.Collections.Generic.List[string]
            Mock Invoke-CdRc { $script:TestBodies.Add($Body); $null } -ParameterFilter { $Command -eq 'config/create' }
            Mock Remove-CdRemoteIfPresent { }
            Mock Write-CdLog { $script:TestLog.Add([string]$Message) }
            $script:TestCredential = New-CdWebDavCredential -Url 'https://webdav.example.org/' -Kind 'iserv' -User 'max.mustermann' -Password (ConvertTo-CdSecureString -Text 'secret-pass-42')
        }
    }

    It 'hands url, user and password to rclone, which obscures the password' {
        InModuleScope CloudDrives {
            Mock Get-CdRemoteAbout { [pscustomobject]@{ used = 1 } }
            New-CdWebDavRemote -RemoteName 'cd-iserv' -Login $script:TestCredential
            $body = $script:TestBodies[0]
            $body.type | Should -Be 'webdav'
            $body.opt.obscure | Should -BeTrue
            $body.opt.nonInteractive | Should -BeTrue
            $body.parameters.url | Should -Be 'https://webdav.example.org/'
            $body.parameters.vendor | Should -Be 'other'
            $body.parameters.user | Should -Be 'max.mustermann'
            Should -Invoke Remove-CdRemoteIfPresent -Times 0 -Exactly
            # The password is not kept in the request after use, and never logged.
            $body.parameters.pass | Should -BeNullOrEmpty
            foreach ($line in $script:TestLog) { $line | Should -Not -Match 'secret-pass-42' }
        }
    }

    It 'reports a refused sign-in as <Code> and removes the remote' -ForEach @(
        @{ Text = "couldn't list files: No public access to this resource.: Sabre\DAV\Exception\NotAuthenticated: 401 Unauthorized"; Code = 'CD-3012' }
        @{ Text = 'error listing: : 401 Unauthorized'; Code = 'CD-3012' }
        @{ Text = 'error listing: File not found: 404 Not Found'; Code = 'CD-3013' }
    ) {
        InModuleScope CloudDrives -Parameters @{ Text = $Text; Code = $Code } {
            $script:TestAboutText = $Text
            Mock Get-CdRemoteAbout { throw (New-CdException -Code (Resolve-CdErrorCode -Text $script:TestAboutText) -Detail $script:TestAboutText) }
            try { New-CdWebDavRemote -RemoteName 'cd-iserv' -Login $script:TestCredential; throw 'expected an error' }
            catch { Get-CdErrorCode $_ | Should -Be $Code }
            Should -Invoke Remove-CdRemoteIfPresent -Times 1 -Exactly -ParameterFilter { $Name -eq 'cd-iserv' }
        }
    }

    It 'needs a credential to add a WebDAV account' {
        InModuleScope CloudDrives {
            Mock Start-CdEngine { }
            Mock Backup-CdRcloneConfig { }
            try { [void](Add-CdAccount -Provider 'webdav' -Kind 'iserv' -Label 'IServ'); throw 'expected an error' }
            catch { Get-CdErrorCode $_ | Should -Be 'CD-2006' }
        }
    }
}

Describe 'WebDAV accounts' {
    It 'are the user at the address' {
        InModuleScope CloudDrives {
            $identity = & (Get-CdProvider -Id 'webdav').GetIdentity ([pscustomobject]@{ Config = [pscustomobject]@{ url = 'https://webdav.schule.example.org/'; user = 'max.mustermann' } })
            $identity.Id | Should -Be 'max.mustermann@webdav.schule.example.org'
            $identity.Name | Should -Be 'max.mustermann @ webdav.schule.example.org'
            & (Get-CdProvider -Id 'webdav').GetIdentity ([pscustomobject]@{ Config = [pscustomobject]@{ url = ''; user = 'max.mustermann' } }) | Should -BeNullOrEmpty
        }
    }

    It 'point to the security settings of Nextcloud for revoking the app password' {
        InModuleScope CloudDrives {
            $config = [pscustomobject]@{ url = 'https://cloud.example.com/remote.php/dav/files/Max%20Mustermann' }
            & (Get-CdProvider -Id 'webdav').GetRevokeUrl ([ordered]@{ kind = 'nextcloud' }) $config | Should -Be 'https://cloud.example.com/settings/user/security'
            & (Get-CdProvider -Id 'webdav').GetRevokeUrl ([ordered]@{ kind = 'iserv' }) $config | Should -Be ''
        }
    }

    It 'classify "<Text>" as <Code>' -ForEach @(
        @{ Text = "couldn't list files: Username or password was incorrect: Sabre\DAV\Exception\NotAuthenticated: 401 Unauthorized"; Code = 'CD-3012' }
        @{ Text = 'ERROR : Groups: error listing: : 401 Unauthorized'; Code = 'CD-3012' }
        @{ Text = 'HTTP error 401 (401 Unauthorized) returned body: "{\"error\":{\"code\":\"InvalidAuthenticationToken\"}}"'; Code = 'CD-3001' }
        @{ Text = 'googleapi: Error 401: Request had invalid authentication credentials., authError'; Code = 'CD-9000' }
    ) {
        InModuleScope CloudDrives -Parameters @{ Text = $Text; Code = $Code } {
            Resolve-CdErrorCode -Text $Text | Should -Be $Code
        }
    }

    It 're-read directory listings after two minutes, as WebDAV reports no changes' {
        InModuleScope CloudDrives {
            $settings = New-CdDefaultSettings
            $account = [ordered]@{ id = 'iserv'; provider = 'webdav'; kind = 'iserv'; label = 'IServ' }
            $drive = [ordered]@{ id = 'iserv'; account = 'iserv'; label = 'IServ'; letter = 'X'; path = ''; encrypted = $false; autoConnect = $true; readOnly = $false }
            (Get-CdMountOptions -Drive $drive -Account $account -Settings $settings).dir_cache_time | Should -Be '2m'
        }
    }
}
