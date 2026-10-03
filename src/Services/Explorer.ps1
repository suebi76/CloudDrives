# Explorer integration: friendly drive names. Network mounts are shown as "Name (\\CloudDrives) (K:)"
# by default; the _LabelFromReg value under MountPoints2 makes Explorer show "Google Pro (K:)" instead.

function Get-CdExplorerKey {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Drive)
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2\##CloudDrives#$($Drive.id)"
}

function Set-CdDriveLabel {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Drive)
    try {
        $key = Get-CdExplorerKey -Drive $Drive
        if (-not (Test-Path -LiteralPath $key)) { [void](New-Item -Path $key -Force) }
        Set-ItemProperty -LiteralPath $key -Name '_LabelFromReg' -Value ([string]$Drive.label)
    }
    catch {
        Write-CdLog -Level WARN -Component 'Explorer' -Message "Could not set the Explorer label of '$($Drive.id)': $($_.Exception.Message)"
    }
}

function Remove-CdDriveLabel {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Drive)
    $key = Get-CdExplorerKey -Drive $Drive
    if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue }
}
