# WebDAV accounts against a real WebDAV server (rclone serve webdav with a user and a password) and the real engine:
# signing in with user name and password, refusing a wrong password and a wrong address, connecting the account as
# a drive, signing in again and removing it. Nextcloud's browser sign-in is covered by the unit tests.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome
    Import-CdModuleForTest

    $rcloneSource = $env:CLOUDDRIVES_TEST_RCLONE
    if (-not $rcloneSource) { $rcloneSource = Join-Path $env:LOCALAPPDATA 'CloudDrives-dev\rclone\1.75.1\rclone.exe' }
    $script:Served = Join-Path $script:TestHome 'served'
    [void](New-Item -ItemType Directory -Path $script:Served -Force)
    [IO.File]::WriteAllText((Join-Path $script:Served 'welcome.txt'), 'hello from the server')
    $script:DavPassword = 'dav-test-' + [guid]::NewGuid().ToString('N').Substring(0, 10)
    $script:DavServer = InModuleScope CloudDrives -Parameters @{ Source = $rcloneSource; Served = $script:Served; Password = $script:DavPassword } {
        Initialize-CdHome
        $target = Join-Path (Get-CdContext).DepsDir 'rclone\1.75.1'
        if (Test-Path -LiteralPath $Source) {
            [void](New-Item -ItemType Directory -Path $target -Force)
            Copy-Item -LiteralPath $Source -Destination $target -Force
        }
        else {
            [void](Install-CdRclone)
        }
        [void](Start-CdEngine)
        # The WebDAV server: a second rclone serving a local folder.
        $port = Get-CdFreeTcpPort
        $arguments = @('serve', 'webdav', ('"{0}"' -f $Served), '--addr', "127.0.0.1:$port", '--user', 'tester', '--pass', $Password,
            '--config', ('"{0}"' -f (Join-Path (Get-CdContext).Home 'serve.conf')))
        $process = Start-Process -FilePath (Join-Path $target 'rclone.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $deadline = (Get-Date).AddSeconds(20)
        while (-not (Test-CdTcpEndpoint -HostName '127.0.0.1' -Port $port -TimeoutMs 500) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
        [pscustomobject]@{ Port = $port; ProcessId = $process.Id; Url = "http://127.0.0.1:$port/" }
    }
}

AfterAll {
    InModuleScope CloudDrives {
        try { Stop-CdEngine } catch { Write-Warning $_ }
        foreach ($name in @('config', 'rc')) { Remove-CdSecret -Name $name }
    }
    Stop-Process -Id $script:DavServer.ProcessId -Force -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='rclone.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($script:TestHome) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'WebDAV accounts with the real engine' {
    It 'adds an account with user name and password and keeps the password only encrypted' {
        $script:AccountId = InModuleScope CloudDrives -Parameters @{ Server = $script:DavServer; Password = $script:DavPassword } {
            $credential = New-CdWebDavCredential -Url $Server.Url -Kind 'other' -User 'tester' -Password (ConvertTo-CdSecureString -Text $Password)
            $result = Add-CdAccount -Provider 'webdav' -Kind 'other' -Label 'Test DAV' -WebDavLogin $credential
            $result.Success | Should -BeTrue
            $account = Get-CdAccount -Id $result.Data.Account.id
            $account.provider | Should -Be 'webdav'
            $account.kind | Should -Be 'other'
            $account.Contains('clientId') | Should -BeFalse
            $account.identity.id | Should -Be "tester@127.0.0.1:$($Server.Port)"
            $config = Invoke-CdRc -Command 'config/get' -Body @{ name = (Get-CdAccountRemoteName -AccountId $account.id) }
            $config.type | Should -Be 'webdav'
            $config.url | Should -Be $Server.Url
            $config.vendor | Should -Be 'other'
            $config.user | Should -Be 'tester'
            # rclone stores the password obscured, inside the encrypted configuration.
            $config.pass | Should -Not -BeNullOrEmpty
            $config.pass | Should -Not -Be $Password
            [IO.File]::ReadAllText((Get-CdContext).SettingsFile) | Should -Not -Match ([regex]::Escape($Password))
            [IO.File]::ReadAllText((Get-CdContext).RcloneConfig) | Should -Not -Match ([regex]::Escape($Password))
            [IO.File]::ReadAllText((Get-CdContext).RcloneConfig) | Should -Match 'RCLONE_ENCRYPT_V0'
            # Nor do the logs (the engine keeps its log open, so it is read shared).
            foreach ($log in (Get-ChildItem -LiteralPath (Get-CdContext).LogDir -File)) {
                $stream = [IO.File]::Open($log.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                try { (New-Object IO.StreamReader($stream)).ReadToEnd() | Should -Not -Match ([regex]::Escape($Password)) }
                finally { $stream.Dispose() }
            }
            $account.id
        }
    }

    It 'refuses a wrong password with CD-3012 and leaves nothing behind' {
        InModuleScope CloudDrives -Parameters @{ Server = $script:DavServer } {
            $accounts = @((Get-CdSettings).accounts).Count
            $remotes = @(Get-CdRemoteNames).Count
            $credential = New-CdWebDavCredential -Url $Server.Url -Kind 'other' -User 'tester' -Password (ConvertTo-CdSecureString -Text 'wrong-password')
            try { [void](Add-CdAccount -Provider 'webdav' -Kind 'other' -Label 'Wrong' -WebDavLogin $credential); throw 'expected an error' }
            catch { Get-CdErrorCode $_ | Should -Be 'CD-3012' }
            @((Get-CdSettings).accounts).Count | Should -Be $accounts
            @(Get-CdRemoteNames).Count | Should -Be $remotes
        }
    }

    It 'refuses an address without a WebDAV folder with CD-3013' {
        InModuleScope CloudDrives -Parameters @{ Server = $script:DavServer; Password = $script:DavPassword } {
            $credential = New-CdWebDavCredential -Url ($Server.Url + 'missing-folder/') -Kind 'other' -User 'tester' -Password (ConvertTo-CdSecureString -Text $Password)
            try { [void](Add-CdAccount -Provider 'webdav' -Kind 'other' -Label 'Missing' -WebDavLogin $credential); throw 'expected an error' }
            catch { Get-CdErrorCode $_ | Should -Be 'CD-3013' }
        }
    }

    It 'connects the account as a drive; files written there arrive on the server' {
        InModuleScope CloudDrives -Parameters @{ AccountId = $script:AccountId; Served = $script:Served } {
            $letter = Get-CdSuggestedDriveLetter -Preferred @('X', 'V', 'U', 'Y')
            $drive = New-CdDrive -AccountId $AccountId -Letter $letter -Label 'Test DAV'
            (Mount-CdDrive -Drive $drive).Success | Should -BeTrue
            [IO.File]::ReadAllText("${letter}:\welcome.txt") | Should -Be 'hello from the server'
            $content = 'CloudDrives ' + [char]0x00FC + 'ber WebDAV'
            [IO.File]::WriteAllText("${letter}:\from-drive.txt", $content, [Text.Encoding]::UTF8)
            $deadline = (Get-Date).AddSeconds(30)
            while (-not (Test-Path -LiteralPath (Join-Path $Served 'from-drive.txt')) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
            [IO.File]::ReadAllText((Join-Path $Served 'from-drive.txt'), [Text.Encoding]::UTF8) | Should -Be $content
            (Dismount-CdDrive -Drive $drive -Force).Success | Should -BeTrue
        }
    }

    It 'signs in again with the password; a wrong one changes nothing' {
        InModuleScope CloudDrives -Parameters @{ AccountId = $script:AccountId; Server = $script:DavServer; Password = $script:DavPassword } {
            $remote = Get-CdAccountRemoteName -AccountId $AccountId
            $before = (Invoke-CdRc -Command 'config/get' -Body @{ name = $remote }).pass
            $wrong = New-CdWebDavCredential -Url $Server.Url -Kind 'other' -User 'tester' -Password (ConvertTo-CdSecureString -Text 'wrong-password')
            try { [void](Update-CdAccountLogin -AccountId $AccountId -WebDavLogin $wrong); throw 'expected an error' }
            catch { Get-CdErrorCode $_ | Should -Be 'CD-3012' }
            (Invoke-CdRc -Command 'config/get' -Body @{ name = $remote }).pass | Should -Be $before

            $right = New-CdWebDavCredential -Url $Server.Url -Kind 'other' -User 'tester' -Password (ConvertTo-CdSecureString -Text $Password)
            (Update-CdAccountLogin -AccountId $AccountId -WebDavLogin $right).Success | Should -BeTrue
            [void](Get-CdRemoteAbout -RemoteName $remote -CacheSec 0)
            (Get-CdRemoteNames) | Should -Not -Contain (Get-CdSignInRemoteName -AccountId $AccountId)
        }
    }

    It 'removes the account together with its stored password' {
        InModuleScope CloudDrives -Parameters @{ AccountId = $script:AccountId } {
            $result = Remove-CdAccount -Id $AccountId
            $result.Success | Should -BeTrue
            $result.Data.RevokeUrl | Should -BeNullOrEmpty
            (Get-CdRemoteNames) | Should -Not -Contain (Get-CdAccountRemoteName -AccountId $AccountId)
        }
    }
}
