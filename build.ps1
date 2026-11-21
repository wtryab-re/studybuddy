# Builds "dist\Study Buddy.exe" from src\ using the C# compiler that ships with Windows (.NET Framework 4.8).
# Nothing to install. Run:  powershell -ExecutionPolicy Bypass -File build.ps1
# The app icon comes from icon.png in this folder.

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$fw   = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
$wpf  = "$fw\WPF"
$obj  = Join-Path $root "build"
$dist = Join-Path $root "dist"
New-Item -ItemType Directory -Force $obj, $dist | Out-Null

Add-Type -AssemblyName System.Drawing

# ---- Icon: a square 256 px PNG to embed (window/taskbar/tray), and a multi-size .ico for the .exe file itself
$srcImg = [System.Drawing.Image]::FromFile((Join-Path $root "icon.png"))
function New-Square([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $scale = [math]::Min([double]$size / $srcImg.Width, [double]$size / $srcImg.Height)
    $w = [int]($srcImg.Width * $scale); $h = [int]($srcImg.Height * $scale)
    $g.DrawImage($srcImg, [int](($size - $w) / 2), [int](($size - $h) / 2), $w, $h)
    $g.Dispose()
    return $bmp
}
function Get-Png($bmp) {
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    return , $ms.ToArray()
}

(New-Square 256).Save((Join-Path $obj "icon.png"), [System.Drawing.Imaging.ImageFormat]::Png)

$sizes = 16, 24, 32, 48, 64, 128, 256
$images = @(foreach ($s in $sizes) { , (Get-Png (New-Square $s)) })
$fs = [System.IO.File]::Create((Join-Path $obj "app.ico"))
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)    # header: reserved, type=icon, count
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }                     # 0 means 256
    $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$images[$i].Length); $bw.Write([uint32]$offset)
    $offset += $images[$i].Length
}
foreach ($img in $images) { $bw.Write($img) }
$bw.Close()
$srcImg.Dispose()

# ---- Compile
$out = Join-Path $dist "Study Buddy.exe"
$cscArgs = @(
    "/nologo", "/target:winexe", "/optimize+", "/platform:anycpu",
    "/out:$out",
    "/win32icon:$(Join-Path $obj 'app.ico')",
    "/resource:$(Join-Path $obj 'icon.png'),icon.png",
    "/resource:$(Join-Path $root 'src\window.xaml'),window.xaml",
    "/r:$wpf\PresentationFramework.dll", "/r:$wpf\PresentationCore.dll", "/r:$wpf\WindowsBase.dll",
    "/r:$wpf\UIAutomationClient.dll", "/r:$wpf\UIAutomationTypes.dll",
    "/r:$fw\System.Xaml.dll", "/r:$fw\System.Windows.Forms.dll", "/r:$fw\System.Drawing.dll",
    "/r:$fw\System.Web.Extensions.dll",
    (Join-Path $root "src\StudyBuddy.cs")
)
& "$fw\csc.exe" @cscArgs
if ($LASTEXITCODE -ne 0) { throw "Build failed." }
"Built: $out"
