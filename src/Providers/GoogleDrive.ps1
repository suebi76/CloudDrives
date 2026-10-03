# Google Drive - private Google accounts (e.g. Google One / Pro) and Google Workspace accounts.
# Google Docs/Sheets/Slides appear as .url shortcuts that open the document in the browser.

Register-CdProvider @{
    Id               = 'drive'
    RcloneType       = 'drive'
    NameKey          = 'provider.drive.name'
    Kinds            = @('personal', 'workspace')
    PreferredLetters = @('K', 'J', 'L', 'U', 'I')
    RevokeUrl        = 'https://myaccount.google.com/permissions'
    # Drive reports changes (ChangeNotify), so directory listings can be cached longer.
    MountOptions     = @{ dir_cache_time = '1h'; poll_interval = '1m' }
    NewParameters    = {
        param([string]$ClientId, [string]$ClientSecret)
        $parameters = [ordered]@{ scope = 'drive'; export_formats = 'url' }
        if ($ClientId) {
            $parameters.client_id = $ClientId
            $parameters.client_secret = $ClientSecret
        }
        $parameters
    }
}
