# Localisation. Texts live in Resources\lang\<language>.json as flat "dotted.key": "text" pairs.
# German and English are provided; English is the fallback for missing keys.

$script:CdStrings = @{}
$script:CdFallbackStrings = @{}
$script:CdLanguage = 'en'

function Get-CdSystemLanguage {
    if ((Get-UICulture).TwoLetterISOLanguageName -eq 'de') { 'de' } else { 'en' }
}

function Read-CdLanguageFile {
    param([Parameter(Mandatory)][string]$Language)
    $table = @{}
    $file = Join-Path (Get-CdContext).ResourcesDir "lang\$Language.json"
    if (-not (Test-Path -LiteralPath $file)) { return $table }
    $json = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($property in $json.PSObject.Properties) { $table[$property.Name] = [string]$property.Value }
    $table
}

function Initialize-CdI18n {
    param([string]$Language = 'auto')
    if (-not $Language -or $Language -eq 'auto') { $Language = Get-CdSystemLanguage }
    if (@('de', 'en') -notcontains $Language) { $Language = 'en' }
    $script:CdLanguage = $Language
    $script:CdFallbackStrings = Read-CdLanguageFile -Language 'en'
    if ($Language -eq 'en') { $script:CdStrings = $script:CdFallbackStrings }
    else { $script:CdStrings = Read-CdLanguageFile -Language $Language }
}

function Get-CdLanguage { $script:CdLanguage }

function Get-CdText {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Key,
        [Parameter(Position = 1)][object[]]$FormatArgs
    )
    if ($script:CdStrings.Count -eq 0 -and $script:CdFallbackStrings.Count -eq 0) { Initialize-CdI18n }
    $text = $script:CdStrings[$Key]
    if ($null -eq $text) { $text = $script:CdFallbackStrings[$Key] }
    if ($null -eq $text) { return "[$Key]" }
    if ($FormatArgs) {
        try { return ($text -f $FormatArgs) } catch { return $text }
    }
    $text
}

function Format-CdSize {
    # Human readable size with binary units in the current UI language (e.g. "1,2 TB").
    param([AllowNull()][object]$Bytes)
    if ($null -eq $Bytes -or [string]$Bytes -eq '') { return '-' }
    $value = [double]$Bytes
    $units = @('B', 'KB', 'MB', 'GB', 'TB', 'PB')
    $i = 0
    while ($value -ge 1024 -and $i -lt ($units.Count - 1)) { $value = $value / 1024; $i++ }
    $culture = [Globalization.CultureInfo]::CurrentCulture
    if ($script:CdLanguage -eq 'de') { $culture = [Globalization.CultureInfo]::GetCultureInfo('de-DE') }
    elseif ($script:CdLanguage -eq 'en') { $culture = [Globalization.CultureInfo]::GetCultureInfo('en-US') }
    $format = 'N1'
    if ($i -eq 0) { $format = 'N0' }
    '{0} {1}' -f $value.ToString($format, $culture), $units[$i]
}
