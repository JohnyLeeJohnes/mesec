# Vygeneruje assets/mesec.ico a assets/mesec.png:
#   powershell -ExecutionPolicy Bypass -File tools/make-icon.ps1
Add-Type -AssemblyName System.Drawing

$assets = Join-Path $PSScriptRoot '..\assets'
New-Item -ItemType Directory -Force $assets | Out-Null

function Color($hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
function Point($x, $y) { New-Object System.Drawing.PointF $x, $y }

# Obdélník se zaoblenými rohy; $bottom = $false nechá spodní hranu rovnou (sloupec grafu)
function Rounded($x, $y, $w, $h, $r, $bottom = $true) {
    $d = 2 * $r
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($x, $y, $d, $d, 180, 90)
    $path.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    if ($bottom) {
        $path.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
        $path.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    } else {
        $path.AddLine($x + $w, $y + $h, $x, $y + $h)
    }
    $path.CloseFigure()
    $path
}

# Každá velikost se kreslí zvlášť (4x větší a pak zmenšená), malé dostanou jednodušší kresbu.
function Draw([int]$px) {
    $size = $px * 4
    $s = $size / 256.0
    $small = $px -le 32

    $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'

    $tile = Rounded 0 0 $size $size (60 * $s)
    $green = New-Object System.Drawing.Drawing2D.LinearGradientBrush (Point 0 0), (Point 0 $size), (Color '#2A5444'), (Color '#0B1410')
    $g.FillPath($green, $tile)

    # Tři rostoucí sloupce
    if ($small) { $bars = @(30, 96), @(98, 146), @(166, 196); $width = 60; $base = 226 }
    else { $bars = @(52, 74), @(108, 112), @(164, 152); $width = 42; $base = 208 }
    $mint = New-Object System.Drawing.Drawing2D.LinearGradientBrush (Point 0 (40 * $s)), (Point 0 ($base * $s)), (Color '#A4F0D0'), (Color '#3FB485')
    foreach ($bar in $bars) {
        $g.FillPath($mint, (Rounded ($bar[0] * $s) (($base - $bar[1]) * $s) ($width * $s) ($bar[1] * $s) (10 * $s) $false))
    }

    if (-not $small) {
        # Mince nad nejnižším sloupcem
        $gold = New-Object System.Drawing.Drawing2D.LinearGradientBrush (Point (44 * $s) (40 * $s)), (Point (104 * $s) (100 * $s)), (Color '#FFE9A6'), (Color '#EFB23E')
        $g.FillEllipse($gold, 46 * $s, 44 * $s, 54 * $s, 54 * $s)
        $rim = New-Object System.Drawing.Pen (Color '#C98A1E'), (4 * $s)
        $g.DrawEllipse($rim, 57 * $s, 55 * $s, 32 * $s, 32 * $s)

        # Tenká světlá linka, ať má ikona hranu i na tmavém pozadí
        $edge = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(36, 255, 255, 255)), (3 * $s)
        $edge.Alignment = 'Inset'
        $g.DrawPath($edge, $tile)
    }
    $g.Dispose()

    $out = New-Object System.Drawing.Bitmap $px, $px, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($out)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.PixelOffsetMode = 'HighQuality'
    $g.DrawImage($bmp, 0, 0, $px, $px)
    $g.Dispose()
    $bmp.Dispose()

    $out
}

function Png($bmp) {
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    , $ms.ToArray()
}

# Klasický snímek ICO: hlavička BITMAPINFOHEADER, pixely BGRA zdola nahoru, prázdná maska
function Dib($bmp) {
    $px = $bmp.Width
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter $ms
    $w.Write([uint32]40); $w.Write([int32]$px); $w.Write([int32]($px * 2))   # výška = obrázek + maska
    $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write((New-Object byte[] 24))

    $rect = New-Object System.Drawing.Rectangle 0, 0, $px, $px
    $data = $bmp.LockBits($rect, 'ReadOnly', [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $row = New-Object byte[] ($px * 4)
    for ($y = $px - 1; $y -ge 0; $y--) {
        [System.Runtime.InteropServices.Marshal]::Copy([IntPtr]($data.Scan0.ToInt64() + $y * $data.Stride), $row, 0, $row.Length)
        $w.Write($row)
    }
    $bmp.UnlockBits($data)

    $maskStride = [int][Math]::Ceiling($px / 32.0) * 4
    $w.Write((New-Object byte[] ($maskStride * $px)))
    $w.Flush()
    , $ms.ToArray()
}

# 256 px jako PNG, menší jako BMP: tak to čtou i starší nástroje.
$sizes = 256, 64, 48, 40, 32, 24, 20, 16
$bitmaps = $sizes | ForEach-Object { Draw $_ }
$frames = $bitmaps | ForEach-Object { if ($_.Width -eq 256) { , (Png $_) } else { , (Dib $_) } }

# ICO = hlavička + adresář + snímky za sebou
$ico = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter $ico
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $dim = [byte]($sizes[$i] % 256)   # 256 px se zapisuje jako 0
    $w.Write($dim); $w.Write($dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]$frames[$i].Length); $w.Write([uint32]$offset)
    $offset += $frames[$i].Length
}
foreach ($frame in $frames) { $w.Write($frame) }
$w.Flush()

[System.IO.File]::WriteAllBytes((Join-Path $assets 'mesec.ico'), $ico.ToArray())
[System.IO.File]::WriteAllBytes((Join-Path $assets 'mesec.png'), (Png $bitmaps[0]))
"OK: assets/mesec.ico ($($sizes -join ', ') px), assets/mesec.png"
