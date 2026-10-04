# User settings (<home>\settings.json): accounts, drives and preferences - never any secrets.
# Settings are held as ordered hashtables; the file is written atomically with a .bak copy.

$script:CdSettingsSchemaVersion = 1
$script:CdSettings = $null
$script:CdIdPattern = '^[a-z0-9][a-z0-9-]{0,39}$'

function ConvertTo-CdJsonText {
    # JSON for other programs (--json): characters outside ASCII are escaped as \uXXXX, so the text arrives intact
    # whatever code page the reading console or script uses.
    param([Parameter(Mandatory)][AllowNull()][object]$InputObject, [int]$Depth = 5)
    $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth
    [regex]::Replace($json, '[^\x00-\x7F]', { param($Match) '\u{0:x4}' -f [int][char]$Match.Value })
}

function ConvertTo-CdHashtable {
    # Recursively converts ConvertFrom-Json output into ordered hashtables and arrays.
    param([AllowNull()][object]$InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $table = [ordered]@{}
        foreach ($key in $InputObject.Keys) { $table[[string]$key] = ConvertTo-CdHashtable $InputObject[$key] }
        return $table
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $table = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) { $table[$property.Name] = ConvertTo-CdHashtable $property.Value }
        return $table
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $list = @(foreach ($item in $InputObject) { ConvertTo-CdHashtable $item })
        return , $list
    }
    $InputObject
}

function Add-CdArrayItem {
    # Appends one item (even a hashtable) to an array without PowerShell unrolling it.
    param([AllowNull()][object[]]$Array, [Parameter(Mandatory)][object]$Item)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($existing in @($Array)) { if ($null -ne $existing) { $list.Add($existing) } }
    $list.Add($Item)
    , $list.ToArray()
}

function New-CdDefaultSettings {
    [ordered]@{
        schemaVersion = $script:CdSettingsSchemaVersion
        language      = 'auto'
        securityMode  = 'dpapi'
        logLevel      = 'INFO'
        notifications = 'errors'
        autostartAsked = $false
        installAsked  = $false
        lastUpdateCheck = ''
        profile       = 'standard'
        cache         = [ordered]@{ dir = ''; maxSizePerDrive = '10G'; maxAge = '24h' }
        accounts      = @()
        drives        = @()
    }
}

function Complete-CdSettings {
    # Adds keys introduced by newer versions with their default values.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    $defaults = New-CdDefaultSettings
    foreach ($key in $defaults.Keys) {
        if (-not $Settings.Contains($key) -or $null -eq $Settings[$key]) { $Settings[$key] = $defaults[$key]; continue }
        if ($defaults[$key] -is [System.Collections.IDictionary]) {
            foreach ($sub in $defaults[$key].Keys) {
                if (-not $Settings[$key].Contains($sub)) { $Settings[$key][$sub] = $defaults[$key][$sub] }
            }
        }
    }
    $Settings.accounts = @($Settings.accounts | Where-Object { $null -ne $_ })
    $Settings.drives = @($Settings.drives | Where-Object { $null -ne $_ })
    $Settings
}

function Update-CdSettingsSchema {
    # Migrates settings written by older versions step by step to the current schema.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    $version = 0
    if ($Settings.Contains('schemaVersion')) { $version = [int]$Settings.schemaVersion }
    if ($version -gt $script:CdSettingsSchemaVersion) {
        throw (New-CdException -Code 'CD-2005' -Detail "settings schema $version, supported $($script:CdSettingsSchemaVersion)")
    }
    # Future migrations: while ($version -lt $script:CdSettingsSchemaVersion) { switch ($version) { 1 { ...; $version = 2 } } }
    $Settings.schemaVersion = $script:CdSettingsSchemaVersion
    $Settings
}

function Get-CdSettings {
    param([switch]$Reload)
    if ($script:CdSettings -and -not $Reload) { return $script:CdSettings }
    $ctx = Get-CdContext
    if (Test-Path -LiteralPath $ctx.SettingsFile) {
        try {
            $raw = [IO.File]::ReadAllText($ctx.SettingsFile, [Text.Encoding]::UTF8)
            $settings = ConvertTo-CdHashtable ($raw | ConvertFrom-Json)
        }
        catch {
            throw (New-CdException -Code 'CD-2001' -Detail $_.Exception.Message -InnerException $_.Exception)
        }
        $settings = Update-CdSettingsSchema -Settings $settings
        $settings = Complete-CdSettings -Settings $settings
    }
    else {
        $settings = New-CdDefaultSettings
    }
    $script:CdSettings = $settings
    $settings
}

function Test-CdSettings {
    # Returns a list of problems; an empty list means the settings are valid.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    $problems = New-Object System.Collections.Generic.List[string]
    $accountIds = @{}
    foreach ($account in @($Settings.accounts)) {
        if (-not ($account.id -match $script:CdIdPattern)) { $problems.Add("invalid account id '$($account.id)'"); continue }
        if ($accountIds.ContainsKey($account.id)) { $problems.Add("duplicate account id '$($account.id)'") }
        $accountIds[$account.id] = $true
        if (-not (Get-CdProvider -Id $account.provider)) { $problems.Add("account '$($account.id)': unknown provider '$($account.provider)'") }
        if ([string]::IsNullOrWhiteSpace($account.label)) { $problems.Add("account '$($account.id)': empty label") }
    }
    $driveIds = @{}
    $letters = @{}
    foreach ($drive in @($Settings.drives)) {
        if (-not ($drive.id -match $script:CdIdPattern)) { $problems.Add("invalid drive id '$($drive.id)'"); continue }
        if ($driveIds.ContainsKey($drive.id)) { $problems.Add("duplicate drive id '$($drive.id)'") }
        $driveIds[$drive.id] = $true
        if (-not $accountIds.ContainsKey([string]$drive.account)) { $problems.Add("drive '$($drive.id)': unknown account '$($drive.account)'") }
        if (-not ([string]$drive.letter -match '^[D-Z]$')) { $problems.Add("drive '$($drive.id)': invalid letter '$($drive.letter)'") }
        elseif ($letters.ContainsKey($drive.letter)) { $problems.Add("drive '$($drive.id)': letter $($drive.letter) is used twice") }
        else { $letters[$drive.letter] = $true }
        if ([string]::IsNullOrWhiteSpace($drive.label)) { $problems.Add("drive '$($drive.id)': empty label") }
        if ($drive.encrypted -and [string]::IsNullOrWhiteSpace($drive.path)) { $problems.Add("vault drive '$($drive.id)': no folder") }
    }
    if (@('dpapi', 'masterPassword') -notcontains $Settings.securityMode) { $problems.Add("invalid securityMode '$($Settings.securityMode)'") }
    , $problems.ToArray()
}

function Save-CdSettings {
    param([System.Collections.IDictionary]$Settings)
    if (-not $Settings) { $Settings = Get-CdSettings }
    $problems = Test-CdSettings -Settings $Settings
    if ($problems.Count -gt 0) { throw (New-CdException -Code 'CD-2001' -Detail ($problems -join '; ')) }
    Initialize-CdHome
    $ctx = Get-CdContext
    $json = ConvertTo-Json -InputObject $Settings -Depth 10
    $tmp = "$($ctx.SettingsFile).tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $ctx.SettingsFile) { [IO.File]::Replace($tmp, $ctx.SettingsFile, "$($ctx.SettingsFile).bak") }
    else { [IO.File]::Move($tmp, $ctx.SettingsFile) }
    $script:CdSettings = $Settings
    Write-CdLog -Level DEBUG -Component 'Settings' -Message 'Settings saved.'
}

function Get-CdAccount {
    param([Parameter(Mandatory)][string]$Id)
    @((Get-CdSettings).accounts) | Where-Object { $_.id -eq $Id } | Select-Object -First 1
}

function Get-CdDrive {
    param([Parameter(Mandatory)][string]$Id)
    @((Get-CdSettings).drives) | Where-Object { $_.id -eq $Id -or $_.letter -eq $Id.TrimEnd(':') } | Select-Object -First 1
}
