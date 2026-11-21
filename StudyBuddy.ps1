# Study Buddy
# While the app is open (on screen or minimized to the taskbar), it watches the clipboard for new screenshots
# (PrintScreen, Win+Shift+S, Win+PrtScn, Snipping Tool). It looks for an open DeepSeek, Claude, ChatGPT or
# Gemini chat tab in your browsers (active or not); in the first one it finds, it switches to that tab,
# pastes the image with your prompt and sends it.
# Closing the window quits the app completely.
#
# Custom icon: put icon.png (or icon.ico) in this folder and restart the app.

$AppName = "Study Buddy"

# ---------------- Fixed settings ----------------
# How each chat site is recognised:
#  - Title: the tab's name (case-sensitive). The site name must be the whole title or its last " - " part, e.g.
#    "Balancing equations - DeepSeek", "Claude", "ChatGPT". Chrome may append " - Part of group X",
#    " - High memory usage - 1.0 GB" etc., which is allowed. "DeepSeek Platform" or "Claude - Google Search" don't match.
#  - Url: the address bar of each browser window's *active* tab. Needed for ChatGPT, whose conversation
#    tabs are usually titled with just the conversation name.
$ChromeSuffix = '(\s-\s(Part of group|High memory usage|Memory usage|Audio playing|Muted|Pinned|Loading|Network error).*)?$'
$Services = @(
    @{ Name = "DeepSeek"; Title = "(^|\s-\s)DeepSeek( - Into the Unknown)?$ChromeSuffix"; Url = '^(https?://)?chat\.deepseek\.com' },
    @{ Name = "Claude";   Title = "(^|\s-\s)Claude$ChromeSuffix";                          Url = '^(https?://)?claude\.ai' },
    @{ Name = "ChatGPT";  Title = "(^|\s-\s)ChatGPT$ChromeSuffix";                         Url = '^(https?://)?(www\.)?(chatgpt\.com|chat\.openai\.com)' },
    # Gemini titles its tab "Gemini" or "Google Gemini", sometimes with an invisible left-to-right mark in front
    @{ Name = "Gemini";   Title = "(^|\s-\s)[\u200E\u200F]?(Google )?Gemini$ChromeSuffix";    Url = '^(https?://)?gemini\.google\.com' }
)
$Browsers     = @("chrome", "msedge", "brave", "opera", "vivaldi", "firefox")
$PollMs       = 400
$SettingsPath = Join-Path $PSScriptRoot "settings.json"
$AppIcoPath   = Join-Path $PSScriptRoot "app.ico"          # generated; used by the shortcuts
$LauncherLink = Join-Path $PSScriptRoot "$AppName.lnk"

# Light and dark colors (keys match the brushes in the window's resources)
$Themes = @{
    Light = @{ Bg = "#FFFFFF"; Card = "#F5F6F8"; Line = "#E7E8EC"; Text = "#1B1C20"; Muted = "#6B6E76"; Faint = "#9A9DA4"
               Accent = "#16A34A"; TrackOff = "#D5D8DD"; KnobOff = "#FFFFFF"; Hover = "#EDEEF1"; Pressed = "#E2E4E8"
               InputBorder = "#E3E5E9"; InputHover = "#CDD0D6"; Outline = "#E3E5E9"; DotOff = "#B4B7BD"
               SegBg = "#E9EBEE"; SegSel = "#FFFFFF"; Shadow = 0.18 }
    Dark  = @{ Bg = "#121317"; Card = "#1A1B20"; Line = "#26282F"; Text = "#ECECEE"; Muted = "#8A8C94"; Faint = "#5E6068"
               Accent = "#22A559"; TrackOff = "#2C2E35"; KnobOff = "#8A8C94"; Hover = "#262830"; Pressed = "#30323B"
               InputBorder = "#26282F"; InputHover = "#34363F"; Outline = "#22242A"; DotOff = "#5A5D66"
               SegBg = "#24262C"; SegSel = "#3A3D45"; Shadow = 0.55 }
}
# ------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ---------------- Single instance ----------------
# A second launch just asks the running copy to show its window, then quits.
$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, "Local\StudyBuddy", [ref]$createdNew)
if (-not $createdNew) {
    try {
        $ev = [System.Threading.EventWaitHandle]::OpenExisting("Local\StudyBuddy.Show")
        [void]$ev.Set()
    } catch {
        [System.Windows.Forms.MessageBox]::Show("$AppName is already open.", $AppName) | Out-Null
    }
    exit
}
$script:ShowEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, "Local\StudyBuddy.Show")

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class W32 {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    // All visible, titled top-level windows of the given processes, front-most first.
    // (A browser like Chrome runs all its windows in one process, so there can be several per process.)
    public static IntPtr[] WindowsOfProcesses(int[] pids) {
        var list = new List<IntPtr>();
        EnumWindows(delegate (IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h) || GetWindowTextLength(h) == 0) return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (Array.IndexOf(pids, (int)pid) >= 0) list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }

    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("shell32.dll")] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string id);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);

    // Left-click at a screen point, then put the mouse pointer back where it was.
    public static void ClickAt(int x, int y) {
        POINT old; GetCursorPos(out old);
        SetCursorPos(x, y);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero); // left down
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero); // left up
        SetCursorPos(old.X, old.Y);
    }

    public static void Activate(IntPtr h) {
        if (IsIconic(h)) ShowWindow(h, 9); // SW_RESTORE
        // Tapping Alt lets a background process take the foreground.
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x12, 0, 2, UIntPtr.Zero);
        SetForegroundWindow(h);
    }
}
"@

# Own taskbar identity, so the taskbar shows our name/icon instead of grouping us with PowerShell
[void][W32]::SetCurrentProcessExplicitAppUserModelID("StudyBuddy.App")

# ---------------- Settings (saved to settings.json on every change) ----------------
$script:Settings = @{ Prompt = "explain"; UploadWaitSec = 1.5; AutoSend = $true; Notifications = $true; Theme = "Light" }
if (Test-Path $SettingsPath) {
    try {
        $saved = Get-Content $SettingsPath -Raw | ConvertFrom-Json
        foreach ($k in @($script:Settings.Keys)) {
            if ($null -ne $saved.$k) { $script:Settings[$k] = $saved.$k }
        }
    } catch { }
}
$script:Settings.UploadWaitSec = [double]$script:Settings.UploadWaitSec
if ($script:Settings.Theme -notin @("Light", "Dark", "System")) { $script:Settings.Theme = "Light" }

function Save-Settings {
    try { $script:Settings | ConvertTo-Json | Set-Content -Path $SettingsPath -Encoding UTF8 }
    catch { Add-Log "Couldn't save settings: $($_.Exception.Message)" }
}

function New-AppShortcut([string]$path) {
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($path)
    $lnk.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $lnk.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.WindowStyle = 7
    $lnk.Description = $AppName
    if (Test-Path $AppIcoPath) { $lnk.IconLocation = "$AppIcoPath,0" }
    $lnk.Save()
}

# ---------------- Chat tab search ----------------
$UIA = [System.Windows.Automation.AutomationElement]
$TabCondition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::TabItem)
$EditCondition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Edit)

# The browser's address bar (Chrome/Edge/Brave: "Address and search bar"; Firefox: "...enter address")
function Test-AddressBar($el) {
    try { $c = $el.Current; return ($c.ClassName -eq "OmniboxViewViews" -or $c.Name -match 'address') } catch { return $false }
}

# Every browser window (not just one per browser), front-most first
function Get-BrowserWindows {
    $ids = @(Get-Process -Name $Browsers -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    if ($ids.Count -eq 0) { return @() }
    return [W32]::WindowsOfProcesses([int[]]$ids)
}

# Returns @{ Window = <hwnd>; Tab = <AutomationElement or $null>; Service = <name> } for the first
# DeepSeek / Claude / ChatGPT / Gemini chat found, or $null.
# Browser windows are checked front-most first; within a window, the tab being viewed, then tabs left to right.
# Tab is $null when no tab switch is needed (it's the tab being viewed, or a site installed as an app).
function Find-ChatTab {
    foreach ($h in Get-BrowserWindows) {
        try {
            $win  = $UIA::FromHandle($h)
            $addr = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $EditCondition)

            if ($addr -and (Test-AddressBar $addr)) {
                # 1) Tab being viewed, by its address
                $url = ""
                try { $url = $addr.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { }
                foreach ($s in $Services) {
                    if ($url -match $s.Url) { return @{ Window = $h; Tab = $null; Service = $s.Name } }
                }
            } else {
                # No address bar: a site installed as an app (or a popup). Identify it by the window title.
                $title = $win.Current.Name
                foreach ($s in $Services) {
                    if ($title -cmatch $s.Title) { return @{ Window = $h; Tab = $null; Service = $s.Name } }
                }
                continue
            }

            # 2) Any tab, by its name
            $tabs = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $TabCondition)
            foreach ($t in $tabs) {
                $name = $t.Current.Name
                foreach ($s in $Services) {
                    if ($name -cmatch $s.Title) { return @{ Window = $h; Tab = $t; Service = $s.Name } }
                }
            }
        } catch { }
    }
    return $null
}

# Puts the keyboard cursor in the chat site's message box, so the paste and prompt land there
# (and never in the address bar or wherever focus happened to be). Returns $true on success.
# The message box is the page's text field that looks like a prompt box ("Write your prompt to Claude",
# "Ask Gemini", "Message DeepSeek"...), otherwise the lowest one on screen, since chat boxes sit at the bottom.
function Set-ChatInputFocus([IntPtr]$hwnd) {
    $win = $UIA::FromHandle($hwnd)
    $best = $null
    $start = Get-Date
    $deadline = $start.AddMilliseconds(2500)   # the page may still be appearing right after a tab switch
    $pressedEsc = $false
    do {
        # In a narrow (half-screen) window, sites like Gemini switch to a phone-style layout where an open
        # side menu covers the chat and hides the message box. If nothing is found at first, press Esc once
        # to close such menus, then keep looking.
        if (-not $pressedEsc -and ((Get-Date) - $start).TotalMilliseconds -gt 700) {
            [System.Windows.Forms.SendKeys]::SendWait("{ESC}")
            $pressedEsc = $true
            Start-Sleep -Milliseconds 300
        }
        $edits = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $EditCondition)
        $bestScore = [double]::MinValue
        for ($i = 0; $i -lt $edits.Count; $i++) {
            try {
                if (Test-AddressBar $edits[$i]) { continue }
                $c = $edits[$i].Current
                if (-not $c.IsKeyboardFocusable -or $c.IsOffscreen) { continue }
                $r = $c.BoundingRectangle
                if ($r.IsEmpty -or $r.Width -lt 100) { continue }
                $score = $r.Bottom
                if ($c.Name -match 'prompt|message|ask|chat|reply|enter') { $score += 100000 }
                if ($score -gt $bestScore) { $best = $edits[$i]; $bestScore = $score }
            } catch { }
        }
        if ($best) { break }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    if (-not $best) { return $false }

    try { $best.SetFocus() } catch { }
    Start-Sleep -Milliseconds 150
    try { if ($best.Current.HasKeyboardFocus) { return $true } } catch { }

    # Fallback: click into the box
    try {
        $r = $best.Current.BoundingRectangle
        [W32]::ClickAt([int]($r.Left + $r.Width / 2), [int]($r.Top + $r.Height / 2))
        Start-Sleep -Milliseconds 200
        return [bool]$best.Current.HasKeyboardFocus
    } catch { return $false }
}

# ---------------- App icon ----------------
# Uses icon.png / icon.ico from this folder if present, otherwise draws the default (magnifier on blue).
function New-DefaultIconBitmap {
    $s = 256
    $bmp = New-Object System.Drawing.Bitmap $s, $s
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    # Rounded square with a soft blue gradient
    $r = 60; $rect = New-Object System.Drawing.Rectangle 8, 8, ($s - 16), ($s - 16)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($rect.X, $rect.Y, $r, $r, 180, 90)
    $path.AddArc($rect.Right - $r, $rect.Y, $r, $r, 270, 90)
    $path.AddArc($rect.Right - $r, $rect.Bottom - $r, $r, $r, 0, 90)
    $path.AddArc($rect.X, $rect.Bottom - $r, $r, $r, 90, 90)
    $path.CloseFigure()
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect,
        [System.Drawing.Color]::FromArgb(52, 199, 89), [System.Drawing.Color]::FromArgb(22, 150, 64), 45.0)
    $g.FillPath($grad, $path)
    # Magnifying glass
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 22)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round; $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawEllipse($pen, 62, 58, 104, 104)
    $pen.Width = 26
    $g.DrawLine($pen, 154, 150, 194, 190)
    $g.Dispose()
    return $bmp
}

function Get-IconBitmap {
    foreach ($name in "icon.png", "icon.ico") {
        $f = Join-Path $PSScriptRoot $name
        if (-not (Test-Path $f)) { continue }
        try {
            if ($name -like "*.ico") { return (New-Object System.Drawing.Icon($f, 256, 256)).ToBitmap() }
            $ms = New-Object System.IO.MemoryStream(, [System.IO.File]::ReadAllBytes($f))   # don't lock the file
            return New-Object System.Drawing.Bitmap([System.Drawing.Image]::FromStream($ms))
        } catch { }
    }
    return New-DefaultIconBitmap
}

# Scales an image into a transparent square, keeping its proportions
function Resize-Bitmap($bmp, [int]$size) {
    $out = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($out)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $scale = [math]::Min([double]$size / $bmp.Width, [double]$size / $bmp.Height)
    $w = [int]($bmp.Width * $scale); $h = [int]($bmp.Height * $scale)
    $g.DrawImage($bmp, [int](($size - $w) / 2), [int](($size - $h) / 2), $w, $h)
    $g.Dispose()
    return $out
}

function Get-PngBytes($bmp) {
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    return , $ms.ToArray()   # leading comma: return the byte[] as-is, not unrolled into an object[]
}

# Writes a single-image (PNG-compressed, 256px) .ico for the shortcuts
function Save-Ico($bmp, [string]$path) {
    $png = Get-PngBytes (Resize-Bitmap $bmp 256)
    $fs = [System.IO.File]::Create($path)
    $w = New-Object System.IO.BinaryWriter($fs)
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]1)          # header: reserved, type=icon, count
    $w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]0) # 256x256, no palette
    $w.Write([uint16]1); $w.Write([uint16]32)                               # planes, bits per pixel
    $w.Write([uint32]$png.Length); $w.Write([uint32]22)                     # data size, data offset
    $w.Write($png)
    $w.Close()
}

$IconBitmap = Get-IconBitmap
try { Save-Ico $IconBitmap $AppIcoPath } catch { }
$IconImageSource = [System.Windows.Media.Imaging.BitmapFrame]::Create(
    (New-Object System.IO.MemoryStream(, (Get-PngBytes (Resize-Bitmap $IconBitmap 256)))))
$TrayIcon = [System.Drawing.Icon]::FromHandle((Resize-Bitmap $IconBitmap 32).GetHicon())

# Keep the folder launcher pointing at this script with the current icon
try { New-AppShortcut $LauncherLink } catch { }

# ---------------- Window (WPF) ----------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Study Buddy" Width="404" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="CanMinimize" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <!-- Theme colors. These are the light values; Set-Theme swaps them for the dark ones at runtime.
         Everything below uses DynamicResource so it updates when they change. -->
    <SolidColorBrush x:Key="Bg"          Color="#FFFFFF"/>
    <SolidColorBrush x:Key="Card"        Color="#F5F6F8"/>
    <SolidColorBrush x:Key="Line"        Color="#E7E8EC"/>
    <SolidColorBrush x:Key="Text"        Color="#1B1C20"/>
    <SolidColorBrush x:Key="Muted"       Color="#6B6E76"/>
    <SolidColorBrush x:Key="Faint"       Color="#9A9DA4"/>
    <SolidColorBrush x:Key="Accent"      Color="#16A34A"/>
    <SolidColorBrush x:Key="TrackOff"    Color="#D5D8DD"/>
    <SolidColorBrush x:Key="KnobOff"     Color="#FFFFFF"/>
    <SolidColorBrush x:Key="Hover"       Color="#EDEEF1"/>
    <SolidColorBrush x:Key="Pressed"     Color="#E2E4E8"/>
    <SolidColorBrush x:Key="InputBorder" Color="#E3E5E9"/>
    <SolidColorBrush x:Key="InputHover"  Color="#CDD0D6"/>
    <SolidColorBrush x:Key="Outline"     Color="#E3E5E9"/>
    <SolidColorBrush x:Key="DotOff"      Color="#B4B7BD"/>
    <SolidColorBrush x:Key="SegBg"       Color="#E9EBEE"/>
    <SolidColorBrush x:Key="SegSel"      Color="#FFFFFF"/>

    <!-- Toggle switch -->
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="Track" Width="38" Height="22" CornerRadius="11" Background="{DynamicResource TrackOff}">
              <Ellipse x:Name="Knob" Width="16" Height="16" Fill="{DynamicResource KnobOff}"
                       HorizontalAlignment="Left" Margin="3,0,0,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="{DynamicResource Accent}"/>
                <Setter TargetName="Knob" Property="Fill" Value="White"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Knob" Property="Margin" Value="0,0,3,0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Borderless button that lights up on hover -->
    <Style x:Key="Ghost" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" CornerRadius="7"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="{DynamicResource Hover}"/>
                <Setter Property="Foreground" Value="{DynamicResource Text}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="B" Property="Background" Value="{DynamicResource Pressed}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Close button: turns red on hover -->
    <Style x:Key="CloseBtn" TargetType="Button" BasedOn="{StaticResource Ghost}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="Transparent" CornerRadius="7">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="#C42B1C"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Segmented choice (Light / Dark / System) -->
    <Style x:Key="Seg" TargetType="RadioButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="B" Background="Transparent" CornerRadius="6" Padding="10,4">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="{DynamicResource Text}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="B" Property="Background" Value="{DynamicResource SegSel}"/>
                <Setter Property="Foreground" Value="{DynamicResource Text}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Text input -->
    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="CaretBrush" Value="{DynamicResource Text}"/>
      <Setter Property="SelectionBrush" Value="{DynamicResource Accent}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="B" Background="{DynamicResource Card}" BorderBrush="{DynamicResource InputBorder}" BorderThickness="1"
                    CornerRadius="10" Padding="12,9">
              <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="BorderBrush" Value="{DynamicResource InputHover}"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="B" Property="BorderBrush" Value="{DynamicResource Accent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Section" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="4,20,0,8"/>
    </Style>
    <Style x:Key="RowTitle" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>
    <Style x:Key="RowHint" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Margin" Value="0,2,0,0"/>
    </Style>
  </Window.Resources>

  <Grid Margin="12">
    <!-- Shadow sits on its own layer so it doesn't blur the content -->
    <Border x:Name="ShadowLayer" CornerRadius="14" Background="{DynamicResource Bg}">
      <Border.Effect>
        <DropShadowEffect BlurRadius="22" ShadowDepth="0" Opacity="0.18" Color="Black"/>
      </Border.Effect>
    </Border>

    <Border CornerRadius="14" Background="{DynamicResource Bg}" BorderBrush="{DynamicResource Outline}" BorderThickness="1"
            TextElement.Foreground="{DynamicResource Text}">
      <StackPanel>

        <!-- Title bar (drag to move) -->
        <Grid x:Name="TitleBar" Height="46" Background="Transparent" Margin="18,0,10,0">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Image x:Name="Logo" Width="18" Height="18" Margin="0,0,10,0"
                   RenderOptions.BitmapScalingMode="HighQuality"/>
            <TextBlock Text="Study Buddy" FontWeight="SemiBold" FontSize="13" VerticalAlignment="Center"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
            <Button x:Name="BtnMin" Style="{StaticResource Ghost}" Width="30" Height="30" ToolTip="Minimize (keeps working)">
              <Rectangle Width="10" Height="1.2" Fill="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
            </Button>
            <Button x:Name="BtnClose" Style="{StaticResource CloseBtn}" Width="30" Height="30" ToolTip="Close (stops the app)">
              <Path Data="M0,0 L9,9 M9,0 L0,9" StrokeThickness="1.3"
                    Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"/>
            </Button>
          </StackPanel>
        </Grid>

        <StackPanel Margin="18,2,18,16">

          <!-- Status -->
          <Border Background="{DynamicResource Card}" CornerRadius="12" Padding="16,14">
            <Grid>
              <StackPanel VerticalAlignment="Center">
                <TextBlock x:Name="StatusTitle" Text="Watching for screenshots" FontSize="15" FontWeight="SemiBold"/>
                <StackPanel Orientation="Horizontal" Margin="0,5,0,0">
                  <Ellipse x:Name="TabDot" Width="7" Height="7" Fill="{DynamicResource DotOff}" VerticalAlignment="Center" Margin="0,1,7,0"/>
                  <TextBlock x:Name="TabStatus" Text="Looking for a chat tab..." Foreground="{DynamicResource Muted}" FontSize="12"/>
                </StackPanel>
              </StackPanel>
              <CheckBox x:Name="ChkActive" Style="{StaticResource Switch}" HorizontalAlignment="Right"
                        VerticalAlignment="Center" IsChecked="True" ToolTip="Pause / resume"/>
            </Grid>
          </Border>

          <!-- Prompt -->
          <TextBlock Text="PROMPT" Style="{StaticResource Section}"/>
          <TextBox x:Name="TxtPrompt" Style="{StaticResource Input}"/>

          <!-- Settings -->
          <TextBlock Text="SETTINGS" Style="{StaticResource Section}"/>
          <Border Background="{DynamicResource Card}" CornerRadius="12" Padding="16,4">
            <StackPanel>
              <Grid Margin="0,10">
                <StackPanel>
                  <TextBlock Text="Wait before sending" Style="{StaticResource RowTitle}"/>
                  <TextBlock Text="Gives the image time to upload" Style="{StaticResource RowHint}"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                  <Button x:Name="BtnWaitDown" Style="{StaticResource Ghost}" Width="28" Height="28" FontSize="16" Content="&#x2212;"/>
                  <TextBlock x:Name="TxtWait" Text="1.5 s" Width="46" TextAlignment="Center" VerticalAlignment="Center"/>
                  <Button x:Name="BtnWaitUp" Style="{StaticResource Ghost}" Width="28" Height="28" FontSize="16" Content="+"/>
                </StackPanel>
              </Grid>
              <Border Height="1" Background="{DynamicResource Line}"/>
              <Grid Margin="0,10">
                <StackPanel>
                  <TextBlock Text="Send automatically" Style="{StaticResource RowTitle}"/>
                  <TextBlock Text="Press Enter after pasting" Style="{StaticResource RowHint}"/>
                </StackPanel>
                <CheckBox x:Name="ChkAutoSend" Style="{StaticResource Switch}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
              </Grid>
              <Border Height="1" Background="{DynamicResource Line}"/>
              <Grid Margin="0,12">
                <TextBlock Text="Notifications" Style="{StaticResource RowTitle}" VerticalAlignment="Center"/>
                <CheckBox x:Name="ChkNotify" Style="{StaticResource Switch}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
              </Grid>
              <Border Height="1" Background="{DynamicResource Line}"/>
              <Grid Margin="0,10">
                <TextBlock Text="Appearance" Style="{StaticResource RowTitle}" VerticalAlignment="Center"/>
                <Border Background="{DynamicResource SegBg}" CornerRadius="8" Padding="3" HorizontalAlignment="Right">
                  <StackPanel Orientation="Horizontal">
                    <RadioButton x:Name="RbLight"  GroupName="Theme" Style="{StaticResource Seg}" Content="Light"/>
                    <RadioButton x:Name="RbDark"   GroupName="Theme" Style="{StaticResource Seg}" Content="Dark"/>
                    <RadioButton x:Name="RbSystem" GroupName="Theme" Style="{StaticResource Seg}" Content="System"/>
                  </StackPanel>
                </Border>
              </Grid>
            </StackPanel>
          </Border>

          <!-- Activity -->
          <TextBlock Text="ACTIVITY" Style="{StaticResource Section}"/>
          <ScrollViewer Height="92" VerticalScrollBarVisibility="Hidden" Margin="4,0,0,0">
            <StackPanel x:Name="LogPanel"/>
          </ScrollViewer>

          <!-- Footer -->
          <TextBlock Text="Changes save automatically  &#x00B7;  Closing the window stops the app" Foreground="{DynamicResource Faint}"
                     FontSize="11.5" Margin="4,10,0,0"/>
        </StackPanel>
      </StackPanel>
    </Border>
  </Grid>
</Window>
'@

$window = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
foreach ($n in "TitleBar","Logo","BtnMin","BtnClose","StatusTitle","TabDot","TabStatus","ChkActive","TxtPrompt",
               "BtnWaitDown","TxtWait","BtnWaitUp","ChkAutoSend","ChkNotify","RbLight","RbDark","RbSystem",
               "LogPanel","ShadowLayer") {
    Set-Variable -Name $n -Value $window.FindName($n) -Scope Script
}
$window.Icon = $IconImageSource
$Logo.Source = $IconImageSource

# ---------------- Theme ----------------
# Windows' own app mode: Settings > Personalization > Colors > "Choose your default app mode"
function Get-SystemTheme {
    try {
        $v = Get-ItemPropertyValue "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" "AppsUseLightTheme" -ErrorAction Stop
        if ($v -eq 0) { return "Dark" }
    } catch { }
    return "Light"
}

function Set-Theme([string]$choice) {
    $effective = if ($choice -eq "System") { Get-SystemTheme } else { $choice }
    $script:EffectiveTheme = $effective
    $colors = $Themes[$effective]
    foreach ($k in $colors.Keys) {
        if ($k -eq "Shadow") { continue }
        # ::new + BaseObject: WPF rejects the PowerShell wrapper object that New-Object would hand it
        $brush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($colors[$k]))
        $brush.Freeze()
        $window.Resources[$k] = $brush.psobject.BaseObject
    }
    $ShadowLayer.Effect.Opacity = $colors.Shadow
}

# ---------------- Notifications ----------------
# The tray icon only appears briefly to show a notification; the app itself lives on the taskbar.
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $TrayIcon
$tray.Text = $AppName
$tray.Visible = $false
$tray.add_BalloonTipClicked({ Show-Window })
$tray.add_Click({ Show-Window })

$trayHideTimer = New-Object System.Windows.Threading.DispatcherTimer
$trayHideTimer.Interval = [TimeSpan]::FromSeconds(8)
$trayHideTimer.add_Tick({ $trayHideTimer.Stop(); $tray.Visible = $false })

# ---------------- Helpers ----------------
function Add-Log($msg) {
    $row = New-Object System.Windows.Controls.DockPanel
    $row.Margin = "0,0,0,7"
    $time = New-Object System.Windows.Controls.TextBlock
    $time.Text = Get-Date -Format "HH:mm"
    $time.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, "Faint")   # follows the theme
    $time.FontSize = 12; $time.Width = 46
    [System.Windows.Controls.DockPanel]::SetDock($time, "Left")
    $text = New-Object System.Windows.Controls.TextBlock
    $text.Text = $msg; $text.ToolTip = $msg
    $text.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, "Muted")
    $text.FontSize = 12; $text.TextTrimming = "CharacterEllipsis"
    [void]$row.Children.Add($time); [void]$row.Children.Add($text)
    $LogPanel.Children.Insert(0, $row)
    while ($LogPanel.Children.Count -gt 40) { $LogPanel.Children.RemoveAt($LogPanel.Children.Count - 1) }
}

function Notify($msg) {
    Add-Log $msg
    if ($script:Settings.Notifications) {
        $tray.Visible = $true
        $tray.ShowBalloonTip(3000, $AppName, $msg, "Info")
        $trayHideTimer.Stop(); $trayHideTimer.Start()
    }
}

function Set-Paused([bool]$p) {
    $script:Paused = $p
    $ChkActive.IsChecked = -not $p
    if ($p) {
        $StatusTitle.Text = "Paused"
        $Logo.Opacity = 0.4
        $window.Title = "$AppName (paused)"
    } else {
        $StatusTitle.Text = "Watching for screenshots"
        $Logo.Opacity = 1
        $window.Title = $AppName
    }
}

function Update-TabStatus {
    $f = Find-ChatTab
    if ($f) {
        $TabStatus.Text = "$($f.Service) tab found"
        $TabDot.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, "Accent")
    } else {
        $TabStatus.Text = "No AI chat tab open"
        $TabDot.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, "DotOff")
    }
}

function Set-Wait([double]$sec) {
    # 0.5 s steps, from 0.5 s to 30 s
    # (30.0, not 30: an integer literal makes PowerShell pick Math.Min(int,int) and round the value)
    [double]$sec = [math]::Round($sec * 2.0) / 2.0
    [double]$sec = [math]::Min([double]30.0, [math]::Max([double]0.5, $sec))
    $script:Settings.UploadWaitSec = $sec
    $TxtWait.Text = ("{0:0.0} s" -f $sec)
    $BtnWaitDown.IsEnabled = $sec -gt 0.5
    $BtnWaitUp.IsEnabled   = $sec -lt 30.0
    $BtnWaitDown.Opacity = if ($BtnWaitDown.IsEnabled) { 1 } else { 0.3 }
    $BtnWaitUp.Opacity   = if ($BtnWaitUp.IsEnabled)   { 1 } else { 0.3 }
}

function Show-Window {
    $window.Show()
    if ($window.WindowState -eq "Minimized") { $window.WindowState = "Normal" }
    [void]$window.Activate()
    Update-TabStatus
}

# ---------------- Initial values ----------------
$script:Paused = $false
$TxtPrompt.Text = $script:Settings.Prompt
Set-Wait $script:Settings.UploadWaitSec
$ChkAutoSend.IsChecked = [bool]$script:Settings.AutoSend
$ChkNotify.IsChecked   = [bool]$script:Settings.Notifications
switch ($script:Settings.Theme) { "Dark" { $RbDark.IsChecked = $true } "System" { $RbSystem.IsChecked = $true } default { $RbLight.IsChecked = $true } }
Set-Theme $script:Settings.Theme
Set-Paused $false

# ---------------- Events (every change applies and saves immediately) ----------------
$TitleBar.add_MouseLeftButtonDown({ $window.DragMove() })
$BtnMin.add_Click({ $window.WindowState = "Minimized" })
$BtnClose.add_Click({ $window.Close() })

# Closing the window quits the whole app; nothing keeps running in the background.
$window.add_Closed({
    $timer.Stop(); $tabTimer.Stop(); $trayHideTimer.Stop(); $themeTimer.Stop()
    $tray.Visible = $false; $tray.Dispose()
    $app.Shutdown()
})

$ChkActive.add_Click({ Set-Paused (-not $ChkActive.IsChecked) })

$TxtPrompt.add_TextChanged({
    $p = $TxtPrompt.Text.Trim()
    if ($p) { $script:Settings.Prompt = $p; Save-Settings }
})
$TxtPrompt.add_LostFocus({ if (-not $TxtPrompt.Text.Trim()) { $TxtPrompt.Text = $script:Settings.Prompt } })

$BtnWaitDown.add_Click({ Set-Wait ($script:Settings.UploadWaitSec - 0.5); Save-Settings })
$BtnWaitUp.add_Click({   Set-Wait ($script:Settings.UploadWaitSec + 0.5); Save-Settings })

$ChkAutoSend.add_Click({ $script:Settings.AutoSend = [bool]$ChkAutoSend.IsChecked; Save-Settings })
$ChkNotify.add_Click({   $script:Settings.Notifications = [bool]$ChkNotify.IsChecked; Save-Settings })
$RbLight.add_Checked({  $script:Settings.Theme = "Light";  Set-Theme "Light";  Save-Settings })
$RbDark.add_Checked({   $script:Settings.Theme = "Dark";   Set-Theme "Dark";   Save-Settings })
$RbSystem.add_Checked({ $script:Settings.Theme = "System"; Set-Theme "System"; Save-Settings })

# With "System", follow Windows when its app mode changes (checked every 2 s)
$themeTimer = New-Object System.Windows.Threading.DispatcherTimer
$themeTimer.Interval = [TimeSpan]::FromSeconds(2)
$themeTimer.add_Tick({
    if ($script:Settings.Theme -eq "System" -and (Get-SystemTheme) -ne $script:EffectiveTheme) { Set-Theme "System" }
})
$themeTimer.Start()

# ---------------- Clipboard watcher ----------------
$script:LastSeq = [W32]::GetClipboardSequenceNumber()
$script:Busy = $false

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds($PollMs)
$timer.add_Tick({
    if ($script:ShowEvent.WaitOne(0)) { Show-Window }   # another launch asked us to show the window
    if ($script:Busy) { return }
    $seq = [W32]::GetClipboardSequenceNumber()
    if ($seq -eq $script:LastSeq) { return }
    $script:LastSeq = $seq
    if ($script:Paused) { return }

    $script:Busy = $true
    try {
        Start-Sleep -Milliseconds 250   # let the screenshot tool finish writing the clipboard
        $hasImage = $false
        try { $hasImage = [System.Windows.Forms.Clipboard]::ContainsImage() } catch { }
        if (-not $hasImage) { return }

        $found = Find-ChatTab
        if (-not $found) {
            Notify "Screenshot taken, but no DeepSeek, Claude, ChatGPT or Gemini tab is open."
            return
        }

        [W32]::Activate($found.Window)
        Start-Sleep -Milliseconds 300
        if ([W32]::GetForegroundWindow() -ne $found.Window) {
            Notify "Couldn't bring the browser window to the front. Skipped."
            return
        }

        # Switch to the chat tab (not needed if it was found as the active tab)
        if ($found.Tab) {
            try {
                $sel = $found.Tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
                if (-not $sel.Current.IsSelected) { $sel.Select(); Start-Sleep -Milliseconds 700 }
            } catch {
                Notify "Found the $($found.Service) tab but couldn't switch to it. Skipped."
                return
            }
        }

        # Put the cursor in the message box first; skip rather than type somewhere random
        if (-not (Set-ChatInputFocus $found.Window)) {
            Notify "Couldn't find the message box in $($found.Service). Click into it once, then take the screenshot again."
            return
        }

        [System.Windows.Forms.SendKeys]::SendWait("^v")
        Start-Sleep -Milliseconds 300
        # Escape SendKeys special characters so any prompt text is typed literally
        $escaped = [regex]::Replace($script:Settings.Prompt, '[+^%~(){}\[\]]', '{$0}')
        [System.Windows.Forms.SendKeys]::SendWait($escaped)
        if ($script:Settings.AutoSend) {
            Start-Sleep -Milliseconds ([int]($script:Settings.UploadWaitSec * 1000))
            [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
            Add-Log ("Sent screenshot to {0} (waited {1:0.0} s)" -f $found.Service, $script:Settings.UploadWaitSec)
        } else {
            Add-Log "Pasted screenshot into $($found.Service) (not sent)"
        }
    }
    finally {
        $script:LastSeq = [W32]::GetClipboardSequenceNumber()
        $script:Busy = $false
    }
})
$timer.Start()

# Refresh the "DeepSeek tab" status while the window is on screen
$tabTimer = New-Object System.Windows.Threading.DispatcherTimer
$tabTimer.Interval = [TimeSpan]::FromSeconds(4)
$tabTimer.add_Tick({ if ($window.IsVisible -and $window.WindowState -ne "Minimized" -and -not $script:Busy) { Update-TabStatus } })
$tabTimer.Start()

Add-Log "App started"
$app = New-Object System.Windows.Application
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$window.Show()
[void]$window.Activate()
Update-TabStatus
[void]$app.Run()
