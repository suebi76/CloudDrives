# Error knowledge base (Resources\errors.json): maps rclone/system messages to CloudDrives codes.
# Each code has a localized title and fix text (error.<code>.title / error.<code>.fix) and an optional
# automatic action that the UI can offer.

$script:CdErrorCatalog = $null

function Get-CdErrorCatalog {
    if (-not $script:CdErrorCatalog) {
        $file = Join-Path (Get-CdContext).ResourcesDir 'errors.json'
        $json = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $script:CdErrorCatalog = @($json.errors)
    }
    $script:CdErrorCatalog
}

function Resolve-CdErrorCode {
    # Classifies free text (rclone output, exception messages) into a CloudDrives error code.
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'CD-9000' }
    foreach ($entry in Get-CdErrorCatalog) {
        foreach ($pattern in @($entry.patterns)) {
            if ($pattern -and $Text -match $pattern) { return [string]$entry.code }
        }
    }
    'CD-9000'
}

function Get-CdErrorEntry {
    param([Parameter(Mandatory)][string]$Code)
    Get-CdErrorCatalog | Where-Object { $_.code -eq $Code } | Select-Object -First 1
}

function Get-CdErrorInfo {
    # Everything the UI needs to explain an error: code, title, fix, redacted detail and suggested action.
    param([Parameter(Mandatory)][object]$ErrorObject)
    $code = Get-CdErrorCode $ErrorObject
    $detail = Protect-CdText (Get-CdErrorDetail $ErrorObject)
    $entry = Get-CdErrorEntry -Code $code
    $action = $null
    if ($entry) { $action = $entry.action }
    [pscustomobject]@{
        PSTypeName = 'CloudDrives.ErrorInfo'
        Code       = $code
        Title      = Get-CdText "error.$code.title"
        Fix        = Get-CdText "error.$code.fix"
        Detail     = $detail
        Action     = $action
    }
}
