# CloudDrives module loader.
# Components are dot-sourced layer by layer so that lower layers never depend on higher ones:
#   Infrastructure -> Providers -> Services -> Commands -> UI
$script:CdModuleRoot = $PSScriptRoot

foreach ($layer in @('Infrastructure', 'Providers', 'Services', 'Commands', 'UI')) {
    $layerDir = Join-Path $PSScriptRoot $layer
    if (-not (Test-Path -LiteralPath $layerDir)) { continue }
    foreach ($file in (Get-ChildItem -LiteralPath $layerDir -Filter '*.ps1' -File | Sort-Object -Property Name)) {
        . $file.FullName
    }
}
