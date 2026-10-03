# Microsoft OneDrive - personal Microsoft accounts (including Microsoft 365 Family members).

Register-CdProvider @{
    Id               = 'onedrive'
    RcloneType       = 'onedrive'
    NameKey          = 'provider.onedrive.name'
    Kinds            = @('personal')
    PreferredLetters = @('M', 'O', 'N', 'L')
    RevokeUrl        = 'https://account.live.com/consent/Manage'
    # OneDrive reports changes (ChangeNotify), so directory listings can be cached longer.
    MountOptions     = @{ dir_cache_time = '1h'; poll_interval = '1m' }
    NewParameters    = {
        param([string]$ClientId, [string]$ClientSecret)
        $parameters = [ordered]@{}
        if ($ClientId) {
            $parameters.client_id = $ClientId
            $parameters.client_secret = $ClientSecret
        }
        $parameters
    }
}
