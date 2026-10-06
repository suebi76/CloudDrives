# Signing an account in through rclone's configuration dialogue (config/create over the RC API, one question after
# the other): OAuth in the browser for Google and OneDrive, address, user name and password for WebDAV. The provider
# definitions answer rclone's questions; CloudDrives never sees a password of an OAuth sign-in.

function Invoke-CdOAuthRemoteCreate {
    # Creates an OAuth remote through the engine. The browser opens via $OnAuthUrl; $ShouldCancel is polled.
    # rclone's configuration runs step by step: each question rclone asks - OneDrive, for example, asks after the
    # sign-in which drive to use - comes back here and is answered from $Answers (the provider's answers) or with
    # rclone's default, and an error rclone reports ends the configuration with that error. (Run in one go, rclone
    # answered every question with its default itself and started over after an error, for ever.)
    param(
        [Parameter(Mandatory)][string]$RemoteName,
        [Parameter(Mandatory)][string]$RcloneType,
        [System.Collections.IDictionary]$Parameters = @{},
        [System.Collections.IDictionary]$Answers = @{},
        [scriptblock]$OnAuthUrl,
        [scriptblock]$ShouldCancel,
        # Gets a status text when a step begins (waiting for the browser, setting up the account) and is called
        # without text about twice a second while CloudDrives waits, so the display can show it is still working.
        [scriptblock]$OnProgress,
        [int]$TimeoutSec = 600,
        [int]$MaxSteps = 30
    )
    # Not stored in the configuration: sign in through the local web server, and no browser from rclone - we open
    # it ourselves so the link can also be shown in the console.
    $signIn = [ordered]@{ config_is_local = 'true'; config_auth_no_browser = 'true' }
    $allParameters = [ordered]@{}
    foreach ($key in $Parameters.Keys) { $allParameters[$key] = $Parameters[$key] }
    foreach ($key in $signIn.Keys) { $allParameters[$key] = $signIn[$key] }

    $job = @{
        RemoteName = $RemoteName; Deadline = (Get-Date).AddSeconds($TimeoutSec); Progress = @{ UrlDelivered = $false; SignedIn = $false }
        OnAuthUrl = $OnAuthUrl; ShouldCancel = $ShouldCancel; OnProgress = $OnProgress
    }
    # Shared with the providers' answers: the remote being configured, the values tried, rclone's last error.
    $context = @{ RemoteName = $RemoteName; Tried = @{}; LastError = $null; Errors = 0 }
    $asked = @{}
    Write-CdLog -Component 'Accounts' -Message "OAuth configuration of '$RemoteName' started."
    try {
        $body = [ordered]@{ name = $RemoteName; type = $RcloneType; parameters = $allParameters; opt = @{ nonInteractive = $true; obscure = $true }; _async = $true }
        $out = Invoke-CdConfigJob @job -Command 'config/create' -Body $body
        for ($step = 1; $out -and $out.State; $step++) {
            $result = [string]$out.Result
            if ($out.Error) {
                $context.LastError = [string]$out.Error
                $context.Errors++
                Write-CdLog -Level WARN -Component 'Accounts' -Message "Configuring '$RemoteName', rclone reports: $($context.LastError)"
                Send-CdProgress -OnProgress $OnProgress -Text (Get-CdText 'progress.setupRetry' ($context.Errors + 1))
            }
            if ($out.Option) {
                # The same question again means the previous answer failed: a few attempts, then the last error.
                $name = [string]$out.Option.Name
                $asked[$name] = 1 + [int]$asked[$name]
                $result = $null
                if ($asked[$name] -le 4) { $result = Get-CdConfigAnswer -Option $out.Option -Answers $Answers -Context $context }
                if ($null -eq $result) { throw (New-CdConfigException -Question $name -LastError $context.LastError) }
                Write-CdLog -Level DEBUG -Component 'Accounts' -Message "Configuring '$RemoteName': question '$name' answered."
            }
            if ($step -gt $MaxSteps) { throw (New-CdConfigException -Question ([string]$out.State) -LastError $context.LastError) }
            $body = [ordered]@{ name = $RemoteName; parameters = $signIn; opt = @{ nonInteractive = $true; continue = $true; state = [string]$out.State; result = $result }; _async = $true }
            $out = Invoke-CdConfigJob @job -Command 'config/update' -Body $body
        }
    }
    catch {
        Remove-CdRemoteIfPresent -Name $RemoteName
        throw
    }
    if ($out -and $out.Error) { Write-CdLog -Level WARN -Component 'Accounts' -Message "Configuring '$RemoteName' ended with: $($out.Error)" }
    Write-CdLog -Component 'Accounts' -Message "OAuth configuration of '$RemoteName' completed."
}

function Invoke-CdConfigJob {
    # Runs one step of rclone's configuration as an asynchronous job and returns its output: the next question,
    # an error rclone reports, or an empty state when the configuration is complete. A browser sign-in the step
    # starts goes to $OnAuthUrl, its progress to $OnProgress; $ShouldCancel and the deadline stop the step.
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Body,
        [Parameter(Mandatory)][string]$RemoteName,
        [Parameter(Mandatory)][datetime]$Deadline,
        [Parameter(Mandatory)][hashtable]$Progress,
        [scriptblock]$OnAuthUrl,
        [scriptblock]$ShouldCancel,
        [scriptblock]$OnProgress
    )
    $jobId = [int](Invoke-CdRc -Command $Command -Body $Body).jobid
    Write-CdLog -Level DEBUG -Component 'Accounts' -Message "Configuring '$RemoteName': $Command runs as job $jobId."
    while ($true) {
        $status = Invoke-CdRc -Command 'job/status' -Body @{ jobid = $jobId }
        if ($status.finished) { break }
        if (-not $Progress.SignedIn) {
            $oauth = $null
            try { $oauth = Invoke-CdRc -Command 'config/oauthstatus' } catch { Write-CdLog -Level DEBUG -Component 'Accounts' -Message "oauthstatus: $($_.Exception.Message)" }
            if (-not $Progress.UrlDelivered -and $oauth -and $oauth.status -eq 'running' -and $oauth.authUrl) {
                $Progress.UrlDelivered = $true
                if ($OnAuthUrl) { & $OnAuthUrl ([string]$oauth.authUrl) }
                Send-CdProgress -OnProgress $OnProgress -Text (Get-CdText 'progress.browser')
            }
            # rclone's sign-in web server stops once the browser has delivered the sign-in.
            elseif ($Progress.UrlDelivered -and $oauth -and $oauth.status -ne 'running') { Set-CdSignedIn -Progress $Progress -OnProgress $OnProgress }
        }
        $cancelled = $false
        if ($ShouldCancel) { $cancelled = [bool](& $ShouldCancel) }
        if ($cancelled -or (Get-Date) -gt $Deadline) {
            Stop-CdConfigJob -JobId $jobId
            if ($cancelled) { throw (New-CdException -Code 'CD-3004') }
            throw (New-CdException -Code 'CD-3005')
        }
        Send-CdProgress -OnProgress $OnProgress
        Start-Sleep -Milliseconds 500
    }
    if ($Progress.UrlDelivered -and -not $Progress.SignedIn -and $status.success) { Set-CdSignedIn -Progress $Progress -OnProgress $OnProgress }
    if (-not $status.success) {
        $text = [string]$status.error
        $code = Resolve-CdErrorCode -Text $text
        if ($code -eq 'CD-9000') { $code = 'CD-3008' }
        throw (New-CdException -Code $code -Detail $text)
    }
    $status.output
}

function Set-CdSignedIn {
    # Notes that the browser sign-in is done: rclone now fetches the token and sets up the remote.
    param([Parameter(Mandatory)][hashtable]$Progress, [scriptblock]$OnProgress)
    $Progress.SignedIn = $true
    Write-CdLog -Component 'Accounts' -Message 'Browser sign-in received.'
    Send-CdProgress -OnProgress $OnProgress -Text (Get-CdText 'progress.setup')
}

function Stop-CdConfigJob {
    # Stops a configuration step: ends a running browser sign-in, stops the job and waits briefly until it has
    # ended, so it cannot write into the configuration after the half-configured remote is removed.
    param([Parameter(Mandatory)][int]$JobId)
    try {
        if ((Invoke-CdRc -Command 'config/oauthstatus').status -eq 'running') { [void](Invoke-CdRc -Command 'config/oauthstop') }
    }
    catch { Write-CdLog -Level DEBUG -Component 'Accounts' -Message "oauthstop: $($_.Exception.Message)" }
    try { [void](Invoke-CdRc -Command 'job/stop' -Body @{ jobid = $JobId }) } catch { Write-CdLog -Level DEBUG -Component 'Accounts' -Message "job/stop: $($_.Exception.Message)" }
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline) {
        $finished = $true
        try { $finished = [bool](Invoke-CdRc -Command 'job/status' -Body @{ jobid = $JobId }).finished } catch { $finished = $true }
        if ($finished) { return }
        Start-Sleep -Milliseconds 200
    }
    Write-CdLog -Level WARN -Component 'Accounts' -Message "Configuration job $JobId did not end after being stopped."
}

function Get-CdConfigAnswer {
    # Answer to a question of rclone's configuration: the provider's answer (text, or a script block that gets the
    # question and the configuration context), otherwise rclone's default. $null when there is no answer.
    param(
        [Parameter(Mandatory)][object]$Option,
        [System.Collections.IDictionary]$Answers = @{},
        [hashtable]$Context = @{}
    )
    $name = [string]$Option.Name
    if ($Answers -and $Answers.Contains($name)) {
        $answer = $Answers[$name]
        if ($answer -is [scriptblock]) { $answer = & $answer $Option $Context }
        if ($null -eq $answer) { return $null }
        return [string]$answer
    }
    # DefaultStr is rclone's text form of the default ("false" rather than PowerShell's "False").
    if ($null -ne $Option.Default -and [string]$Option.DefaultStr -ne '') { return [string]$Option.DefaultStr }
    if ($Option.Required) { return $null }
    ''
}

function Get-CdUntriedChoice {
    # Answers a choice of rclone's configuration with an offered value not tried in this configuration yet: $First
    # (when offered), then values whose description matches $Prefer, then the others. rclone asks again when a
    # value fails, so every attempt takes the next value; $null once all were tried.
    param(
        [Parameter(Mandatory)][object]$Option,
        [Parameter(Mandatory)][hashtable]$Context,
        [AllowNull()][AllowEmptyString()][string]$First,
        [string]$Prefer
    )
    if (-not $Context.ContainsKey('Tried')) { $Context.Tried = @{} }
    $name = [string]$Option.Name
    if (-not $Context.Tried.ContainsKey($name)) { $Context.Tried[$name] = New-Object System.Collections.Generic.List[string] }
    $tried = $Context.Tried[$name]
    $firstValues = New-Object System.Collections.Generic.List[string]
    $preferred = New-Object System.Collections.Generic.List[string]
    $others = New-Object System.Collections.Generic.List[string]
    foreach ($example in @($Option.Examples)) {
        $value = [string]$example.Value
        if (-not $value -or $tried.Contains($value)) { continue }
        if ($First -and [string]::Equals($value, $First, [StringComparison]::OrdinalIgnoreCase)) { $firstValues.Add($value) }
        elseif ($Prefer -and [string]$example.Help -match $Prefer) { $preferred.Add($value) }
        else { $others.Add($value) }
    }
    $candidates = @($firstValues) + @($preferred) + @($others)
    if ($candidates.Count -eq 0) { return $null }
    $tried.Add($candidates[0])
    $candidates[0]
}

function Test-CdPasswordSignIn {
    # True for providers that sign in with a user name and a password (WebDAV) instead of OAuth in the browser.
    param([Parameter(Mandatory)][hashtable]$Definition)
    $Definition.ContainsKey('SignIn') -and $Definition.SignIn -eq 'password'
}

function Get-CdConfigAnswers {
    # The provider's answers to rclone's configuration questions (empty when it has none).
    param([Parameter(Mandatory)][hashtable]$Definition)
    if ($Definition.ContainsKey('ConfigAnswers') -and $Definition.ConfigAnswers) { return $Definition.ConfigAnswers }
    @{}
}

function New-CdConfigException {
    # The error that ends a configuration rclone cannot complete: the error rclone reported last, classified,
    # otherwise CD-3011 naming the question that could not be answered.
    param([Parameter(Mandatory)][string]$Question, [AllowNull()][AllowEmptyString()][string]$LastError)
    if ($LastError) {
        $code = Resolve-CdErrorCode -Text $LastError
        if ($code -eq 'CD-9000') { $code = 'CD-3011' }
        return (New-CdException -Code $code -Detail $LastError)
    }
    New-CdException -Code 'CD-3011' -Detail "rclone asked '$Question', which CloudDrives cannot answer"
}
