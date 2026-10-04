# WebDAV servers: Nextcloud, IServ (school server) and any other WebDAV server. Nextcloud signs in in the browser and
# hands CloudDrives an app password of its own (Login Flow v2); IServ and other servers take the user name and the
# password, entered in CloudDrives. Either way the password is kept only in the encrypted rclone configuration.

Register-CdProvider @{
    Id               = 'webdav'
    RcloneType       = 'webdav'
    NameKey          = 'provider.webdav.name'
    Kinds            = @('nextcloud', 'iserv', 'other')
    # Signs in with a user name and a password (or an app password) instead of OAuth.
    SignIn           = 'password'
    PreferredLetters = @('X', 'V', 'U', 'L', 'W')
    RevokeUrl        = ''
    # WebDAV reports no changes, so directory listings are read again after two minutes.
    MountOptions     = @{ dir_cache_time = '2m' }
    # Not used: WebDAV accounts bring their parameters with the sign-in (New-CdWebDavCredential).
    NewParameters    = { [ordered]@{} }
    # The cloud account is the user at this WebDAV address.
    GetIdentity      = {
        param([object]$SignIn)
        $url = [string]$SignIn.Config.url
        $user = [string]$SignIn.Config.user
        $uri = $null
        if (-not $user -or -not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)) { return $null }
        [pscustomobject]@{
            Id   = ('{0}@{1}{2}' -f $user, $uri.Authority, $uri.AbsolutePath.TrimEnd('/')).ToLowerInvariant()
            Name = ('{0} @ {1}' -f $user, $uri.Host)
        }
    }
    # Nextcloud lists the app password of CloudDrives under Settings > Security, where it can be revoked.
    GetRevokeUrl     = {
        param([object]$Account, [object]$Config)
        if ($Account.kind -ne 'nextcloud') { return '' }
        $server = Get-CdNextcloudServer -Url ([string]$Config.url)
        if (-not $server) { return '' }
        $server + '/settings/user/security'
    }
}
