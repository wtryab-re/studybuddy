// Study Buddy
// While the app is open (on screen or minimized to the taskbar), it watches the clipboard for new screenshots
// (PrintScreen, Win+Shift+S, Win+PrtScn, Snipping Tool). It looks for an open DeepSeek, Claude, ChatGPT or
// Gemini chat in your browsers; in the first one it finds, it switches to that tab, pastes the image with
// your prompt and sends it. Closing the window quits the app completely.
//
// Built by build.ps1 with the C# compiler that ships with Windows (.NET Framework 4.8, C# 5).
// Settings are stored in %APPDATA%\Study Buddy\settings.json.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Forms = System.Windows.Forms;
using Drawing = System.Drawing;

[assembly: AssemblyTitle("Study Buddy")]
[assembly: AssemblyProduct("Study Buddy")]
[assembly: AssemblyDescription("Sends your screenshots to an open AI chat with a prompt")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace StudyBuddy
{
    static class W32
    {
        [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
        [DllImport("shell32.dll")] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string id);

        delegate bool EnumProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
        [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
        [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);

        // All visible, titled top-level windows of the given processes, front-most first.
        // (A browser like Chrome runs all its windows in one process, so there can be several per process.)
        public static IntPtr[] WindowsOfProcesses(int[] pids)
        {
            var list = new List<IntPtr>();
            EnumWindows(delegate (IntPtr h, IntPtr l)
            {
                if (!IsWindowVisible(h) || GetWindowTextLength(h) == 0) return true;
                uint pid; GetWindowThreadProcessId(h, out pid);
                if (Array.IndexOf(pids, (int)pid) >= 0) list.Add(h);
                return true;
            }, IntPtr.Zero);
            return list.ToArray();
        }

        public static void Activate(IntPtr h)
        {
            if (IsIconic(h)) ShowWindow(h, 9); // SW_RESTORE
            // Tapping Alt lets a background process take the foreground.
            keybd_event(0x12, 0, 0, UIntPtr.Zero);
            keybd_event(0x12, 0, 2, UIntPtr.Zero);
            SetForegroundWindow(h);
        }

        // Left-click at a screen point, then put the mouse pointer back where it was.
        public static void ClickAt(int x, int y)
        {
            POINT old; GetCursorPos(out old);
            SetCursorPos(x, y);
            mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero); // left down
            mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero); // left up
            SetCursorPos(old.X, old.Y);
        }
    }

    class Service
    {
        public string Name; public Regex Title; public Regex Url;
        public Service(string name, string title, string url)
        {
            Name = name;
            Title = new Regex(title);                          // tab names: case-sensitive
            Url = new Regex(url, RegexOptions.IgnoreCase);     // addresses: case-insensitive
        }
    }

    class ChatTarget { public IntPtr Window; public AutomationElement Tab; public string Service; }

    class Settings
    {
        public string Prompt = "explain";
        public double UploadWaitSec = 1.5;
        public bool AutoSend = true;
        public bool Notifications = true;
        public string Theme = "Light";
    }

    static class Program
    {
        [STAThread]
        static void Main()
        {
            // Only one copy at a time; a second launch asks the running copy to show its window.
            bool createdNew;
            var mutex = new Mutex(true, @"Local\StudyBuddy", out createdNew);
            if (!createdNew)
            {
                try { EventWaitHandle.OpenExisting(@"Local\StudyBuddy.Show").Set(); }
                catch { Forms.MessageBox.Show("Study Buddy is already open.", "Study Buddy"); }
                return;
            }
            // Own taskbar identity
            W32.SetCurrentProcessExplicitAppUserModelID("StudyBuddy.App");
            new StudyBuddyApp().Run();
            GC.KeepAlive(mutex);
        }
    }

    class StudyBuddyApp
    {
        const string AppName = "Study Buddy";

        // How each chat site is recognised:
        //  - Title: the tab's name. The site name must be the whole title or its last " - " part, e.g.
        //    "Balancing equations - DeepSeek", "Claude", "ChatGPT". Chrome may append " - Part of group X",
        //    " - High memory usage - 1.0 GB" etc. "DeepSeek Platform" or "Claude - Google Search" don't match.
        //  - Url: the address bar of each browser window's tab being viewed. Needed for ChatGPT, whose
        //    conversation tabs are usually titled with just the conversation name.
        const string ChromeSuffix = @"(\s-\s(Part of group|High memory usage|Memory usage|Audio playing|Muted|Pinned|Loading|Network error).*)?$";
        static readonly Service[] Services =
        {
            new Service("DeepSeek", @"(^|\s-\s)DeepSeek( - Into the Unknown)?" + ChromeSuffix, @"^(https?://)?chat\.deepseek\.com"),
            new Service("Claude",   @"(^|\s-\s)Claude" + ChromeSuffix,                         @"^(https?://)?claude\.ai"),
            new Service("ChatGPT",  @"(^|\s-\s)ChatGPT" + ChromeSuffix,                        @"^(https?://)?(www\.)?(chatgpt\.com|chat\.openai\.com)"),
            // Gemini titles its tab "Gemini" or "Google Gemini", sometimes with an invisible left-to-right mark in front
            new Service("Gemini",   @"(^|\s-\s)[‎‏]?(Google )?Gemini" + ChromeSuffix,   @"^(https?://)?gemini\.google\.com"),
        };
        static readonly string[] Browsers = { "chrome", "msedge", "brave", "opera", "vivaldi", "firefox" };

        // Light and dark colors (keys match the brushes in window.xaml)
        static readonly Dictionary<string, string> LightColors = new Dictionary<string, string>
        {
            {"Bg","#FFFFFF"},{"Card","#F5F6F8"},{"Line","#E7E8EC"},{"Text","#1B1C20"},{"Muted","#6B6E76"},{"Faint","#9A9DA4"},
            {"Accent","#16A34A"},{"TrackOff","#D5D8DD"},{"KnobOff","#FFFFFF"},{"Hover","#EDEEF1"},{"Pressed","#E2E4E8"},
            {"InputBorder","#E3E5E9"},{"InputHover","#CDD0D6"},{"Outline","#E3E5E9"},{"DotOff","#B4B7BD"},
            {"SegBg","#E9EBEE"},{"SegSel","#FFFFFF"}
        };
        static readonly Dictionary<string, string> DarkColors = new Dictionary<string, string>
        {
            {"Bg","#121317"},{"Card","#1A1B20"},{"Line","#26282F"},{"Text","#ECECEE"},{"Muted","#8A8C94"},{"Faint","#5E6068"},
            {"Accent","#22A559"},{"TrackOff","#2C2E35"},{"KnobOff","#8A8C94"},{"Hover","#262830"},{"Pressed","#30323B"},
            {"InputBorder","#26282F"},{"InputHover","#34363F"},{"Outline","#22242A"},{"DotOff","#5A5D66"},
            {"SegBg","#24262C"},{"SegSel","#3A3D45"}
        };

        static readonly PropertyCondition TabCond = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.TabItem);
        static readonly PropertyCondition EditCond = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit);

        readonly Settings S = new Settings();
        string SettingsDir, SettingsPath;
        System.Windows.Application App;
        Window W;
        Forms.NotifyIcon Tray;
        DispatcherTimer Timer, TabTimer, ThemeTimer, TrayHideTimer;
        EventWaitHandle ShowEvent;
        uint LastSeq;
        bool Busy, Paused;
        string EffectiveTheme;

        // Controls from window.xaml
        FrameworkElement TitleBar; Image Logo; Border ShadowLayer;
        Button BtnMin, BtnClose, BtnWaitDown, BtnWaitUp;
        TextBlock StatusTitle, TabStatus, TxtWait;
        System.Windows.Shapes.Ellipse TabDot;
        CheckBox ChkActive, ChkAutoSend, ChkNotify;
        TextBox TxtPrompt;
        RadioButton RbLight, RbDark, RbSystem;
        StackPanel LogPanel;

        public void Run()
        {
            ShowEvent = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\StudyBuddy.Show");
            LoadSettings();

            App = new System.Windows.Application();
            App.ShutdownMode = ShutdownMode.OnExplicitShutdown;

            BuildWindow();
            BuildTray();
            InitValues();
            WireEvents();
            StartTimers();

            AddLog("App started");
            W.Show();
            W.Activate();
            UpdateTabStatus();
            App.Run();
        }

        // ---------------- Setup ----------------
        static Stream Res(string name) { return Assembly.GetExecutingAssembly().GetManifestResourceStream(name); }

        T Find<T>(string name) where T : class { return (T)W.FindName(name); }

        void BuildWindow()
        {
            using (var s = Res("window.xaml")) W = (Window)XamlReader.Load(s);
            TitleBar = Find<FrameworkElement>("TitleBar"); Logo = Find<Image>("Logo"); ShadowLayer = Find<Border>("ShadowLayer");
            BtnMin = Find<Button>("BtnMin"); BtnClose = Find<Button>("BtnClose");
            BtnWaitDown = Find<Button>("BtnWaitDown"); BtnWaitUp = Find<Button>("BtnWaitUp");
            StatusTitle = Find<TextBlock>("StatusTitle"); TabStatus = Find<TextBlock>("TabStatus"); TxtWait = Find<TextBlock>("TxtWait");
            TabDot = Find<System.Windows.Shapes.Ellipse>("TabDot");
            ChkActive = Find<CheckBox>("ChkActive"); ChkAutoSend = Find<CheckBox>("ChkAutoSend"); ChkNotify = Find<CheckBox>("ChkNotify");
            TxtPrompt = Find<TextBox>("TxtPrompt");
            RbLight = Find<RadioButton>("RbLight"); RbDark = Find<RadioButton>("RbDark"); RbSystem = Find<RadioButton>("RbSystem");
            LogPanel = Find<StackPanel>("LogPanel");

            BitmapFrame icon;
            using (var s = Res("icon.png")) icon = BitmapFrame.Create(s, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
            W.Icon = icon;
            Logo.Source = icon;
        }

        // The tray icon only appears briefly to show a notification; the app itself lives on the taskbar.
        void BuildTray()
        {
            Drawing.Icon trayIcon;
            using (var s = Res("icon.png"))
            using (var src = new Drawing.Bitmap(s))
            {
                var bmp = new Drawing.Bitmap(32, 32);
                using (var g = Drawing.Graphics.FromImage(bmp))
                {
                    g.InterpolationMode = Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                    g.DrawImage(src, 0, 0, 32, 32);
                }
                trayIcon = Drawing.Icon.FromHandle(bmp.GetHicon());
            }
            Tray = new Forms.NotifyIcon();
            Tray.Icon = trayIcon;
            Tray.Text = AppName;
            Tray.Visible = false;
            Tray.BalloonTipClicked += delegate { ShowWindow(); };
            Tray.Click += delegate { ShowWindow(); };

            TrayHideTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(8) };
            TrayHideTimer.Tick += delegate { TrayHideTimer.Stop(); Tray.Visible = false; };
        }

        void InitValues()
        {
            TxtPrompt.Text = S.Prompt;
            SetWait(S.UploadWaitSec);
            ChkAutoSend.IsChecked = S.AutoSend;
            ChkNotify.IsChecked = S.Notifications;
            if (S.Theme == "Dark") RbDark.IsChecked = true;
            else if (S.Theme == "System") RbSystem.IsChecked = true;
            else RbLight.IsChecked = true;
            SetTheme(S.Theme);
            SetPaused(false);
        }

        // Every change applies and saves immediately
        void WireEvents()
        {
            TitleBar.MouseLeftButtonDown += delegate { W.DragMove(); };
            BtnMin.Click += delegate { W.WindowState = WindowState.Minimized; };
            BtnClose.Click += delegate { W.Close(); };

            // Closing the window quits the whole app; nothing keeps running in the background.
            W.Closed += delegate
            {
                Timer.Stop(); TabTimer.Stop(); ThemeTimer.Stop(); TrayHideTimer.Stop();
                Tray.Visible = false; Tray.Dispose();
                App.Shutdown();
            };

            ChkActive.Click += delegate { SetPaused(ChkActive.IsChecked != true); };

            TxtPrompt.TextChanged += delegate
            {
                string p = TxtPrompt.Text.Trim();
                if (p.Length > 0) { S.Prompt = p; SaveSettings(); }
            };
            TxtPrompt.LostFocus += delegate { if (TxtPrompt.Text.Trim().Length == 0) TxtPrompt.Text = S.Prompt; };

            BtnWaitDown.Click += delegate { SetWait(S.UploadWaitSec - 0.5); SaveSettings(); };
            BtnWaitUp.Click += delegate { SetWait(S.UploadWaitSec + 0.5); SaveSettings(); };

            ChkAutoSend.Click += delegate { S.AutoSend = ChkAutoSend.IsChecked == true; SaveSettings(); };
            ChkNotify.Click += delegate { S.Notifications = ChkNotify.IsChecked == true; SaveSettings(); };

            RbLight.Checked += delegate { S.Theme = "Light"; SetTheme("Light"); SaveSettings(); };
            RbDark.Checked += delegate { S.Theme = "Dark"; SetTheme("Dark"); SaveSettings(); };
            RbSystem.Checked += delegate { S.Theme = "System"; SetTheme("System"); SaveSettings(); };
        }

        void StartTimers()
        {
            LastSeq = W32.GetClipboardSequenceNumber();

            Timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(400) };
            Timer.Tick += OnClipboardTick;
            Timer.Start();

            // Refresh the "chat tab" status while the window is on screen
            TabTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4) };
            TabTimer.Tick += delegate
            {
                if (W.IsVisible && W.WindowState != WindowState.Minimized && !Busy) UpdateTabStatus();
            };
            TabTimer.Start();

            // With "System", follow Windows when its app mode changes
            ThemeTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
            ThemeTimer.Tick += delegate
            {
                if (S.Theme == "System" && GetSystemTheme() != EffectiveTheme) SetTheme("System");
            };
            ThemeTimer.Start();
        }

        // ---------------- Settings ----------------
        void LoadSettings()
        {
            SettingsDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), AppName);
            SettingsPath = Path.Combine(SettingsDir, "settings.json");
            try
            {
                if (!File.Exists(SettingsPath)) return;
                var d = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(SettingsPath));
                if (d == null) return;
                object v;
                if (d.TryGetValue("Prompt", out v) && v is string && ((string)v).Trim().Length > 0) S.Prompt = (string)v;
                if (d.TryGetValue("UploadWaitSec", out v) && v != null) S.UploadWaitSec = Convert.ToDouble(v, CultureInfo.InvariantCulture);
                if (d.TryGetValue("AutoSend", out v) && v is bool) S.AutoSend = (bool)v;
                if (d.TryGetValue("Notifications", out v) && v is bool) S.Notifications = (bool)v;
                if (d.TryGetValue("Theme", out v) && (v as string == "Light" || v as string == "Dark" || v as string == "System")) S.Theme = (string)v;
            }
            catch { }
        }

        void SaveSettings()
        {
            try
            {
                Directory.CreateDirectory(SettingsDir);
                var d = new Dictionary<string, object>
                {
                    {"Prompt", S.Prompt}, {"UploadWaitSec", S.UploadWaitSec}, {"AutoSend", S.AutoSend},
                    {"Notifications", S.Notifications}, {"Theme", S.Theme}
                };
                File.WriteAllText(SettingsPath, new JavaScriptSerializer().Serialize(d));
            }
            catch (Exception ex) { AddLog("Couldn't save settings: " + ex.Message); }
        }

        // ---------------- UI helpers ----------------
        void AddLog(string msg)
        {
            if (LogPanel == null) return;
            var row = new DockPanel { Margin = new Thickness(0, 0, 0, 7) };
            var time = new TextBlock { Text = DateTime.Now.ToString("HH:mm"), FontSize = 12, Width = 46 };
            time.SetResourceReference(TextBlock.ForegroundProperty, "Faint");   // follows the theme
            DockPanel.SetDock(time, Dock.Left);
            var text = new TextBlock { Text = msg, ToolTip = msg, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis };
            text.SetResourceReference(TextBlock.ForegroundProperty, "Muted");
            row.Children.Add(time);
            row.Children.Add(text);
            LogPanel.Children.Insert(0, row);
            while (LogPanel.Children.Count > 40) LogPanel.Children.RemoveAt(LogPanel.Children.Count - 1);
        }

        void Notify(string msg)
        {
            AddLog(msg);
            if (!S.Notifications) return;
            Tray.Visible = true;
            Tray.ShowBalloonTip(3000, AppName, msg, Forms.ToolTipIcon.Info);
            TrayHideTimer.Stop(); TrayHideTimer.Start();
        }

        void SetPaused(bool p)
        {
            Paused = p;
            ChkActive.IsChecked = !p;
            StatusTitle.Text = p ? "Paused" : "Watching for screenshots";
            Logo.Opacity = p ? 0.4 : 1;
            W.Title = p ? AppName + " (paused)" : AppName;
        }

        void UpdateTabStatus()
        {
            var f = FindChatTab();
            if (f != null)
            {
                TabStatus.Text = f.Service + " tab found";
                TabDot.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, "Accent");
            }
            else
            {
                TabStatus.Text = "No AI chat tab open";
                TabDot.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, "DotOff");
            }
        }

        // 0.5 s steps, from 0.5 s to 30 s
        void SetWait(double sec)
        {
            sec = Math.Round(sec * 2.0) / 2.0;
            sec = Math.Min(30.0, Math.Max(0.5, sec));
            S.UploadWaitSec = sec;
            TxtWait.Text = sec.ToString("0.0", CultureInfo.InvariantCulture) + " s";
            BtnWaitDown.IsEnabled = sec > 0.5;
            BtnWaitUp.IsEnabled = sec < 30.0;
            BtnWaitDown.Opacity = BtnWaitDown.IsEnabled ? 1 : 0.3;
            BtnWaitUp.Opacity = BtnWaitUp.IsEnabled ? 1 : 0.3;
        }

        void ShowWindow()
        {
            W.Show();
            if (W.WindowState == WindowState.Minimized) W.WindowState = WindowState.Normal;
            W.Activate();
            UpdateTabStatus();
        }

        // ---------------- Theme ----------------
        // Windows' own app mode: Settings > Personalization > Colors > "Choose your default app mode"
        static string GetSystemTheme()
        {
            try
            {
                using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                {
                    if (k != null)
                    {
                        object v = k.GetValue("AppsUseLightTheme");
                        if (v is int && (int)v == 0) return "Dark";
                    }
                }
            }
            catch { }
            return "Light";
        }

        void SetTheme(string choice)
        {
            string eff = choice == "System" ? GetSystemTheme() : choice;
            EffectiveTheme = eff;
            var colors = eff == "Dark" ? DarkColors : LightColors;
            foreach (var kv in colors)
            {
                var b = new SolidColorBrush((Color)ColorConverter.ConvertFromString(kv.Value));
                b.Freeze();
                W.Resources[kv.Key] = b;
            }
            var shadow = ShadowLayer.Effect as DropShadowEffect;
            if (shadow != null) shadow.Opacity = eff == "Dark" ? 0.55 : 0.18;
        }

        // ---------------- Finding the chat ----------------
        // The browser's address bar (Chrome/Edge/Brave: "Address and search bar"; Firefox: "...enter address")
        static bool IsAddressBar(AutomationElement el)
        {
            try
            {
                var c = el.Current;
                return c.ClassName == "OmniboxViewViews" || Regex.IsMatch(c.Name ?? "", "address", RegexOptions.IgnoreCase);
            }
            catch { return false; }
        }

        // Every browser window (not just one per browser), front-most first
        static IntPtr[] GetBrowserWindows()
        {
            var ids = new List<int>();
            foreach (var name in Browsers)
                foreach (var p in Process.GetProcessesByName(name)) { ids.Add(p.Id); p.Dispose(); }
            return ids.Count == 0 ? new IntPtr[0] : W32.WindowsOfProcesses(ids.ToArray());
        }

        // The first DeepSeek / Claude / ChatGPT / Gemini chat found, or null.
        // Browser windows are checked front-most first; within a window, the tab being viewed, then tabs left to right.
        // Tab is null when no tab switch is needed (it's the tab being viewed, or a site installed as an app).
        static ChatTarget FindChatTab()
        {
            foreach (var h in GetBrowserWindows())
            {
                try
                {
                    var win = AutomationElement.FromHandle(h);
                    var addr = win.FindFirst(TreeScope.Descendants, EditCond);

                    if (addr != null && IsAddressBar(addr))
                    {
                        // 1) Tab being viewed, by its address
                        string url = "";
                        try
                        {
                            object vp;
                            if (addr.TryGetCurrentPattern(ValuePattern.Pattern, out vp)) url = ((ValuePattern)vp).Current.Value ?? "";
                        }
                        catch { }
                        foreach (var s in Services)
                            if (s.Url.IsMatch(url)) return new ChatTarget { Window = h, Service = s.Name };
                    }
                    else
                    {
                        // No address bar: a site installed as an app (or a popup). Identify it by the window title.
                        string title = win.Current.Name ?? "";
                        foreach (var s in Services)
                            if (s.Title.IsMatch(title)) return new ChatTarget { Window = h, Service = s.Name };
                        continue;
                    }

                    // 2) Any tab, by its name
                    var tabs = win.FindAll(TreeScope.Descendants, TabCond);
                    foreach (AutomationElement t in tabs)
                    {
                        string name = t.Current.Name ?? "";
                        foreach (var s in Services)
                            if (s.Title.IsMatch(name)) return new ChatTarget { Window = h, Tab = t, Service = s.Name };
                    }
                }
                catch { }
            }
            return null;
        }

        // Puts the keyboard cursor in the chat site's message box, so the paste and prompt land there
        // (and never in the address bar or wherever focus happened to be). Returns true on success.
        // The message box is the page's text field that looks like a prompt box ("Write your prompt to Claude",
        // "Ask Gemini", "Message DeepSeek"...), otherwise the lowest one on screen, since chat boxes sit at the bottom.
        static bool SetChatInputFocus(IntPtr hwnd)
        {
            var win = AutomationElement.FromHandle(hwnd);
            AutomationElement best = null;
            var start = DateTime.Now;
            bool pressedEsc = false;
            do
            {
                // In a narrow (half-screen) window, sites like Gemini switch to a phone-style layout where an open
                // side menu covers the chat and hides the message box. If nothing is found at first, press Esc once
                // to close such menus, then keep looking.
                if (!pressedEsc && (DateTime.Now - start).TotalMilliseconds > 700)
                {
                    Forms.SendKeys.SendWait("{ESC}");
                    pressedEsc = true;
                    Thread.Sleep(300);
                }
                var edits = win.FindAll(TreeScope.Descendants, EditCond);
                double bestScore = double.MinValue;
                foreach (AutomationElement e in edits)
                {
                    try
                    {
                        if (IsAddressBar(e)) continue;
                        var c = e.Current;
                        if (!c.IsKeyboardFocusable || c.IsOffscreen) continue;
                        var r = c.BoundingRectangle;
                        if (r.IsEmpty || r.Width < 100) continue;
                        double score = r.Bottom;
                        if (Regex.IsMatch(c.Name ?? "", "prompt|message|ask|chat|reply|enter", RegexOptions.IgnoreCase)) score += 100000;
                        if (score > bestScore) { best = e; bestScore = score; }
                    }
                    catch { }
                }
                if (best != null) break;
                Thread.Sleep(200);
            } while ((DateTime.Now - start).TotalMilliseconds < 2500);
            if (best == null) return false;

            try { best.SetFocus(); } catch { }
            Thread.Sleep(150);
            try { if (best.Current.HasKeyboardFocus) return true; } catch { }

            // Fallback: click into the box
            try
            {
                var r = best.Current.BoundingRectangle;
                W32.ClickAt((int)(r.Left + r.Width / 2), (int)(r.Top + r.Height / 2));
                Thread.Sleep(200);
                return best.Current.HasKeyboardFocus;
            }
            catch { return false; }
        }

        // ---------------- Clipboard watcher ----------------
        void OnClipboardTick(object sender, EventArgs e)
        {
            if (ShowEvent.WaitOne(0)) ShowWindow();   // another launch asked us to show the window
            if (Busy) return;
            uint seq = W32.GetClipboardSequenceNumber();
            if (seq == LastSeq) return;
            LastSeq = seq;
            if (Paused) return;

            Busy = true;
            try { HandleScreenshot(); }
            finally
            {
                LastSeq = W32.GetClipboardSequenceNumber();
                Busy = false;
            }
        }

        void HandleScreenshot()
        {
            Thread.Sleep(250);   // let the screenshot tool finish writing the clipboard
            bool hasImage = false;
            try { hasImage = Forms.Clipboard.ContainsImage(); } catch { }
            if (!hasImage) return;

            var found = FindChatTab();
            if (found == null)
            {
                Notify("Screenshot taken, but no DeepSeek, Claude, ChatGPT or Gemini tab is open.");
                return;
            }

            W32.Activate(found.Window);
            Thread.Sleep(300);
            if (W32.GetForegroundWindow() != found.Window)
            {
                Notify("Couldn't bring the browser window to the front. Skipped.");
                return;
            }

            // Switch to the chat tab (not needed if it was found as the tab being viewed)
            if (found.Tab != null)
            {
                try
                {
                    var sel = (SelectionItemPattern)found.Tab.GetCurrentPattern(SelectionItemPattern.Pattern);
                    if (!sel.Current.IsSelected) { sel.Select(); Thread.Sleep(700); }
                }
                catch
                {
                    Notify("Found the " + found.Service + " tab but couldn't switch to it. Skipped.");
                    return;
                }
            }

            // Put the cursor in the message box first; skip rather than type somewhere random
            if (!SetChatInputFocus(found.Window))
            {
                Notify("Couldn't find the message box in " + found.Service + ". Click into it once, then take the screenshot again.");
                return;
            }

            Forms.SendKeys.SendWait("^v");
            Thread.Sleep(300);
            // Escape SendKeys special characters so any prompt text is typed literally
            Forms.SendKeys.SendWait(Regex.Replace(S.Prompt, @"[+^%~(){}\[\]]", "{$0}"));
            if (S.AutoSend)
            {
                Thread.Sleep((int)(S.UploadWaitSec * 1000));
                Forms.SendKeys.SendWait("{ENTER}");
                AddLog(string.Format(CultureInfo.InvariantCulture, "Sent screenshot to {0} (waited {1:0.0} s)", found.Service, S.UploadWaitSec));
            }
            else
            {
                AddLog("Pasted screenshot into " + found.Service + " (not sent)");
            }
        }
    }
}
