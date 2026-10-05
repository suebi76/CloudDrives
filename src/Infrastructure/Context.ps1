# Runtime context: resolves every path CloudDrives uses and identifies the current run.
# Runtime data lives in %LOCALAPPDATA%\CloudDrives. CLOUDDRIVES_HOME overrides it (tests, portable use).

$script:CdContext = $null

function Get-CdDefaultHome {
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CloudDrives'
}

function Initialize-CdContext {
    param(
        [string]$HomePath,
        [switch]$Silent
    )
    $defaultHome = (Get-CdDefaultHome).TrimEnd('\')
    $homeDir = $defaultHome
    if ($HomePath) { $homeDir = $HomePath }
    elseif ($env:CLOUDDRIVES_HOME) { $homeDir = $env:CLOUDDRIVES_HOME }
    $homeDir = [IO.Path]::GetFullPath($homeDir).TrimEnd('\')
    $isDefault = [string]::Equals($homeDir, $defaultHome, [StringComparison]::OrdinalIgnoreCase)

    # Short stable id of the home directory: keeps secrets and locks of test homes apart from the real ones.
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($homeDir.ToLowerInvariant())) } finally { $sha.Dispose() }
    $homeId = -join ($hash[0..3] | ForEach-Object { $_.ToString('x2') })

    $srcRoot = $script:CdModuleRoot
    $version = '0.0.0'
    $copyright = ''
    if ($ExecutionContext.SessionState.Module) {
        $module = $ExecutionContext.SessionState.Module
        $version = [string]$module.Version
        # A test version carries a label (0.3.3-preview.1), kept in the manifest as PSData.Prerelease.
        $label = $module.PrivateData.PSData.Prerelease
        if ($label) { $version += "-$label" }
        $copyright = [string]$module.Copyright
    }

    $script:CdContext = [pscustomobject]@{
        PSTypeName    = 'CloudDrives.Context'
        Version       = $version
        Copyright     = $copyright
        SrcRoot       = $srcRoot
        AppRoot       = Split-Path -Parent $srcRoot
        ResourcesDir  = Join-Path $srcRoot 'Resources'
        Home          = $homeDir
        IsDefaultHome = $isDefault
        HomeId        = $homeId
        SettingsFile  = Join-Path $homeDir 'settings.json'
        RcloneConfig  = Join-Path $homeDir 'rclone.conf'
        DepsDir       = Join-Path $homeDir 'deps'
        CacheDir      = Join-Path $homeDir 'cache'
        LogDir        = Join-Path $homeDir 'logs'
        StateDir      = Join-Path $homeDir 'state'
        BackupDir     = Join-Path $homeDir 'backup'
        RunId         = ([guid]::NewGuid().ToString('N')).Substring(0, 8)
        Silent        = [bool]$Silent
    }
    $script:CdContext
}

function Get-CdContext {
    if (-not $script:CdContext) { [void](Initialize-CdContext) }
    $script:CdContext
}

function Initialize-CdHome {
    # Creates the runtime folders. A newly created home is restricted to the current user and SYSTEM.
    $ctx = Get-CdContext
    $isNew = -not (Test-Path -LiteralPath $ctx.Home)
    foreach ($dir in @($ctx.Home, $ctx.DepsDir, $ctx.CacheDir, $ctx.LogDir, $ctx.StateDir, $ctx.BackupDir)) {
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    }
    if ($isNew) { [void](Protect-CdDirectory -Path $ctx.Home) }
}

function Protect-CdDirectory {
    # Restricts a directory to the current user and SYSTEM, with inheritance from the parent disabled.
    param([Parameter(Mandatory)][string]$Path)
    try {
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
        $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        $propagation = [Security.AccessControl.PropagationFlags]::None
        $sids = @(
            [Security.Principal.WindowsIdentity]::GetCurrent().User,
            (New-Object Security.Principal.SecurityIdentifier 'S-1-5-18')
        )
        foreach ($sid in $sids) {
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', $inherit, $propagation, 'Allow')))
        }
        Set-Acl -LiteralPath $Path -AclObject $acl
        $true
    }
    catch {
        Write-CdLog -Level WARN -Component 'Context' -Message "Could not restrict permissions on '$Path': $($_.Exception.Message)"
        $false
    }
}

function Test-CdPrivateDirectory {
    # True when only the current user and SYSTEM have access and inheritance is disabled.
    param([Parameter(Mandatory)][string]$Path)
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) { return $false }
    $allowed = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18')
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($allowed -notcontains $rule.IdentityReference.Value) { return $false }
    }
    $true
}

function Enter-CdLock {
    # Named mutex so that concurrent CloudDrives processes (e.g. autostart and menu) do not collide.
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutSec = 90
    )
    $mutex = New-Object System.Threading.Mutex($false, "Local\CloudDrives-$((Get-CdContext).HomeId)-$Name")
    $acquired = $false
    try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSec)) }
    catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) {
        $mutex.Dispose()
        throw (New-CdException -Code 'CD-9002' -Detail "lock '$Name' not acquired within $TimeoutSec s")
    }
    $mutex
}

function Exit-CdLock {
    param([System.Threading.Mutex]$Mutex)
    if (-not $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch { Write-CdLog -Level DEBUG -Component 'Context' -Message "ReleaseMutex: $($_.Exception.Message)" }
    $Mutex.Dispose()
}
