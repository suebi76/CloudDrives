# Loads the native helpers from Resources\Native.cs: the Windows Credential Manager, the detached process start, the
# status line of long operations and the identity of CloudDrives' console window.
# If compilation is not possible (e.g. Constrained Language Mode), callers fall back to pure PowerShell.

$script:CdNativeState = $null

function Initialize-CdNative {
    if ($null -ne $script:CdNativeState) { return $script:CdNativeState }
    try {
        if (-not ('CloudDrives.Native.CredentialStore' -as [type])) {
            $source = [IO.File]::ReadAllText((Join-Path (Get-CdContext).ResourcesDir 'Native.cs'), [Text.Encoding]::UTF8)
            Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
        }
        $script:CdNativeState = $true
    }
    catch {
        Write-CdLog -Level WARN -Component 'Native' -Message "Native helpers unavailable, using fallbacks: $($_.Exception.Message)"
        $script:CdNativeState = $false
    }
    $script:CdNativeState
}
