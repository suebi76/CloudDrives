# Uniform result objects and coded exceptions.
# Services return results (Success/Code/Message/Data) instead of writing to the screen; failures that
# cannot be handled locally are thrown as exceptions carrying a CloudDrives error code (CD-xxxx).

function New-CdResult {
    param(
        [bool]$Success = $true,
        [string]$Code = 'CD-0000',
        [string]$Message = '',
        [object]$Data = $null,
        [string]$Detail = ''
    )
    [pscustomobject]@{
        PSTypeName = 'CloudDrives.Result'
        Success    = $Success
        Code       = $Code
        Message    = $Message
        Detail     = $Detail
        Data       = $Data
    }
}

function New-CdException {
    param(
        [Parameter(Mandatory)][string]$Code,
        [string]$Message,
        [string]$Detail,
        [Exception]$InnerException
    )
    if (-not $Message) { $Message = Get-CdText "error.$Code.title" }
    if ($InnerException) { $ex = New-Object System.Exception($Message, $InnerException) }
    else { $ex = New-Object System.Exception($Message) }
    $ex.Data['CdCode'] = $Code
    if ($Detail) { $ex.Data['CdDetail'] = $Detail }
    $ex
}

function Get-CdExceptionFromError {
    param([Parameter(Mandatory)][object]$ErrorObject)
    if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) { return $ErrorObject.Exception }
    $ErrorObject
}

function Get-CdErrorCode {
    # Returns the CloudDrives code of an error; unknown errors are classified by their message text.
    param([Parameter(Mandatory)][object]$ErrorObject)
    $ex = Get-CdExceptionFromError $ErrorObject
    $current = $ex
    while ($current) {
        if ($current.Data -and $current.Data.Contains('CdCode')) { return [string]$current.Data['CdCode'] }
        $current = $current.InnerException
    }
    Resolve-CdErrorCode -Text ([string]$ex.Message)
}

function Get-CdErrorDetail {
    param([Parameter(Mandatory)][object]$ErrorObject)
    $ex = Get-CdExceptionFromError $ErrorObject
    $current = $ex
    while ($current) {
        if ($current.Data -and $current.Data.Contains('CdDetail')) { return [string]$current.Data['CdDetail'] }
        $current = $current.InnerException
    }
    [string]$ex.Message
}
