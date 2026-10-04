<#
.SYNOPSIS
    Draws the CloudDrives icon (a cloud above a drive) and writes src\Resources\icons\clouddrives.ico.
.DESCRIPTION
    The .ico contains PNG frames (16, 24, 32, 48, 64, 128, 256 px), which Windows Vista and later support.
    Run it only when the design changes; the generated file is committed.
#>
param([string]$OutFile = (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Resources\icons\clouddrives.ico'))

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function New-IconFrame {
    param([int]$Size)
    $bitmap = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $s = $Size / 256.0

        # Drive body (rounded rectangle) with a status light.
        $x = 28 * $s; $y = 150 * $s; $w = 200 * $s; $h = 78 * $s; $r = 18 * $s
        $drive = [System.Drawing.Drawing2D.GraphicsPath]::new()
        $drive.AddArc($x, $y, 2 * $r, 2 * $r, 180, 90)
        $drive.AddArc($x + $w - 2 * $r, $y, 2 * $r, 2 * $r, 270, 90)
        $drive.AddArc($x + $w - 2 * $r, $y + $h - 2 * $r, 2 * $r, 2 * $r, 0, 90)
        $drive.AddArc($x, $y + $h - 2 * $r, 2 * $r, 2 * $r, 90, 90)
        $drive.CloseFigure()
        $driveBrush = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
            [System.Drawing.PointF]::new(0, $y), [System.Drawing.PointF]::new(0, $y + $h),
            [System.Drawing.Color]::FromArgb(255, 72, 84, 104), [System.Drawing.Color]::FromArgb(255, 42, 50, 64))
        $g.FillPath($driveBrush, $drive)
        $light = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 74, 222, 128))
        $g.FillEllipse($light, 190 * $s, 181 * $s, 18 * $s, 18 * $s)

        # Cloud made of overlapping circles on a flat base.
        $cloud = [System.Drawing.Drawing2D.GraphicsPath]::new()
        $cloud.AddEllipse(40 * $s, 70 * $s, 84 * $s, 84 * $s)
        $cloud.AddEllipse(88 * $s, 34 * $s, 104 * $s, 104 * $s)
        $cloud.AddEllipse(150 * $s, 76 * $s, 74 * $s, 74 * $s)
        $cloud.AddRectangle([System.Drawing.RectangleF]::new(80 * $s, 106 * $s, 110 * $s, 48 * $s))
        $cloudBrush = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
            [System.Drawing.PointF]::new(0, 34 * $s), [System.Drawing.PointF]::new(0, 154 * $s),
            [System.Drawing.Color]::FromArgb(255, 96, 178, 255), [System.Drawing.Color]::FromArgb(255, 37, 99, 235))
        $cloud.FillMode = [System.Drawing.Drawing2D.FillMode]::Winding
        $g.FillPath($cloudBrush, $cloud)

        $stream = [System.IO.MemoryStream]::new()
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        , $stream.ToArray()
    }
    finally {
        $g.Dispose()
        $bitmap.Dispose()
    }
}

$sizes = @(16, 24, 32, 48, 64, 128, 256)
$frames = @(foreach ($size in $sizes) { , (New-IconFrame -Size $size) })

$out = [System.IO.MemoryStream]::new()
$writer = [System.IO.BinaryWriter]::new($out)
$writer.Write([UInt16]0); $writer.Write([UInt16]1); $writer.Write([UInt16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $dimension = $sizes[$i]
    if ($dimension -ge 256) { $dimension = 0 }
    $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
    $writer.Write([byte]0); $writer.Write([byte]0)
    $writer.Write([UInt16]1); $writer.Write([UInt16]32)
    $writer.Write([UInt32]$frames[$i].Length); $writer.Write([UInt32]$offset)
    $offset += $frames[$i].Length
}
foreach ($frame in $frames) { $writer.Write([byte[]]$frame) }
$writer.Flush()

$dir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
[IO.File]::WriteAllBytes($OutFile, $out.ToArray())
Write-Host "  Icon written: $OutFile ($($out.Length) bytes)"
