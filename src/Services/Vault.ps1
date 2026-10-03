# Encrypted vaults (rclone crypt): a folder in the cloud whose file contents and names are encrypted on this
# PC before upload. Password and salt live only in the encrypted rclone.conf and in the user's recovery kit.
# A small check file (canary) inside the vault detects a wrong password before anything is mounted, so no
# files can ever be written with a wrong key.

$script:CdVaultCanaryName = '.clouddrives-tresor'
$script:CdVaultPreferredLetters = @('V', 'X', 'J', 'I', 'L')

function New-CdVaultPassword {
    # Readable random secret: groups of 4 characters without look-alikes (6 groups = about 140 bits).
    param([int]$Groups = 6)
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $limit = 256 - (256 % $alphabet.Length)
    $chars = New-Object System.Collections.Generic.List[char]
    $buffer = New-Object byte[] 64
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        while ($chars.Count -lt $Groups * 4) {
            $rng.GetBytes($buffer)
            foreach ($byte in $buffer) {
                # Rejection sampling keeps every character equally likely.
                if ($byte -lt $limit -and $chars.Count -lt $Groups * 4) { $chars.Add($alphabet[$byte % $alphabet.Length]) }
            }
        }
    }
    finally { $rng.Dispose() }
    $text = -join $chars
    (0..($Groups - 1) | ForEach-Object { $text.Substring($_ * 4, 4) }) -join '-'
}

function ConvertTo-CdVaultFolder {
    # Normalises a folder path in the cloud: "\Privat\Tresor\" -> "Privat/Tresor".
    param([AllowNull()][AllowEmptyString()][string]$Folder)
    $value = ([string]$Folder).Trim().Replace('\', '/')
    $value = [regex]::Replace($value, '/{2,}', '/').Trim('/')
    if (-not $value) { throw (New-CdException -Code 'CD-6004' -Detail 'empty vault folder') }
    $value
}

function Get-CdVaultEncoding {
    # base32768 keeps encrypted names short enough for OneDrive's 255-character limit.
    param([Parameter(Mandatory)][string]$Provider)
    if ($Provider -eq 'onedrive') { return 'base32768' }
    'base32'
}

function Get-CdVaultFolderState {
    # 'new' when the vault folder is missing or empty, otherwise 'existing'.
    param([Parameter(Mandatory)][string]$AccountId, [Parameter(Mandatory)][string]$Folder)
    try {
        $list = Invoke-CdRc -Command 'operations/list' -Body ([ordered]@{ fs = "$(Get-CdAccountRemoteName -AccountId $AccountId):"; remote = $Folder }) -TimeoutSec 120
        if (@($list.list | Where-Object { $_ }).Count -gt 0) { return 'existing' }
        return 'new'
    }
    catch {
        if ((Get-CdErrorDetail $_) -match '(?i)directory not found|not found') { return 'new' }
        throw
    }
}

function New-CdVaultRemote {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password', Justification = 'rclone needs the plain value once; it is stored only in the encrypted rclone.conf.')]
    param(
        [Parameter(Mandatory)][string]$DriveId,
        [Parameter(Mandatory)][string]$AccountId,
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][string]$Salt,
        [Parameter(Mandatory)][string]$Encoding
    )
    $name = Get-CdVaultRemoteName -DriveId $DriveId
    Remove-CdRemoteIfPresent -Name $name
    Backup-CdRcloneConfig
    $parameters = [ordered]@{
        remote                    = '{0}:{1}' -f (Get-CdAccountRemoteName -AccountId $AccountId), $Folder
        filename_encryption       = 'standard'
        directory_name_encryption = 'true'
        filename_encoding         = $Encoding
        password                  = $Password
        password2                 = $Salt
    }
    # "obscure" tells rclone the passwords are plain text; the whole configuration file stays encrypted.
    [void](Invoke-CdRc -Command 'config/create' -Body ([ordered]@{ name = $name; type = 'crypt'; parameters = $parameters; opt = @{ obscure = $true } }))
    Write-CdLog -Component 'Vault' -Message "Vault remote '$name' created for '${AccountId}:$Folder'."
    $name
}

function Test-CdVaultKey {
    # True when the vault's check file is found with the configured key (a wrong key encrypts the
    # check file's name differently, so it is not found).
    param([Parameter(Mandatory)][string]$DriveId)
    $stat = Invoke-CdRc -Command 'operations/stat' -Body ([ordered]@{ fs = "$(Get-CdVaultRemoteName -DriveId $DriveId):"; remote = $script:CdVaultCanaryName }) -TimeoutSec 60
    [bool]($stat -and $stat.item)
}

function Test-CdVaultReadable {
    # True when at least one entry of the vault decrypts with the configured key.
    param([Parameter(Mandatory)][string]$DriveId)
    $list = Invoke-CdRc -Command 'operations/list' -Body ([ordered]@{ fs = "$(Get-CdVaultRemoteName -DriveId $DriveId):"; remote = '' }) -TimeoutSec 120
    @($list.list | Where-Object { $_ }).Count -gt 0
}

function Write-CdVaultCanary {
    param([Parameter(Mandatory)][string]$DriveId)
    $work = Join-Path (Get-CdContext).StateDir ('canary-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $work -Force)
    try {
        $content = "CloudDrives vault check file - do not delete.`nvault=$DriveId`ncreated=$((Get-Date).ToString('yyyy-MM-dd'))`n"
        [IO.File]::WriteAllText((Join-Path $work $script:CdVaultCanaryName), $content, (New-Object Text.UTF8Encoding($false)))
        $body = [ordered]@{
            srcFs     = $work
            srcRemote = $script:CdVaultCanaryName
            dstFs     = "$(Get-CdVaultRemoteName -DriveId $DriveId):"
            dstRemote = $script:CdVaultCanaryName
        }
        [void](Invoke-CdRc -Command 'operations/copyfile' -Body $body -TimeoutSec 120)
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Add-CdVaultDrive {
    # Creates a new vault - or connects to an existing one - in a folder of an account and adds it as a drive.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password', Justification = 'rclone needs the plain value once; it is stored only in the encrypted rclone.conf.')]
    param(
        [Parameter(Mandatory)][string]$AccountId,
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string]$Letter,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][string]$Salt
    )
    $account = Get-CdAccount -Id $AccountId
    if (-not $account) { throw (New-CdException -Code 'CD-2006' -Detail "unknown account '$AccountId'") }
    $Folder = ConvertTo-CdVaultFolder -Folder $Folder
    $Letter = $Letter.Trim().TrimEnd(':').ToUpperInvariant()
    if ((Get-CdFreeDriveLetters) -notcontains $Letter) { throw (New-CdException -Code 'CD-4001' -Detail "${Letter}: is not available") }

    [void](Start-CdEngine)
    $state = Get-CdVaultFolderState -AccountId $AccountId -Folder $Folder
    $settings = Get-CdSettings
    $driveId = New-CdUniqueId -Text $Label -Existing @($settings.drives | ForEach-Object { $_.id }) -Fallback 'tresor'
    $encoding = Get-CdVaultEncoding -Provider $account.provider

    [void](New-CdVaultRemote -DriveId $driveId -AccountId $AccountId -Folder $Folder -Password $Password -Salt $Salt -Encoding $encoding)
    try {
        if ($state -eq 'new') {
            Write-CdVaultCanary -DriveId $driveId
        }
        elseif (-not (Test-CdVaultKey -DriveId $driveId)) {
            # A vault created with plain rclone has no check file: adopt it when its names decrypt.
            if (Test-CdVaultReadable -DriveId $driveId) { Write-CdVaultCanary -DriveId $driveId }
            else { throw (New-CdException -Code 'CD-6001' -Detail "folder '$Folder' does not decrypt with the given password") }
        }
    }
    catch {
        Remove-CdRemoteIfPresent -Name (Get-CdVaultRemoteName -DriveId $driveId)
        throw
    }

    $vault = [ordered]@{ filenameEncryption = 'standard'; directoryNameEncryption = $true; filenameEncoding = $encoding }
    $drive = New-CdDrive -AccountId $AccountId -Letter $Letter -Label $Label -Path $Folder -Encrypted -Id $driveId -Vault $vault
    Write-CdLog -Component 'Vault' -Message "Vault drive '$driveId' ($state) added for account '$AccountId'."
    New-CdResult -Message (Get-CdText 'vault.created' $Label, "${Letter}:") -Data ([pscustomobject]@{ Drive = $drive; State = $state })
}

function Get-CdRecoveryKitText {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password', Justification = 'The recovery kit is shown to the user on purpose.')]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Drive,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Account,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][string]$Salt
    )
    $provider = Get-CdProvider -Id $Account.provider
    $encoding = 'base32'
    if ($Drive.vault -and $Drive.vault.filenameEncoding) { $encoding = [string]$Drive.vault.filenameEncoding }
    Get-CdText 'vault.kit.text' @(
        $Drive.label, (Get-Date).ToString('yyyy-MM-dd'), $env:COMPUTERNAME, $Account.label,
        (Get-CdText $provider.NameKey), $Drive.path, $Password, $Salt, $encoding
    )
}

function Test-CdPathInCloudFolder {
    # True when a path lies in a folder that is synchronised to a cloud (OneDrive, Google Drive, CloudDrives).
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    foreach ($root in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial)) {
        if ($root -and $full.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $letter = $full.Substring(0, 1).ToUpperInvariant()
    if (@((Get-CdSettings).drives | ForEach-Object { [string]$_.letter }) -contains $letter) { return $true }
    try {
        $info = New-Object IO.DriveInfo($letter)
        if ($info.IsReady -and $info.VolumeLabel -match '(?i)google drive') { return $true }
    }
    catch { Write-CdLog -Level DEBUG -Component 'Vault' -Message "Drive info for ${letter}: $($_.Exception.Message)" }
    $false
}

function Get-CdRecoveryKitDefaultPath {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Drive)
    $fileName = "CloudDrives-Recovery-$($Drive.id).txt"
    foreach ($folder in @([Environment]::GetFolderPath('MyDocuments'), [Environment]::GetFolderPath('Desktop'), $env:USERPROFILE)) {
        if ($folder -and -not (Test-CdPathInCloudFolder -Path (Join-Path $folder $fileName))) { return (Join-Path $folder $fileName) }
    }
    Join-Path $env:USERPROFILE $fileName
}

function Save-CdRecoveryKit {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $directory = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory -Force) }
    # UTF-8 with BOM so that Notepad shows the umlauts correctly.
    [IO.File]::WriteAllText($Path, ($Text -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($true)))
    Write-CdLog -Component 'Vault' -Message 'Recovery kit saved to a user-chosen file.'
    [IO.Path]::GetFullPath($Path)
}
