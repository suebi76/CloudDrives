# Registry of cloud providers. Each provider module (Providers\*.ps1) registers a definition with:
#   Id, RcloneType, NameKey, Kinds, PreferredLetters, MountOptions, RevokeUrl, NewParameters (script block)
#   and optionally GetIdentity (script block: @{ Config = remote configuration; AccessToken = token or $null }
#   -> @{ Id; Name } with a stable account ID, or $null)

$script:CdProviders = [ordered]@{}

function Register-CdProvider {
    param([Parameter(Mandatory)][hashtable]$Definition)
    foreach ($key in @('Id', 'RcloneType', 'NameKey', 'Kinds', 'PreferredLetters', 'MountOptions', 'NewParameters')) {
        if (-not $Definition.ContainsKey($key)) { throw "Provider definition is missing '$key'." }
    }
    $script:CdProviders[$Definition.Id] = $Definition
}

function Get-CdProvider {
    param([AllowNull()][AllowEmptyString()][string]$Id)
    if ($Id -and $script:CdProviders.Contains($Id)) { return $script:CdProviders[$Id] }
    $null
}

function Get-CdProviderList {
    @($script:CdProviders.Values)
}
