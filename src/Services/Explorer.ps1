# Explorer integration: friendly drive names and the CloudDrives icon.
# Network mounts are shown as "Name (\\CloudDrives) (K:)" by default; the _LabelFromReg value under
# MountPoints2 makes Explorer show "Google Pro (K:)" instead. Per-user drive icons live under
# HKCU\Software\Classes\Applications\Explorer.exe\Drives\<letter>\DefaultIcon.

function Get-CdExplorerKey {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Drive)
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2\##CloudDrives#$($Drive.id)"
}

function Get-CdDriveIconKey {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Drive)
    "HKCU:\Software\Classes\Applications\Explorer.exe\Drives\$($Drive.letter)"
}

function Set-CdDriveLabel {
    # Sets the Explorer name and icon of a drive. -AppRoot selects whose icon file is referenced.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Drive, [string]$AppRoot)
    try {
        $key = Get-CdExplorerKey -Drive $Drive
        if (-not (Test-Path -LiteralPath $key)) { [void](New-Item -Path $key -Force) }
        Set-ItemProperty -LiteralPath $key -Name '_LabelFromReg' -Value ([string]$Drive.label)

        if (-not $AppRoot) { $AppRoot = (Get-CdContext).AppRoot }
        $icon = Join-Path $AppRoot 'src\Resources\icons\clouddrives.ico'
        if (Test-Path -LiteralPath $icon) {
            $iconKey = Join-Path (Get-CdDriveIconKey -Drive $Drive) 'DefaultIcon'
            if (-not (Test-Path -LiteralPath $iconKey)) { [void](New-Item -Path $iconKey -Force) }
            Set-ItemProperty -LiteralPath $iconKey -Name '(default)' -Value "$icon,0"
        }
    }
    catch {
        Write-CdLog -Level WARN -Component 'Explorer' -Message "Could not set the Explorer label of '$($Drive.id)': $($_.Exception.Message)"
    }
}

function Remove-CdDriveLabel {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Drive)
    foreach ($key in @((Get-CdExplorerKey -Drive $Drive), (Get-CdDriveIconKey -Drive $Drive))) {
        if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
