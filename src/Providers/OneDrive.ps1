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
    # rclone's questions after the sign-in: OneDrive Personal or Business (not SharePoint), the user's own drive -
    # should the drive fail its check, rclone asks again and the next drive offered is tried - and confirm it.
    ConfigAnswers    = @{
        config_type     = 'onedrive'
        config_driveid  = { param([object]$Option, [hashtable]$Context) Get-CdUntriedChoice -Option $Option -Context $Context -Prefer '\((personal|business)\)$' }
        config_drive_ok = 'true'
    }
    # Who is signed in: rclone stores the ID of the user's drive in the configuration, so the account is known
    # even when its sign-in has expired. The owner's name is shown when the sign-in works.
    GetIdentity      = {
        param([object]$SignIn)
        $id = [string]$SignIn.Config.drive_id
        $name = $null
        if ($SignIn.AccessToken) {
            try {
                $drive = Invoke-CdApiGet -Uri 'https://graph.microsoft.com/v1.0/me/drive?$select=id,owner' -AccessToken $SignIn.AccessToken
                if (-not $id) { $id = [string]$drive.id }
                $name = [string]$drive.owner.user.displayName
            }
            catch { Write-CdLog -Level DEBUG -Component 'OneDrive' -Message "Owner lookup failed: $((Get-CdErrorInfo $_).Detail)" }
        }
        if (-not $id) { return $null }
        [pscustomobject]@{ Id = $id.ToLowerInvariant(); Name = $name }
    }
}
