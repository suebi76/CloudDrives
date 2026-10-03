@{
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # The console UI intentionally writes coloured output directly to the host.
        'PSAvoidUsingWriteHost',
        # CloudDrives is an application module, not a cmdlet library; -WhatIf support adds no value here.
        'PSUseShouldProcessForStateChangingFunctions',
        # Internal functions such as Get-CdFreeDriveLetters return collections; plural names read better.
        'PSUseSingularNouns'
    )

    Rules        = @{
        # Everything must keep working on the Windows PowerShell 5.1 that ships with Windows.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
    }
}
