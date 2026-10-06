# Secret storage. Primary: Windows Credential Manager (DPAPI-protected, current user only).
# Fallback: DPAPI-encrypted file in <home>\state\secrets. Secrets never touch settings.json or the repository.

function Get-CdSecretTarget {
    param([Parameter(Mandatory)][string]$Name)
    $ctx = Get-CdContext
    if ($ctx.IsDefaultHome) { return "CloudDrives:$Name" }
    "CloudDrives[$($ctx.HomeId)]:$Name"
}

function Get-CdSecretBackend {
    # Where secrets live: the Windows Credential Manager - or, without the native helpers or with
    # CLOUDDRIVES_SECRET_BACKEND=dpapi, a DPAPI-protected file in state\secrets.
    if ($env:CLOUDDRIVES_SECRET_BACKEND -eq 'dpapi') { return 'dpapi' }
    if (Initialize-CdNative) { return 'credman' }
    'dpapi'
}

function Get-CdSecretFile {
    param([Parameter(Mandatory)][string]$Name)
    Join-Path (Join-Path (Get-CdContext).StateDir 'secrets') "$Name.dpapi"
}

function ConvertTo-CdBase64Url {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-CdRandomSecret {
    # Cryptographically random secret, URL/command-line safe (A-Z a-z 0-9 - _).
    param([int]$Bytes = 32)
    $buffer = New-Object byte[] $Bytes
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
    ConvertTo-CdBase64Url -Bytes $buffer
}

function Set-CdSecret {
    # Stores a secret (the key of the rclone configuration, the RC credentials) for the current user.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The value is immediately protected with DPAPI.')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    if ((Get-CdSecretBackend) -eq 'credman') {
        try {
            [CloudDrives.Native.CredentialStore]::Write((Get-CdSecretTarget $Name), 'CloudDrives', $Value, 'CloudDrives - managed automatically, do not edit')
            Remove-CdSecretFile -Name $Name
            return
        }
        catch {
            Write-CdLog -Level WARN -Component 'Secrets' -Message "Credential Manager write failed, using DPAPI file: $($_.Exception.Message)"
        }
    }
    $file = Get-CdSecretFile -Name $Name
    $dir = Split-Path -Parent $file
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $secure = ConvertTo-SecureString -String $Value -AsPlainText -Force
    [IO.File]::WriteAllText($file, (ConvertFrom-SecureString -SecureString $secure), [Text.Encoding]::ASCII)
}

function Get-CdSecret {
    # Reads a secret - from the Credential Manager, otherwise from its DPAPI file; $null when there is none.
    param([Parameter(Mandatory)][string]$Name)
    if ((Get-CdSecretBackend) -eq 'credman') {
        try {
            $value = [CloudDrives.Native.CredentialStore]::Read((Get-CdSecretTarget $Name))
            if ($null -ne $value) { return $value }
        }
        catch {
            Write-CdLog -Level WARN -Component 'Secrets' -Message "Credential Manager read failed: $($_.Exception.Message)"
        }
    }
    $file = Get-CdSecretFile -Name $Name
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try {
        $secure = ConvertTo-SecureString -String ([IO.File]::ReadAllText($file).Trim())
        return (New-Object System.Management.Automation.PSCredential('clouddrives', $secure)).GetNetworkCredential().Password
    }
    catch {
        throw (New-CdException -Code 'CD-2003' -Detail "DPAPI secret '$Name' cannot be decrypted: $($_.Exception.Message)")
    }
}

function Remove-CdSecretFile {
    param([Parameter(Mandatory)][string]$Name)
    $file = Get-CdSecretFile -Name $Name
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
}

function Remove-CdSecret {
    param([Parameter(Mandatory)][string]$Name)
    if (Initialize-CdNative) {
        try { [void][CloudDrives.Native.CredentialStore]::Delete((Get-CdSecretTarget $Name)) }
        catch { Write-CdLog -Level WARN -Component 'Secrets' -Message "Credential Manager delete failed: $($_.Exception.Message)" }
    }
    Remove-CdSecretFile -Name $Name
}
