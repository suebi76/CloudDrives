@{
    RootModule           = 'CloudDrives.psm1'
    ModuleVersion        = '0.2.4'
    GUID                 = '0edc3a22-ce54-4e92-8d9f-49ba4f0cadc9'
    Author               = 'Steffen Schwabe'
    Copyright            = '(c) 2026 Steffen Schwabe. MIT License.'
    Description          = 'Mounts OneDrive and Google Drive accounts as Windows drive letters using rclone and WinFsp.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @('Invoke-CdCli')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('rclone', 'OneDrive', 'GoogleDrive', 'WinFsp', 'mount', 'Windows')
            ProjectUri = 'https://github.com/suebi76/CloudDrives'
            LicenseUri = 'https://github.com/suebi76/CloudDrives/blob/main/LICENSE'
        }
    }
}
