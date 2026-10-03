# Stable, readable ids for accounts and drives (also used in rclone remote names and Explorer keys).

function ConvertTo-CdSlug {
    # "Schule (Workspace)" -> "schule-workspace"; German umlauts are transliterated, other accents removed.
    param([AllowNull()][AllowEmptyString()][string]$Text, [int]$MaxLength = 30)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $value = $Text.ToLowerInvariant()
    $replacements = @(
        @([string][char]0x00E4, 'ae'), @([string][char]0x00F6, 'oe'), @([string][char]0x00FC, 'ue'), @([string][char]0x00DF, 'ss')
    )
    foreach ($pair in $replacements) { $value = $value.Replace($pair[0], $pair[1]) }
    $decomposed = $value.Normalize([Text.NormalizationForm]::FormD)
    $builder = New-Object System.Text.StringBuilder
    foreach ($char in $decomposed.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($char) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$builder.Append($char) }
    }
    $value = [regex]::Replace($builder.ToString(), '[^a-z0-9]+', '-').Trim('-')
    if ($value.Length -gt $MaxLength) { $value = $value.Substring(0, $MaxLength).Trim('-') }
    $value
}

function New-CdUniqueId {
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [AllowNull()][AllowEmptyCollection()][string[]]$Existing = @(),
        [string]$Fallback = 'item'
    )
    $base = ConvertTo-CdSlug -Text $Text
    if (-not $base) { $base = $Fallback }
    $id = $base
    $counter = 2
    while (@($Existing) -contains $id) { $id = "$base-$counter"; $counter++ }
    $id
}

function Get-CdAccountRemoteName {
    param([Parameter(Mandatory)][string]$AccountId)
    "cd-$AccountId"
}

function Get-CdVaultRemoteName {
    param([Parameter(Mandatory)][string]$DriveId)
    "cd-vault-$DriveId"
}
