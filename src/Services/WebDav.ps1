# WebDAV accounts (Nextcloud, IServ, other servers): the WebDAV address for what the user types, the browser sign-in
# of Nextcloud (Login Flow v2) and the remote with user name and password. A password stays a SecureString until it
# goes to rclone, which stores it obscured in the encrypted configuration. It is never logged or shown.

function ConvertTo-CdSecureString {
    # SecureString from text (for a password that arrives as text, e.g. the app password Nextcloud hands over).
    param([AllowEmptyString()][string]$Text)
    $secure = New-Object System.Security.SecureString
    foreach ($character in $Text.ToCharArray()) { $secure.AppendChar($character) }
    $secure.MakeReadOnly()
    $secure
}

function Get-CdNextcloudServer {
    # The server address of a Nextcloud WebDAV address (https://host[/folder]/remote.php/dav/files/user).
    param([AllowEmptyString()][string]$Url)
    if ($Url -match '^(?<server>https?://[^/]+(/.*?)?)/(remote|index)\.php(/|$)') { return $Matches['server'] }
    $uri = $null
    if ([Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $uri.GetLeftPart([UriPartial]::Authority) }
    ''
}

function ConvertTo-CdWebDavAddress {
    # What the user typed turned into addresses: for Nextcloud the server (also from its WebDAV or browser address),
    # for IServ the WebDAV address of the school server (webdav.<school address>), otherwise the WebDAV address as
    # typed. Only https is accepted (http only on this computer). Returns @{ Url; Server; HostName }; the WebDAV
    # address of Nextcloud is known only after the sign-in (it contains the user ID).
    param(
        [Parameter(Mandatory)][ValidateSet('nextcloud', 'iserv', 'other')][string]$Kind,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Address
    )
    $text = $Address.Trim()
    if ($text -and $text -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $text = 'https://' + $text }
    $uri = $null
    if (-not $text -or -not [Uri]::TryCreate($text, [UriKind]::Absolute, [ref]$uri) -or -not $uri.Host) {
        throw (New-CdException -Code 'CD-3013' -Detail "not an address: '$Address'")
    }
    if ($uri.Scheme -ne 'https' -and -not ($uri.Scheme -eq 'http' -and $uri.IsLoopback)) {
        throw (New-CdException -Code 'CD-3013' -Detail "only https addresses are accepted: '$Address'")
    }
    $origin = $uri.GetLeftPart([UriPartial]::Authority)
    $path = $uri.AbsolutePath
    switch ($Kind) {
        'nextcloud' {
            # Nextcloud may live in a folder; its pages and WebDAV addresses start below that folder. A WebDAV address
            # with the user ID (from the Nextcloud file settings) is taken over as it is.
            $url = ''
            if ($path -match '^(?<folder>.*?)/remote\.php/dav/files/(?<user>[^/]+)') { $url = '{0}{1}/remote.php/dav/files/{2}' -f $origin, $Matches['folder'], $Matches['user'] }
            $folder = ([regex]::Replace($path, '/(remote\.php|index\.php|apps|login|settings|s)(/.*)?$', '')).TrimEnd('/')
            return [pscustomobject]@{ Url = $url; Server = $origin + $folder; HostName = $uri.Host }
        }
        'iserv' {
            # IServ serves WebDAV on its own sub domain; https://<school>/webdav is the documented alternative.
            if ($path -match '^/webdav(/|$)') { $url = $origin + '/webdav/' }
            elseif ($uri.Host -like 'webdav.*') { $url = $origin + '/' }
            else {
                $port = ''
                if (-not $uri.IsDefaultPort) { $port = ':' + $uri.Port }
                $url = '{0}://webdav.{1}{2}/' -f $uri.Scheme, $uri.Host, $port
            }
            $webdav = [Uri]$url
            return [pscustomobject]@{ Url = $url; Server = $webdav.GetLeftPart([UriPartial]::Authority); HostName = $webdav.Host }
        }
        default {
            return [pscustomobject]@{ Url = $uri.GetLeftPart([UriPartial]::Path); Server = $origin; HostName = $uri.Host }
        }
    }
}

function New-CdWebDavCredential {
    # Everything a WebDAV remote needs; the password as SecureString.
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][ValidateSet('nextcloud', 'iserv', 'other')][string]$Kind,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][System.Security.SecureString]$Password
    )
    # rclone knows Nextcloud's extensions (modification times, checksums, uploads in parts); IServ is plain WebDAV.
    $vendor = 'other'
    if ($Kind -eq 'nextcloud') { $vendor = 'nextcloud' }
    [pscustomobject]@{
        PSTypeName = 'CloudDrives.WebDavCredential'
        Url        = $Url
        Kind       = $Kind
        Vendor     = $vendor
        User       = $User
        Password   = $Password
    }
}

function Invoke-CdNextcloudLogin {
    # Browser sign-in to a Nextcloud (Login Flow v2). Nextcloud shows its own sign-in page - with two-factor
    # authentication when the user has it - and hands CloudDrives an app password of its own, which the user can
    # revoke under Settings > Security. Returns a WebDAV credential with the address that contains the user ID.
    param(
        [Parameter(Mandatory)][string]$Server,
        [scriptblock]$OnAuthUrl,
        [scriptblock]$ShouldCancel,
        [scriptblock]$OnProgress,
        [int]$TimeoutSec = 600,
        [int]$PollMilliseconds = 1000
    )
    $Server = $Server.TrimEnd('/')
    $serverUri = [Uri]$Server
    # Nextcloud names the app password after the client, so the user recognises it: "CloudDrives (<computer>)".
    $headers = @{ 'User-Agent' = ('CloudDrives ({0})' -f $env:COMPUTERNAME); 'Accept-Language' = (Get-CdLanguage) }
    $start = Invoke-CdHttpRequest -Method POST -Uri ($Server + '/index.php/login/v2') -Headers $headers
    $flow = $null
    if ($start.Status -eq 200) { try { $flow = $start.Text | ConvertFrom-Json } catch { $flow = $null } }
    if (-not $flow -or -not $flow.poll.token -or -not $flow.poll.endpoint -or -not $flow.login) {
        throw (New-CdException -Code 'CD-3014' -Detail "no Nextcloud sign-in at $Server (HTTP $($start.Status))")
    }
    # The sign-in page and the poll token belong to this server only.
    foreach ($address in @([string]$flow.login, [string]$flow.poll.endpoint)) {
        $uri = $null
        if (-not [Uri]::TryCreate($address, [UriKind]::Absolute, [ref]$uri) -or $uri.Host -ne $serverUri.Host -or
            ($uri.Scheme -ne 'https' -and -not $uri.IsLoopback)) {
            throw (New-CdException -Code 'CD-3014' -Detail "the server answered with a foreign address ($($uri.Host))")
        }
    }
    Write-CdLog -Component 'WebDav' -Message "Nextcloud sign-in started at $($serverUri.Host)."
    if ($OnAuthUrl) { & $OnAuthUrl ([string]$flow.login) }
    Send-CdProgress -OnProgress $OnProgress -Text (Get-CdText 'progress.browser')

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $granted = $null
    $failures = 0
    while (-not $granted) {
        if ($ShouldCancel -and [bool](& $ShouldCancel)) { throw (New-CdException -Code 'CD-3004') }
        if ((Get-Date) -gt $deadline) { throw (New-CdException -Code 'CD-3005') }
        $answer = $null
        try { $answer = Invoke-CdHttpRequest -Method POST -Uri ([string]$flow.poll.endpoint) -Form @{ token = [string]$flow.poll.token } -TimeoutSec 15 }
        catch {
            # A short network hiccup while the user signs in: keep asking for a while.
            $failures++
            if ($failures -ge 10) { throw }
            Write-CdLog -Level DEBUG -Component 'WebDav' -Message "Nextcloud poll failed: $((Get-CdErrorInfo $_).Detail)"
        }
        if ($answer -and $answer.Status -eq 200) {
            try { $granted = $answer.Text | ConvertFrom-Json } catch { $granted = $null }
            if (-not $granted -or -not $granted.loginName -or -not $granted.appPassword) {
                throw (New-CdException -Code 'CD-3014' -Detail 'the sign-in answer of Nextcloud is incomplete')
            }
            break
        }
        # 404 means: not signed in yet.
        if ($answer -and $answer.Status -ne 404) { throw (New-CdException -Code 'CD-3014' -Detail "sign-in answer HTTP $($answer.Status)") }
        Send-CdProgress -OnProgress $OnProgress
        Start-Sleep -Milliseconds $PollMilliseconds
    }
    Send-CdProgress -OnProgress $OnProgress -Text (Get-CdText 'progress.setup')
    $loginName = [string]$granted.loginName
    $password = ConvertTo-CdSecureString -Text ([string]$granted.appPassword)
    $granted = $null
    Write-CdLog -Component 'WebDav' -Message 'Nextcloud sign-in received (app password created).'

    $credential = New-Object System.Management.Automation.PSCredential($loginName, $password)
    New-CdWebDavCredential -Url (Get-CdNextcloudDavUrl -Server $Server -Credential $credential) -Kind 'nextcloud' -User $loginName -Password $password
}

function Get-CdNextcloudDavUrl {
    # The WebDAV address of the account: it contains the user ID, which may differ from the login name (e.g. an
    # e-mail address). Nextcloud tells the user ID; otherwise the login name is used.
    param([Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential)
    $userId = $Credential.UserName
    try {
        $me = Invoke-CdHttpRequest -Uri ($Server.TrimEnd('/') + '/ocs/v1.php/cloud/user?format=json') -Headers @{ 'OCS-APIRequest' = 'true' } -Credential $Credential
        if ($me.Status -eq 200) {
            $id = [string](($me.Text | ConvertFrom-Json).ocs.data.id)
            if ($id) { $userId = $id }
        }
    }
    catch { Write-CdLog -Level DEBUG -Component 'WebDav' -Message "Nextcloud user ID unavailable, using the login name: $((Get-CdErrorInfo $_).Detail)" }
    '{0}/remote.php/dav/files/{1}' -f $Server.TrimEnd('/'), [Uri]::EscapeDataString($userId)
}

function New-CdNextcloudCredential {
    # Sign-in with user name and app password, for a Nextcloud that does not allow the browser sign-in for programs.
    # A normal password is exchanged for an app password of CloudDrives where Nextcloud allows it, so only a
    # revocable app password is stored. The WebDAV address is the given one or is built from the user ID.
    param(
        [Parameter(Mandatory)][string]$Server,
        [AllowEmptyString()][string]$Url,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][System.Security.SecureString]$Password
    )
    $Server = $Server.TrimEnd('/')
    $credential = New-Object System.Management.Automation.PSCredential($User, $Password)
    $headers = @{ 'OCS-APIRequest' = 'true'; 'User-Agent' = ('CloudDrives ({0})' -f $env:COMPUTERNAME) }
    $exchange = $null
    try { $exchange = Invoke-CdHttpRequest -Uri ($Server + '/ocs/v2.php/core/getapppassword?format=json') -Headers $headers -Credential $credential }
    catch { Write-CdLog -Level DEBUG -Component 'WebDav' -Message "App password exchange unavailable: $((Get-CdErrorInfo $_).Detail)" }
    # A wrong user name or password ends here, before further attempts count against the account.
    if ($exchange -and $exchange.Status -eq 401) { throw (New-CdException -Code 'CD-3012' -Detail 'Nextcloud refused the user name or the password (401)') }
    if ($exchange -and $exchange.Status -eq 200) {
        $appPassword = ''
        try { $appPassword = [string](($exchange.Text | ConvertFrom-Json).ocs.data.apppassword) } catch { $appPassword = '' }
        if ($appPassword) {
            $Password = ConvertTo-CdSecureString -Text $appPassword
            $appPassword = $null
            $credential = New-Object System.Management.Automation.PSCredential($User, $Password)
            Write-CdLog -Component 'WebDav' -Message 'Nextcloud password exchanged for an app password of CloudDrives.'
        }
    }
    # Any other answer (403: it already is an app password) keeps the password as entered.
    if (-not $Url) { $Url = Get-CdNextcloudDavUrl -Server $Server -Credential $credential }
    New-CdWebDavCredential -Url $Url -Kind 'nextcloud' -User $User -Password $Password
}

function New-CdWebDavRemote {
    # Creates (or replaces) the remote of a WebDAV account and checks that the server accepts the sign-in. Only here
    # does the password go to rclone, which obscures it and stores it in the encrypted configuration.
    param([Parameter(Mandatory)][string]$RemoteName, [Parameter(Mandatory)][object]$Login, [scriptblock]$OnProgress)
    $serverName = ([Uri]$Login.Url).Host
    Send-CdProgress -OnProgress $OnProgress -Text (Get-CdText 'progress.webdavCheck' $serverName)
    $parameters = [ordered]@{
        url    = [string]$Login.Url
        vendor = [string]$Login.Vendor
        user   = [string]$Login.User
        pass   = (New-Object System.Net.NetworkCredential('', $Login.Password)).Password
    }
    try {
        [void](Invoke-CdRc -Command 'config/create' -Body @{ name = $RemoteName; type = 'webdav'; parameters = $parameters; opt = @{ nonInteractive = $true; obscure = $true } })
    }
    finally { $parameters.pass = $null }
    try { [void](Get-CdRemoteAbout -RemoteName $RemoteName -CacheSec 0 -TimeoutSec 30) }
    catch {
        $info = Get-CdErrorInfo $_
        Remove-CdRemoteIfPresent -Name $RemoteName
        $detail = [string]$info.Detail
        Write-CdLog -Level WARN -Component 'WebDav' -Message "Sign-in at $serverName refused: $($info.Code) $detail"
        if ($detail -match '401 Unauthorized|NotAuthenticated') { throw (New-CdException -Code 'CD-3012' -Detail $detail) }
        if ($detail -match '404 Not Found|405 Method Not Allowed|\b30[1278]\b') { throw (New-CdException -Code 'CD-3013' -Detail $detail) }
        throw
    }
    Write-CdLog -Component 'WebDav' -Message "Signed in at $serverName."
}

function Get-CdWebDavAccountInfo {
    # Address and user of a WebDAV account (no password), e.g. to sign it in again.
    param([Parameter(Mandatory)][string]$AccountId)
    $config = Invoke-CdRc -Command 'config/get' -Body @{ name = (Get-CdAccountRemoteName -AccountId $AccountId) }
    $url = [string]$config.url
    $uri = $null
    $hostName = ''
    if ([Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)) { $hostName = $uri.Host }
    [pscustomobject]@{ Url = $url; User = [string]$config.user; Server = (Get-CdNextcloudServer -Url $url); HostName = $hostName }
}
