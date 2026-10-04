# rclone's configuration of a sign-in, step by step. The engine is simulated: each step returns the next question,
# an error or the end, like rclone's state machine does for OneDrive and Google Drive after the browser sign-in.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelper.ps1')
    $script:TestHome = New-CdTestHome
    Import-CdModuleForTest
}

AfterAll {
    Remove-CdTestHome -Path $script:TestHome
}

Describe 'Configuring a sign-in step by step' {
    BeforeEach {
        InModuleScope CloudDrives {
            # A question as the RC API returns it: Default keeps its type, DefaultStr is rclone's text form.
            $script:TestQuestion = {
                param([string]$State, [string]$Name, [object]$Default, [object[]]$Examples = @(), [bool]$Required = $false)
                $text = '<nil>'
                if ($Default -is [bool]) { $text = ([string]$Default).ToLowerInvariant() }
                elseif ($null -ne $Default) { $text = [string]$Default }
                $option = [pscustomobject]@{ Name = $Name; Default = $Default; DefaultStr = $text; Examples = @($Examples); Required = $Required }
                [pscustomobject]@{ State = $State; Option = $option; Error = ''; Result = '' }
            }
            $script:TestError = { param([string]$State, [string]$Text) [pscustomobject]@{ State = $State; Option = $null; Error = $Text; Result = '' } }
            $script:TestDone = [pscustomobject]@{ State = ''; Option = $null; Error = ''; Result = '' }

            # OneDrive after the sign-in: type of connection, drive, drive check. Drives in TestFailing fail the check.
            $script:TestFailing = @()
            $script:TestDrives = @(
                [pscustomobject]@{ Value = 'library'; Help = 'Documents (documentLibrary)' }
                [pscustomobject]@{ Value = 'drive-a'; Help = 'OneDrive (personal)' }
                [pscustomobject]@{ Value = 'drive-b'; Help = 'OneDrive (personal)' }
            )
            $script:TestStep = {
                param([string]$State, [string]$Result)
                switch ($State) {
                    { $_ -in '', 'choose_type' } { return (& $script:TestQuestion 'choose_type_done' 'config_type' 'onedrive' @([pscustomobject]@{ Value = 'onedrive' }, [pscustomobject]@{ Value = 'sharepoint' })) }
                    'choose_type_done' { return (& $script:TestQuestion 'driveid_final' 'config_driveid' 'library' $script:TestDrives) }
                    'driveid_final' {
                        if ($script:TestFailing -contains $Result) { return (& $script:TestError 'choose_type' "Failed to query root for drive `"$Result`": HTTP error 404 (404 Not Found)") }
                        return (& $script:TestQuestion 'driveid_final_end' 'config_drive_ok' $true @())
                    }
                    'driveid_final_end' { return $script:TestDone }
                }
                throw "unexpected state '$State'"
            }

            # The engine: every configuration step runs as a job; a step can keep a browser sign-in open for a
            # few polls (TestPolls) - the job stops when asked to.
            $script:TestCalls = New-Object System.Collections.Generic.List[object]
            $script:TestOutput = $null
            $script:TestPolls = 0
            $script:TestSigningIn = $false
            $script:TestSignInPolls = 1000
            $script:TestJobError = $null
            $script:TestUrls = New-Object System.Collections.Generic.List[string]
            Mock Invoke-CdRc {
                switch ($Command) {
                    { $_ -in 'config/create', 'config/update' } {
                        $state = ''
                        $result = ''
                        if ($Body.opt.continue) { $state = [string]$Body.opt.state; $result = [string]$Body.opt.result }
                        $script:TestCalls.Add([pscustomobject]@{ Command = $Command; State = $state; Result = $result; Body = $Body })
                        $script:TestOutput = & $script:TestStep $state $result
                        return [pscustomobject]@{ jobid = $script:TestCalls.Count }
                    }
                    'job/status' {
                        if ($script:TestPolls -gt 0) { $script:TestPolls--; return [pscustomobject]@{ finished = $false } }
                        $script:TestSigningIn = $false
                        if ($script:TestJobError) { return [pscustomobject]@{ finished = $true; success = $false; error = $script:TestJobError } }
                        return [pscustomobject]@{ finished = $true; success = $true; output = $script:TestOutput }
                    }
                    'config/oauthstatus' {
                        if ($script:TestSigningIn -and $script:TestSignInPolls -gt 0) {
                            $script:TestSignInPolls--
                            return [pscustomobject]@{ status = 'running'; authUrl = 'http://127.0.0.1:53682/auth?state=test' }
                        }
                        return [pscustomobject]@{ status = 'stopped' }
                    }
                    'config/oauthstop' { $script:TestSigningIn = $false; return $null }
                    'job/stop' { $script:TestPolls = 0; return $null }
                    default { throw "unexpected RC call $Command" }
                }
            }
            Mock Remove-CdRemoteIfPresent { }
            # Microsoft Graph is not asked in these tests; the drives come in the order rclone offers them.
            Mock Get-CdOneDriveOwnDriveId { $null }
            $script:TestProgress = New-Object System.Collections.Generic.List[string]
            Mock Start-Sleep { }
            $script:TestAnswers = (Get-CdProvider -Id 'onedrive').ConfigAnswers
        }
    }

    It 'answers OneDrive''s questions: OneDrive, the user''s own drive, confirmed' {
        InModuleScope CloudDrives {
            Invoke-CdOAuthRemoteCreate -RemoteName 'cd-od' -RcloneType 'onedrive' -Answers $script:TestAnswers
            @($script:TestCalls | ForEach-Object { "$($_.State)=$($_.Result)" }) |
                Should -Be @('=', 'choose_type_done=onedrive', 'driveid_final=drive-a', 'driveid_final_end=true')
            Should -Invoke Remove-CdRemoteIfPresent -Times 0 -Exactly
        }
    }

    It 'runs rclone''s configuration non-interactively and signs in through the local web server' {
        InModuleScope CloudDrives {
            Invoke-CdOAuthRemoteCreate -RemoteName 'cd-od' -RcloneType 'onedrive' -Parameters @{ client_id = 'own-id' } -Answers $script:TestAnswers
            $create = $script:TestCalls[0].Body
            $create.type | Should -Be 'onedrive'
            $create.opt.nonInteractive | Should -BeTrue
            $create._async | Should -BeTrue
            $create.parameters.client_id | Should -Be 'own-id'
            $create.parameters.config_is_local | Should -Be 'true'
            $create.parameters.config_auth_no_browser | Should -Be 'true'
            foreach ($call in @($script:TestCalls | Select-Object -Skip 1)) {
                $call.Command | Should -Be 'config/update'
                $call.Body.opt.nonInteractive | Should -BeTrue
                $call.Body.opt.continue | Should -BeTrue
                $call.Body._async | Should -BeTrue
                $call.Body.parameters.Contains('client_id') | Should -BeFalse
            }
        }
    }

    It 'tries the next drive when rclone reports that a drive failed its check' {
        InModuleScope CloudDrives {
            $script:TestFailing = @('drive-a')
            Invoke-CdOAuthRemoteCreate -RemoteName 'cd-od' -RcloneType 'onedrive' -Answers $script:TestAnswers
            @($script:TestCalls | ForEach-Object { "$($_.State)=$($_.Result)" }) | Should -Be @(
                '=', 'choose_type_done=onedrive', 'driveid_final=drive-a',
                'choose_type=', 'choose_type_done=onedrive', 'driveid_final=drive-b', 'driveid_final_end=true')
        }
    }

    It 'ends with the error rclone reports once every drive failed, instead of starting over for ever' {
        InModuleScope CloudDrives {
            $script:TestFailing = @('library', 'drive-a', 'drive-b')
            try { Invoke-CdOAuthRemoteCreate -RemoteName 'cd-od' -RcloneType 'onedrive' -Answers $script:TestAnswers; throw 'expected an error' }
            catch {
                Get-CdErrorCode $_ | Should -Be 'CD-3011'
                (Get-CdErrorInfo $_).Detail | Should -Match 'Failed to query root for drive "library"'
            }
            @($script:TestCalls | Where-Object { $_.State -eq 'driveid_final' } | ForEach-Object { $_.Result }) | Should -Be @('drive-a', 'drive-b', 'library')
            Should -Invoke Remove-CdRemoteIfPresent -Times 1 -Exactly -ParameterFilter { $Name -eq 'cd-od' }
        }
    }

    It 'gives up after a few attempts when rclone fails the same way again and again' {
        InModuleScope CloudDrives {
            # OneDrive Personal sometimes refuses to list drives (https://github.com/rclone/rclone/issues/9794).
            $script:TestStep = {
                param([string]$State, [string]$Result)
                if ($State -in '', 'choose_type') { return (& $script:TestQuestion 'choose_type_done' 'config_type' 'onedrive' @()) }
                & $script:TestError 'choose_type' 'Failed to query available drives: HTTP error 403 (403 Forbidden) returned body: "{\"error\":{\"code\":\"accessDenied\",\"message\":\"Database Is Read Only\"}}"'
            }
            try { Invoke-CdOAuthRemoteCreate -RemoteName 'cd-od' -RcloneType 'onedrive' -Answers $script:TestAnswers; throw 'expected an error' }
            catch {
                Get-CdErrorCode $_ | Should -Be 'CD-3011'
                (Get-CdErrorInfo $_).Detail | Should -Match 'Database Is Read Only'
            }
            $script:TestCalls.Count | Should -BeLessOrEqual 10
            Should -Invoke Remove-CdRemoteIfPresent -Times 1 -Exactly
        }
    }

    It 'classifies the error rclone reports, e.g. an expired sign-in' {
        InModuleScope CloudDrives {
            $script:TestStep = {
                param([string]$State, [string]$Result)
                if ($State -in '', 'choose_type') { return (& $script:TestQuestion 'choose_type_done' 'config_type' 'onedrive' @()) }
                & $script:TestError 'choose_type' 'Failed to query available drives: InvalidAuthenticationToken: Access token has expired'
            }
            try { Invoke-CdOAuthRemoteCreate -RemoteName 'cd-od' -RcloneType 'onedrive' -Answers $script:TestAnswers; throw 'expected an error' }
            catch { Get-CdErrorCode $_ | Should -Be 'CD-3001' }
        }
    }

    It 'stops at a question it cannot answer and removes the half-configured remote' {
        InModuleScope CloudDrives {
            $script:TestStep = { param([string]$State, [string]$Result) & $script:TestQuestion 'driveid_end' 'config_driveid_fixed' $null @() $true }
            try { Invoke-CdOAuthRemoteCreate -RemoteName 'cd-od' -RcloneType 'onedrive' -Answers $script:TestAnswers; throw 'expected an error' }
            catch {
                Get-CdErrorCode $_ | Should -Be 'CD-3011'
                (Get-CdErrorInfo $_).Detail | Should -Match 'config_driveid_fixed'
            }
            $script:TestCalls.Count | Should -Be 1
            Should -Invoke Remove-CdRemoteIfPresent -Times 1 -Exactly -ParameterFilter { $Name -eq 'cd-od' }
        }
    }

    It 'answers other questions with rclone''s default in rclone''s spelling' {
        InModuleScope CloudDrives {
            $script:TestStep = {
                param([string]$State, [string]$Result)
                switch ($State) {
                    '' { return (& $script:TestQuestion 'flag' 'config_flag' $false @()) }
                    'flag' { return (& $script:TestQuestion 'text' 'config_text' 'abc' @()) }
                    'text' { return (& $script:TestQuestion 'optional' 'config_optional' $null @()) }
                    'optional' { return $script:TestDone }
                }
            }
            Invoke-CdOAuthRemoteCreate -RemoteName 'cd-x' -RcloneType 'drive'
            @($script:TestCalls | ForEach-Object { "$($_.State)=$($_.Result)" }) | Should -Be @('=', 'flag=false', 'text=abc', 'optional=')
        }
    }

    It 'shows the sign-in link also when rclone starts the sign-in in a later step (Google, shared client)' {
        InModuleScope CloudDrives {
            $script:TestStep = {
                param([string]$State, [string]$Result)
                switch ($State) {
                    '' { return (& $script:TestQuestion 'client_id_warning' 'config_shared_client_id' $false @()) }
                    'client_id_warning' {
                        # The answer leads to the browser sign-in, then to the question about shared drives.
                        $script:TestPolls = 2
                        $script:TestSigningIn = $true
                        return (& $script:TestQuestion 'teamdrive_ok' 'config_change_team_drive' $false @())
                    }
                    'teamdrive_ok' { return $script:TestDone }
                }
            }
            Invoke-CdOAuthRemoteCreate -RemoteName 'cd-g' -RcloneType 'drive' -Answers (Get-CdProvider -Id 'drive').ConfigAnswers -OnAuthUrl { param([string]$Url) $script:TestUrls.Add($Url) }
            @($script:TestCalls | ForEach-Object { "$($_.State)=$($_.Result)" }) | Should -Be @('=', 'client_id_warning=true', 'teamdrive_ok=false')
            @($script:TestUrls) | Should -Be @('http://127.0.0.1:53682/auth?state=test')
        }
    }

    It 'stops the sign-in and removes the remote when the user cancels' {
        InModuleScope CloudDrives {
            $script:TestPolls = 1000
            $script:TestSigningIn = $true
            try { Invoke-CdOAuthRemoteCreate -RemoteName 'cd-od' -RcloneType 'onedrive' -Answers $script:TestAnswers -ShouldCancel { $true }; throw 'expected an error' }
            catch { Get-CdErrorCode $_ | Should -Be 'CD-3004' }
            Should -Invoke Invoke-CdRc -Times 1 -Exactly -ParameterFilter { $Command -eq 'config/oauthstop' }
            Should -Invoke Invoke-CdRc -Times 1 -Exactly -ParameterFilter { $Command -eq 'job/stop' }
            Should -Invoke Remove-CdRemoteIfPresent -Times 1 -Exactly -ParameterFilter { $Name -eq 'cd-od' }
        }
    }

    It 'reports its progress: the browser, the sign-in received, further attempts, and that it keeps working' {
        InModuleScope CloudDrives {
            # The browser sign-in takes two polls; rclone then goes on while its sign-in web server has stopped.
            $script:TestPolls = 4
            $script:TestSigningIn = $true
            $script:TestSignInPolls = 2
            $script:TestFailing = @('drive-a')
            Invoke-CdOAuthRemoteCreate -RemoteName 'cd-od' -RcloneType 'onedrive' -Answers $script:TestAnswers -OnAuthUrl { } `
                -OnProgress { param([string]$Status) $script:TestProgress.Add($Status) }
            @($script:TestProgress | Where-Object { $_ }) | Should -Be @(
                (Get-CdText 'progress.browser'), (Get-CdText 'progress.setup'), (Get-CdText 'progress.setupRetry' 2))
            @($script:TestProgress | Where-Object { -not $_ }).Count | Should -BeGreaterThan 2
        }
    }

    It 'notices the end of the browser sign-in also when the step ends right after it' {
        InModuleScope CloudDrives {
            $script:TestPolls = 1
            $script:TestSigningIn = $true
            Invoke-CdOAuthRemoteCreate -RemoteName 'cd-od' -RcloneType 'onedrive' -Answers $script:TestAnswers -OnAuthUrl { } `
                -OnProgress { param([string]$Status) $script:TestProgress.Add($Status) }
            @($script:TestProgress | Where-Object { $_ }) | Should -Be @((Get-CdText 'progress.browser'), (Get-CdText 'progress.setup'))
        }
    }

    It 'keeps going when the progress display fails' {
        InModuleScope CloudDrives {
            $script:TestPolls = 2
            $script:TestSigningIn = $true
            Invoke-CdOAuthRemoteCreate -RemoteName 'cd-od' -RcloneType 'onedrive' -Answers $script:TestAnswers -OnProgress { throw 'display broken' }
            $script:TestCalls.Count | Should -Be 4
        }
    }

    It 'reports a failed step with its classified error' {
        InModuleScope CloudDrives {
            $script:TestJobError = 'config failed to refresh token: oauth2: cannot fetch token: 400 Bad Request'
            try { Invoke-CdOAuthRemoteCreate -RemoteName 'cd-od' -RcloneType 'onedrive' -Answers $script:TestAnswers; throw 'expected an error' }
            catch { Get-CdErrorCode $_ | Should -Be 'CD-3008' }
            Should -Invoke Remove-CdRemoteIfPresent -Times 1 -Exactly
        }
    }
}

Describe 'Signing in to OneDrive' {
    BeforeEach {
        InModuleScope CloudDrives {
            $script:TestCalls = New-Object System.Collections.Generic.List[string]
            $script:TestDrives = @(
                [pscustomobject]@{ Value = 'b!stale-1'; Help = 'OneDrive (personal)' }
                [pscustomobject]@{ Value = 'b!stale-2'; Help = 'OneDrive (personal)' }
                [pscustomobject]@{ Value = 'A669B4226F7C'; Help = 'OneDrive (personal)' }
            )
            Mock Invoke-CdRc {
                switch ($Command) {
                    { $_ -in 'config/create', 'config/update' } {
                        $state = [string]$Body.opt.state
                        $script:TestCalls.Add("$state=$([string]$Body.opt.result)")
                        $option = $null
                        $next = ''
                        switch ($state) {
                            '' { $next = 'choose_type_done'; $option = [pscustomobject]@{ Name = 'config_type'; Default = 'onedrive'; DefaultStr = 'onedrive'; Examples = @() } }
                            'choose_type_done' { $next = 'driveid_final'; $option = [pscustomobject]@{ Name = 'config_driveid'; Default = 'b!stale-1'; DefaultStr = 'b!stale-1'; Examples = $script:TestDrives } }
                            'driveid_final' { $next = 'driveid_final_end'; $option = [pscustomobject]@{ Name = 'config_drive_ok'; Default = $true; DefaultStr = 'true'; Examples = @() } }
                        }
                        $script:TestOutput = [pscustomobject]@{ State = $next; Option = $option; Error = ''; Result = '' }
                        return [pscustomobject]@{ jobid = $script:TestCalls.Count }
                    }
                    'job/status' { return [pscustomobject]@{ finished = $true; success = $true; output = $script:TestOutput } }
                    'config/oauthstatus' { return [pscustomobject]@{ status = 'stopped' } }
                    'config/get' { return [pscustomobject]@{ type = 'onedrive'; token = '{"access_token":"tok-1"}' } }
                    default { throw "unexpected RC call $Command" }
                }
            }
            Mock Remove-CdRemoteIfPresent { }
            Mock Start-Sleep { }
        }
    }

    It 'takes the user''s own drive (Graph /me/drive) first instead of stale drives rclone also offers' {
        InModuleScope CloudDrives {
            Mock Invoke-CdApiGet { [pscustomobject]@{ id = 'a669b4226f7c' } }
            Invoke-CdOAuthRemoteCreate -RemoteName 'cd-od' -RcloneType 'onedrive' -Answers (Get-CdProvider -Id 'onedrive').ConfigAnswers
            $script:TestCalls.ToArray() | Should -Be @('=', 'choose_type_done=onedrive', 'driveid_final=A669B4226F7C', 'driveid_final_end=true')
            Should -Invoke Invoke-CdApiGet -Times 1 -Exactly -ParameterFilter { $Uri -like 'https://graph.microsoft.com/v1.0/me/drive*' -and $AccessToken -eq 'tok-1' }
        }
    }

    It 'falls back to the order rclone offers when Graph cannot name the own drive' {
        InModuleScope CloudDrives {
            Mock Invoke-CdApiGet { throw (New-CdException -Code 'CD-5001' -Detail 'GET /me/drive: HTTP 503') }
            Get-CdOneDriveOwnDriveId -RemoteName 'cd-od' | Should -BeNullOrEmpty
            Invoke-CdOAuthRemoteCreate -RemoteName 'cd-od' -RcloneType 'onedrive' -Answers (Get-CdProvider -Id 'onedrive').ConfigAnswers
            $script:TestCalls[2] | Should -Be 'driveid_final=b!stale-1'
        }
    }
}

Describe 'Answers to rclone''s questions' {
    It 'takes the drives offered one after the other, the preferred ones first' {
        InModuleScope CloudDrives {
            $option = [pscustomobject]@{ Name = 'config_driveid'; Examples = @(
                    [pscustomobject]@{ Value = 'library'; Help = 'Documents (documentLibrary)' }
                    [pscustomobject]@{ Value = 'personal'; Help = 'OneDrive (personal)' }
                ) }
            $context = @{}
            Get-CdUntriedChoice -Option $option -Context $context -Prefer '\((personal|business)\)$' | Should -Be 'personal'
            Get-CdUntriedChoice -Option $option -Context $context -Prefer '\((personal|business)\)$' | Should -Be 'library'
            Get-CdUntriedChoice -Option $option -Context $context -Prefer '\((personal|business)\)$' | Should -BeNullOrEmpty
        }
    }

    It 'takes a given value first, whatever its case, when it is offered' {
        InModuleScope CloudDrives {
            $option = [pscustomobject]@{ Name = 'config_driveid'; Examples = @(
                    [pscustomobject]@{ Value = 'b!stale'; Help = 'OneDrive (personal)' }
                    [pscustomobject]@{ Value = 'A669B4226F7C'; Help = 'OneDrive (personal)' }
                ) }
            Get-CdUntriedChoice -Option $option -Context @{} -First 'a669b4226f7c' -Prefer '\((personal|business)\)$' | Should -Be 'A669B4226F7C'
            Get-CdUntriedChoice -Option $option -Context @{} -First 'not-offered' -Prefer '\((personal|business)\)$' | Should -Be 'b!stale'
        }
    }

    It 'gives every provider an answer for the questions rclone asks it after the sign-in' {
        InModuleScope CloudDrives {
            (Get-CdProvider -Id 'onedrive').ConfigAnswers.config_type | Should -Be 'onedrive'
            (Get-CdProvider -Id 'onedrive').ConfigAnswers.config_drive_ok | Should -Be 'true'
            (Get-CdProvider -Id 'drive').ConfigAnswers.config_shared_client_id | Should -Be 'true'
            (Get-CdProvider -Id 'drive').ConfigAnswers.config_change_team_drive | Should -Be 'false'
        }
    }
}
