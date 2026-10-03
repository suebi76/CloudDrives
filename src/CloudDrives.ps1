# CloudDrives entry point (started by CloudDrives.bat). Run "CloudDrives.bat help" for usage.
$ErrorActionPreference = 'Stop'
try {
    Import-Module -Name (Join-Path $PSScriptRoot 'CloudDrives.psd1') -Force
}
catch {
    Write-Host "CloudDrives could not be loaded: $($_.Exception.Message)" -ForegroundColor Red
    exit 4
}
$exitCode = @(Invoke-CdCli -Arguments @($args)) | Where-Object { $_ -is [int] } | Select-Object -Last 1
if ($null -eq $exitCode) { $exitCode = 0 }
exit $exitCode
