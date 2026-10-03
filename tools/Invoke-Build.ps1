<#
.SYNOPSIS
    Quality gate: source normalisation check, PSScriptAnalyzer and Pester tests.
.PARAMETER Integration
    Also run the integration tests (they need WinFsp and rclone and mount real drive letters).
.PARAMETER Edition
    Run the tests in Windows PowerShell 5.1 ("Desktop"), PowerShell 7 ("Core"), "Both", or the "Current" host.
.PARAMETER TestsOnly
    Skip the static checks (used internally when tests run in another PowerShell edition).
#>
param(
    [switch]$Integration,
    [ValidateSet('Current', 'Desktop', 'Core', 'Both')][string]$Edition = 'Current',
    [switch]$TestsOnly
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$devTools = Join-Path $env:LOCALAPPDATA 'CloudDrives-dev\Modules'
if ($env:CLOUDDRIVES_DEVTOOLS) { $devTools = $env:CLOUDDRIVES_DEVTOOLS }
if (-not (Test-Path -LiteralPath (Join-Path $devTools 'Pester'))) { & (Join-Path $PSScriptRoot 'Install-DevTools.ps1') -Path $devTools }
$env:PSModulePath = $devTools + [IO.Path]::PathSeparator + $env:PSModulePath

$exitCode = 0
if (-not $TestsOnly) {
    Write-Host '=== Source files ===' -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'Format-SourceFiles.ps1') -Check
    if ($LASTEXITCODE -ne 0) { $exitCode = 1 }

    Write-Host '=== PSScriptAnalyzer ===' -ForegroundColor Cyan
    Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0
    $settingsFile = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
    $findings = @()
    foreach ($folder in @('src', 'tools')) {
        $findings += @(Invoke-ScriptAnalyzer -Path (Join-Path $root $folder) -Recurse -Settings $settingsFile)
    }
    if ($findings.Count -gt 0) {
        $findings | Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message | Out-String -Width 250 | Write-Host
        $exitCode = 1
    }
    else { Write-Host '  No findings.' -ForegroundColor Green }
}

if ($Edition -ne 'Current') {
    $hosts = @()
    if (@('Desktop', 'Both') -contains $Edition) { $hosts += "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" }
    if (@('Core', 'Both') -contains $Edition) { $hosts += 'pwsh.exe' }
    foreach ($exe in $hosts) {
        Write-Host "`n=== Tests in $exe ===" -ForegroundColor Cyan
        $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-TestsOnly')
        if ($Integration) { $arguments += '-Integration' }
        & $exe @arguments
        if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
    }
    exit $exitCode
}

Write-Host "=== Pester ($($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)) ===" -ForegroundColor Cyan
Import-Module Pester -RequiredVersion 5.7.1
$config = New-PesterConfiguration
$paths = @(Join-Path $root 'tests\Unit')
if ($Integration) { $paths += Join-Path $root 'tests\Integration' }
$config.Run.Path = $paths
$config.Run.Exit = $false
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Normal'
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = Join-Path $root ('TestResults\testResults-{0}.xml' -f $PSVersionTable.PSEdition)
$result = Invoke-Pester -Configuration $config
if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') { $exitCode = 1 }
exit $exitCode
