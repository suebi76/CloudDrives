# The rclone configuration (<home>\rclone.conf) holds OAuth tokens and vault keys and is ALWAYS encrypted.
# Its key is a random 256-bit secret in the secret store (mode "dpapi") or derived from a master
# password with PBKDF2 (mode "masterPassword"). Either way the key is base64url, i.e. command-line safe.

$script:CdConfigPassword = $null
$script:CdPasswordPrompt = $null

function Set-CdPasswordPrompt {
    # The UI registers a script block that asks for the master password (never called in silent mode).
    param([scriptblock]$Prompt)
    $script:CdPasswordPrompt = $Prompt
}

function ConvertTo-CdConfigKey {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'MasterPassword', Justification = 'PBKDF2 needs the plain value; it is never stored.')]
    param([Parameter(Mandatory)][string]$MasterPassword, [Parameter(Mandatory)][string]$Salt)
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($MasterPassword, [Convert]::FromBase64String($Salt), 600000, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try { ConvertTo-CdBase64Url -Bytes $kdf.GetBytes(32) } finally { $kdf.Dispose() }
}

function Test-CdRcloneConfigExists {
    $file = (Get-CdContext).RcloneConfig
    (Test-Path -LiteralPath $file) -and ((Get-Item -LiteralPath $file).Length -gt 0)
}

function Test-CdRcloneConfigEncrypted {
    $file = (Get-CdContext).RcloneConfig
    if (-not (Test-Path -LiteralPath $file)) { return $false }
    [bool](Select-String -LiteralPath $file -Pattern '^RCLONE_ENCRYPT_V0:' -Quiet)
}

function Get-CdConfigPassword {
    if ($script:CdConfigPassword) { return $script:CdConfigPassword }
    $settings = Get-CdSettings
    if ($settings.securityMode -eq 'masterPassword') {
        if (-not $script:CdPasswordPrompt -or (Get-CdContext).Silent) { throw (New-CdException -Code 'CD-2004') }
        $master = & $script:CdPasswordPrompt
        if (-not $master) { throw (New-CdException -Code 'CD-2004') }
        $password = ConvertTo-CdConfigKey -MasterPassword $master -Salt ([string]$settings.masterPasswordSalt)
    }
    else {
        $password = Get-CdSecret -Name 'config'
        if (-not $password) {
            if (Test-CdRcloneConfigExists) { throw (New-CdException -Code 'CD-2003') }
            $password = New-CdRandomSecret -Bytes 32
            Set-CdSecret -Name 'config' -Value $password
            Write-CdLog -Component 'Config' -Message 'Generated a new configuration key.'
        }
    }
    $script:CdConfigPassword = $password
    $password
}

function Initialize-CdRcloneConfig {
    # Makes sure rclone.conf exists and is encrypted with the configuration key.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'ConfigPassword', Justification = 'rclone receives the key through an environment variable of its own process only.')]
    param(
        [Parameter(Mandatory)][string]$RclonePath,
        [Parameter(Mandatory)][string]$ConfigPassword
    )
    if (Test-CdRcloneConfigEncrypted) { return }
    $file = (Get-CdContext).RcloneConfig
    if (Test-CdRcloneConfigExists) {
        Write-CdLog -Level WARN -Component 'Config' -Message 'Found an unencrypted rclone.conf - encrypting it now.'
    }
    else {
        [IO.File]::WriteAllText($file, '', [Text.Encoding]::ASCII)
    }
    $run = Invoke-CdProcess -FilePath $RclonePath -TimeoutSec 60 `
        -ArgumentList @('config', 'encryption', 'set', '--config', $file, '--password-command', 'cmd /c echo %CLOUDDRIVES_NEW_CONFIG_PASS%') `
        -Environment @{ CLOUDDRIVES_NEW_CONFIG_PASS = $ConfigPassword }
    if ($run.ExitCode -ne 0 -or -not (Test-CdRcloneConfigEncrypted)) {
        throw (New-CdException -Code 'CD-2002' -Detail (Protect-CdText ($run.StdErr + ' ' + $run.StdOut)))
    }
    Write-CdLog -Component 'Config' -Message 'rclone configuration is encrypted.'
}

function Backup-CdRcloneConfig {
    # Keeps the 10 most recent copies of the (encrypted) configuration before every change.
    $ctx = Get-CdContext
    if (-not (Test-CdRcloneConfigExists)) { return }
    if (-not (Test-Path -LiteralPath $ctx.BackupDir)) { [void](New-Item -ItemType Directory -Path $ctx.BackupDir -Force) }
    $target = Join-Path $ctx.BackupDir ('rclone-{0}.conf' -f (Get-Date).ToString('yyyyMMdd-HHmmss-fff'))
    Copy-Item -LiteralPath $ctx.RcloneConfig -Destination $target -Force
    Get-ChildItem -LiteralPath $ctx.BackupDir -Filter 'rclone-*.conf' -File |
        Sort-Object -Property Name -Descending |
        Select-Object -Skip 10 |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Get-CdRemoteNames {
    $result = Invoke-CdRc -Command 'config/listremotes'
    @($result.remotes | Where-Object { $_ })
}

function Remove-CdRemote {
    param([Parameter(Mandatory)][string]$Name)
    Backup-CdRcloneConfig
    [void](Invoke-CdRc -Command 'config/delete' -Body @{ name = $Name })
    Write-CdLog -Component 'Config' -Message "Removed remote '$Name'."
}
