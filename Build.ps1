<#
.SYNOPSIS
  Builds everything: app.ico, ProcessInspector.exe, a portable zip and ProcessInspector-Setup.exe.

.DESCRIPTION
  Needs nothing but Windows: uses the C# compiler that ships with the .NET Framework
  (C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe).
  Output goes to .\dist\
#>
[CmdletBinding()]
param([switch]$NoSetup)

$ErrorActionPreference = 'Stop'
$root  = $PSScriptRoot
$dist  = Join-Path $root 'dist'
$stage = Join-Path $dist 'ProcessInspector'

# ---- 1. Icon --------------------------------------------------------------------------
function New-AppIcon([string]$out) {
    Add-Type -AssemblyName System.Drawing
    $sizes = 256, 128, 64, 48, 32, 24, 16
    $master = New-Object System.Drawing.Bitmap 256, 256
    $g = [System.Drawing.Graphics]::FromImage($master)
    $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)

    # rounded square, blue gradient
    $rect = New-Object System.Drawing.Rectangle 10, 10, 236, 236
    $r = 60
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($rect.X, $rect.Y, $r, $r, 180, 90)
    $path.AddArc($rect.Right - $r, $rect.Y, $r, $r, 270, 90)
    $path.AddArc($rect.Right - $r, $rect.Bottom - $r, $r, $r, 0, 90)
    $path.AddArc($rect.X, $rect.Bottom - $r, $r, $r, 90, 90)
    $path.CloseFigure()
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect,
        [System.Drawing.Color]::FromArgb(255, 52, 120, 214), [System.Drawing.Color]::FromArgb(255, 22, 58, 130), 65)
    $g.FillPath($brush, $path)

    # magnifying glass
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 24)
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $g.DrawEllipse($pen, 48, 40, 116, 116)          # lens, centre (106,98)
    $g.DrawLine($pen, 150, 142, 210, 202)           # handle

    # "process list" lines inside the lens
    $pen2 = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 13)
    $pen2.StartCap = 'Round'; $pen2.EndCap = 'Round'
    $g.DrawLine($pen2, 80, 78, 134, 78)
    $g.DrawLine($pen2, 80, 98, 134, 98)
    $g.DrawLine($pen2, 80, 118, 116, 118)
    $g.Dispose()

    $pngs = @()
    foreach ($s in $sizes) {
        $bmp = New-Object System.Drawing.Bitmap $s, $s
        $g2 = [System.Drawing.Graphics]::FromImage($bmp)
        $g2.SmoothingMode = 'AntiAlias'; $g2.InterpolationMode = 'HighQualityBicubic'; $g2.PixelOffsetMode = 'HighQuality'
        $g2.DrawImage($master, 0, 0, $s, $s)
        $g2.Dispose()
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngs += ,$ms.ToArray()
        $bmp.Dispose()
    }
    # a PNG copy for README / GitHub
    [IO.File]::WriteAllBytes((Join-Path (Split-Path $out) 'docs\icon-256.png'), $pngs[0])

    # ICO container with PNG-compressed frames
    $fs = [IO.File]::Create($out)
    $bw = New-Object System.IO.BinaryWriter($fs)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $s = $sizes[$i]; $b = if ($s -ge 256) { 0 } else { $s }
        $bw.Write([byte]$b); $bw.Write([byte]$b); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
        $offset += $pngs[$i].Length
    }
    foreach ($p in $pngs) { $bw.Write($p) }
    $bw.Close(); $fs.Close()
    $master.Dispose()
}

New-Item -ItemType Directory -Force -Path $dist, $stage, (Join-Path $root 'docs') | Out-Null
$ico = Join-Path $root 'app.ico'
Write-Host "Creating icon..." -ForegroundColor Cyan
New-AppIcon $ico

# ---- 2. Compiler ------------------------------------------------------------------------
$csc = Get-ChildItem "$env:WINDIR\Microsoft.NET\Framework64\v4*\csc.exe" -ErrorAction SilentlyContinue | Select-Object -Last 1
if (-not $csc) { $csc = Get-ChildItem "$env:WINDIR\Microsoft.NET\Framework\v4*\csc.exe" | Select-Object -Last 1 }
if (-not $csc) { throw 'csc.exe (C# compiler from the .NET Framework) not found.' }
$sma = Get-ChildItem "$env:WINDIR\Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation" -Recurse -Filter 'System.Management.Automation.dll' | Select-Object -First 1
if (-not $sma) { throw 'System.Management.Automation.dll not found in the GAC.' }

# ---- 3. ProcessInspector.exe -------------------------------------------------------------
Write-Host "Compiling ProcessInspector.exe..." -ForegroundColor Cyan
$exe = Join-Path $root 'ProcessInspector.exe'
& $csc.FullName /nologo /target:winexe /platform:anycpu /optimize+ "/win32icon:$ico" `
    "/r:$($sma.FullName)" /r:System.Windows.Forms.dll "/out:$exe" (Join-Path $root 'Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw "csc failed for Launcher.cs ($LASTEXITCODE)" }

# ---- 4. Stage + portable zip --------------------------------------------------------------
$files = 'ProcessInspector.exe','ProcessInspector.ps1','HandleEnum.cs','app.ico',
         'WhosLocking.ps1','ListProcesses.ps1','OpenFiles.ps1',
         'ProcessInspector.cmd','WhosLocking.cmd','ListProcesses.cmd',
         'Install.ps1','Uninstall.ps1','README.md','LICENSE'
Get-ChildItem $stage -File -ErrorAction SilentlyContinue | Remove-Item -Force
foreach ($f in $files) {
    $src = Join-Path $root $f
    if (Test-Path $src) { Copy-Item $src (Join-Path $stage $f) -Force } else { Write-Warning "missing: $f" }
}
$zip = Join-Path $dist 'ProcessInspector-portable.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Write-Host "Portable zip: $zip" -ForegroundColor Green

# ---- 5. Setup.exe (self-extracting) -------------------------------------------------------
if (-not $NoSetup) {
    Write-Host "Compiling ProcessInspector-Setup.exe..." -ForegroundColor Cyan
    $setup = Join-Path $dist 'ProcessInspector-Setup.exe'
    $res = Get-ChildItem $stage -File | ForEach-Object { "/resource:$($_.FullName),$($_.Name)" }
    & $csc.FullName /nologo /target:winexe /platform:anycpu /optimize+ "/win32icon:$ico" `
        /r:System.Windows.Forms.dll "/out:$setup" @res (Join-Path $root 'Setup.cs')
    if ($LASTEXITCODE -ne 0) { throw "csc failed for Setup.cs ($LASTEXITCODE)" }
    Write-Host "Installer: $setup" -ForegroundColor Green
}
Write-Host "Done." -ForegroundColor Green
