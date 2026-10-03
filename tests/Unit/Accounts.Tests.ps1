BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome
    Import-CdModuleForTest
}

AfterAll {
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'Google client IDs' {
    It 'accepts "<Value>": <Valid>' -ForEach @(
        @{ Value = '123456789012-abcdefghijklmnopqrstuvwxyz012345.apps.googleusercontent.com'; Valid = $true }
        @{ Value = '  123456789012-abc123.apps.googleusercontent.com  '; Valid = $true }
        @{ Value = 'GOCSPX-not-a-client-id'; Valid = $false }
        @{ Value = 'abc.apps.googleusercontent.com'; Valid = $false }
        @{ Value = ''; Valid = $false }
    ) {
        InModuleScope CloudDrives -Parameters @{ Value = $Value; Valid = $Valid } {
            Test-CdGoogleClientId -ClientId $Value | Should -Be $Valid
        }
    }
}

Describe 'Downloaded Google client files' {
    BeforeAll {
        $script:Downloads = Join-Path $script:TestHome 'downloads'
        [void](New-Item -ItemType Directory -Path $script:Downloads -Force)
        $desktop = '{"installed":{"client_id":"123456789012-desktopclient.apps.googleusercontent.com","client_secret":"fake-secret-for-tests","redirect_uris":["http://localhost"]}}'
        $web = '{"web":{"client_id":"123456789012-webclient.apps.googleusercontent.com","client_secret":"fake-web-secret"}}'
        [IO.File]::WriteAllText((Join-Path $script:Downloads 'client_secret_123456789012-desktopclient.apps.googleusercontent.com.json'), $desktop)
        Start-Sleep -Milliseconds 50
        [IO.File]::WriteAllText((Join-Path $script:Downloads 'client_secret_123456789012-webclient.apps.googleusercontent.com.json'), $web)
        [IO.File]::WriteAllText((Join-Path $script:Downloads 'client_secret_broken.json'), '{ not json')
    }

    It 'reads client ID and secret of a desktop client' {
        InModuleScope CloudDrives -Parameters @{ Folder = $script:Downloads } {
            $client = Read-CdGoogleClientFile -Path (Join-Path $Folder 'client_secret_123456789012-desktopclient.apps.googleusercontent.com.json')
            $client.ClientId | Should -Be '123456789012-desktopclient.apps.googleusercontent.com'
            $client.ClientSecret | Should -Be 'fake-secret-for-tests'
        }
    }

    It 'ignores web clients and damaged files and finds the desktop client' {
        InModuleScope CloudDrives -Parameters @{ Folder = $script:Downloads } {
            Read-CdGoogleClientFile -Path (Join-Path $Folder 'client_secret_123456789012-webclient.apps.googleusercontent.com.json') | Should -BeNullOrEmpty
            Read-CdGoogleClientFile -Path (Join-Path $Folder 'client_secret_broken.json') | Should -BeNullOrEmpty
            (Find-CdGoogleClientFile -Folder $Folder).ClientId | Should -Be '123456789012-desktopclient.apps.googleusercontent.com'
        }
    }

    It 'returns nothing when no client file exists' {
        InModuleScope CloudDrives {
            Find-CdGoogleClientFile -Folder (Join-Path (Get-CdContext).Home 'empty-folder') | Should -BeNullOrEmpty
        }
    }
}

Describe 'Quota for status displays' {
    BeforeEach {
        InModuleScope CloudDrives { $script:CdQuotaCache = @{} }
    }

    It 'returns the quota and serves repeated requests from the cache' {
        InModuleScope CloudDrives {
            Mock Invoke-CdRc { [pscustomobject]@{ total = 16106127360; used = 0 } } -ParameterFilter { $Command -eq 'operations/about' }
            (Get-CdAccountQuota -AccountId 'gw').total | Should -Be 16106127360
            (Get-CdAccountQuota -AccountId 'gw').total | Should -Be 16106127360
            Should -Invoke Invoke-CdRc -Times 1 -Exactly
        }
    }

    It 'uses a short timeout so a throttled provider cannot block the menu' {
        InModuleScope CloudDrives {
            Mock Invoke-CdRc { [pscustomobject]@{ total = 1; used = 0 } } -ParameterFilter { $Command -eq 'operations/about' }
            [void](Get-CdAccountQuota -AccountId 'gw')
            Should -Invoke Invoke-CdRc -Times 1 -Exactly -ParameterFilter { $TimeoutSec -le 10 }
        }
    }

    It 'remembers failures for a while instead of retrying on every refresh' {
        InModuleScope CloudDrives {
            Mock Invoke-CdRc { throw (New-CdException -Code 'CD-5003' -Detail 'timeout') } -ParameterFilter { $Command -eq 'operations/about' }
            Get-CdAccountQuota -AccountId 'gw' | Should -BeNullOrEmpty
            Get-CdAccountQuota -AccountId 'gw' | Should -BeNullOrEmpty
            Should -Invoke Invoke-CdRc -Times 1 -Exactly
        }
    }
}
