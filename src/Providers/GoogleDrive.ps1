# Google Drive - private Google accounts (e.g. Google One / Pro) and Google Workspace accounts.
# Google Docs/Sheets/Slides appear as .url shortcuts that open the document in the browser.
# rclone's shared client ID is being retired during 2026; an own client ID (docs\GOOGLE-OAUTH.md) is required.

function Test-CdGoogleClientId {
    # Plausibility check for OAuth client IDs of the form "<number>-<id>.apps.googleusercontent.com".
    param([AllowNull()][AllowEmptyString()][string]$ClientId)
    ([string]$ClientId).Trim() -match '^\d+-[a-z0-9]+\.apps\.googleusercontent\.com$'
}

function Get-CdDownloadsFolder {
    try {
        $shellFolders = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' -ErrorAction Stop
        $path = $shellFolders.'{374DE290-123F-4565-9164-39C4925E467B}'
        if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    }
    catch { Write-CdLog -Level DEBUG -Component 'Google' -Message "Downloads folder lookup: $($_.Exception.Message)" }
    Join-Path $env:USERPROFILE 'Downloads'
}

function Read-CdGoogleClientFile {
    # Reads client ID and secret from a downloaded "Desktop app" OAuth client file (client_secret_*.json).
    param([Parameter(Mandatory)][string]$Path)
    try {
        $section = ([IO.File]::ReadAllText($Path) | ConvertFrom-Json).installed
        if ($section -and (Test-CdGoogleClientId -ClientId $section.client_id) -and $section.client_secret) {
            return [pscustomobject]@{ Path = $Path; ClientId = ([string]$section.client_id).Trim(); ClientSecret = [string]$section.client_secret }
        }
    }
    catch { Write-CdLog -Level DEBUG -Component 'Google' -Message "Not a client file: $Path" }
    $null
}

function Find-CdGoogleClientFile {
    # The newest valid client file in the Downloads folder (or the program folder, where some embedded
    # browsers save downloads), or $null.
    param([string]$Folder)
    $folders = @($Folder)
    if (-not $Folder) { $folders = @((Get-CdDownloadsFolder), (Get-CdContext).AppRoot) }
    $files = foreach ($candidate in $folders) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { Get-ChildItem -LiteralPath $candidate -Filter 'client_secret_*.json' -File -ErrorAction SilentlyContinue }
    }
    foreach ($file in (@($files) | Where-Object { $_ } | Sort-Object -Property LastWriteTime -Descending)) {
        $client = Read-CdGoogleClientFile -Path $file.FullName
        if ($client) { return $client }
    }
    $null
}

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
    # Who is signed in: Drive's "about" names the user. The permission ID is stable, the address is shown.
    GetIdentity      = {
        param([object]$SignIn)
        if (-not $SignIn.AccessToken) { return $null }
        $about = Invoke-CdApiGet -Uri 'https://www.googleapis.com/drive/v3/about?fields=user(displayName,emailAddress,permissionId)' -AccessToken $SignIn.AccessToken
        if (-not $about.user.permissionId) { return $null }
        $name = [string]$about.user.emailAddress
        if (-not $name) { $name = [string]$about.user.displayName }
        [pscustomobject]@{ Id = [string]$about.user.permissionId; Name = $name }
    }
}
