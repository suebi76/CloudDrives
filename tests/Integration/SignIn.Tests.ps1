# rclone's configuration of a sign-in with the real engine, without browser: the remotes start with a token, so
# rclone asks whether to replace it (no) and then its questions after the sign-in, which CloudDrives answers.

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

Describe 'Configuring a sign-in with the real engine' {
    BeforeEach {
        InModuleScope CloudDrives {
            foreach ($name in @(Get-CdRemoteNames)) { Remove-CdRemote -Name $name }
            $script:TestToken = '{"access_token":"test-access","token_type":"Bearer","refresh_token":"r1","expiry":"2099-01-01T00:00:00Z"}'
        }
    }

    It 'completes Google Drive''s configuration with the provider''s answers' {
        InModuleScope CloudDrives {
            $answers = @{ config_refresh_token = 'false' }
            $google = (Get-CdProvider -Id 'drive').ConfigAnswers
            foreach ($key in $google.Keys) { $answers[$key] = $google[$key] }
            $parameters = [ordered]@{ scope = 'drive'; client_id = 'test-client'; client_secret = 'test-secret'; token = $script:TestToken }
            $watch = [Diagnostics.Stopwatch]::StartNew()
            Invoke-CdOAuthRemoteCreate -RemoteName 'cd-g' -RcloneType 'drive' -Parameters $parameters -Answers $answers -TimeoutSec 60
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 30
            $config = Invoke-CdRc -Command 'config/get' -Body @{ name = 'cd-g' }
            $config.type | Should -Be 'drive'
            $config.client_id | Should -Be 'test-client'
            $config.token | Should -Be $script:TestToken
            # Answers to rclone's questions are not stored.
            @($config.PSObject.Properties.Name | Where-Object { $_ -like 'config_*' }) | Should -BeNullOrEmpty
            # The configuration is finished: no job of it is left running (the listing itself runs as a job).
            @((Invoke-CdRc -Command 'job/list').runningIds).Count | Should -BeLessOrEqual 1
        }
    }

    It 'ends OneDrive''s configuration with an error when the drive cannot be determined, instead of running for ever' {
        InModuleScope CloudDrives {
            # The made-up token cannot list drives (or there is no network): rclone reports an error and asks for a
            # drive ID by hand, which CloudDrives cannot answer.
            $answers = @{ config_refresh_token = 'false' }
            $onedrive = (Get-CdProvider -Id 'onedrive').ConfigAnswers
            foreach ($key in $onedrive.Keys) { $answers[$key] = $onedrive[$key] }
            $code = $null
            try { Invoke-CdOAuthRemoteCreate -RemoteName 'cd-od' -RcloneType 'onedrive' -Parameters @{ token = $script:TestToken } -Answers $answers -TimeoutSec 240 }
            catch { $code = Get-CdErrorCode $_ }
            $code | Should -Not -BeNullOrEmpty
            $code | Should -Not -Be 'CD-3005'
            (Get-CdRemoteNames) | Should -Not -Contain 'cd-od'
            @((Invoke-CdRc -Command 'job/list').runningIds).Count | Should -BeLessOrEqual 1
        }
    }
}
