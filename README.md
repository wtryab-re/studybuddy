# Study Buddy

Study Buddy is a small Windows app that sends your screenshots to an AI chat for you. Take a screenshot of a question, a diagram or a page of notes, and Study Buddy pastes it into your open DeepSeek, Claude, ChatGPT or Gemini chat together with your prompt (for example "explain this like I'm a student") and sends it.

No browser extension, no account and no setup: it's a single `.exe`.

## Features

- **Works with three AI chats:** DeepSeek, Claude, and Gemini, in Chrome, Edge, Brave, Opera, Vivaldi or Firefox.
- **Finds the chat for you:** the chat can be in any browser window, in a background tab, in a window snapped to half the screen, or installed as an app. Study Buddy switches to it, pastes the screenshot and types your prompt.
- **Works with any screenshot tool:** Print Screen, Win + Shift + S, Win + Print Screen or Snipping Tool. Anything that copies an image works.
- **Your own prompt:** type whatever you want sent with each screenshot. It's remembered between sessions.
- **Upload wait:** a short pause before sending, so the image finishes uploading first. Adjustable from 0.5 to 30 seconds in half-second steps.
- **Send automatically or not:** have it press Enter for you, or just paste and let you add more before sending.
- **Pause switch:** turn it off temporarily without closing the app.
- **Activity log:** shows what happened with each screenshot, including why one was skipped.
- **Light, dark or system theme.**
- **Runs only while open:** closing the window stops it completely. Minimizing it to the taskbar keeps it working.

## Download

**[Download Study Buddy.exe](https://github.com/wtryab-re/studybuddy/raw/main/dist/Study%20Buddy.exe)**

Or on GitHub: open the [`dist`](https://github.com/wtryab-re/studybuddy/tree/main/dist) folder, click `Study Buddy.exe`, then click the download button ("Download raw file") at the top right of the file view.

That one file is all you need. Put it anywhere you like, such as your Desktop or Documents, and double-click it to start.

**Requirements:** Windows 10 or 11. Nothing else to install; the .NET Framework 4.8 it uses is already part of Windows.

### "Windows protected your PC"

I promise there is no virus in the app!
Windows shows this warning for any program downloaded from the internet whose publisher it doesn't recognise. Study Buddy isn't signed with a paid certificate, so you'll see it the first time. To run it, do one of these:

- In the warning, click **More info**, then **Run anyway**.
- Or before opening it, right-click `Study Buddy.exe`, choose **Properties**, tick **Unblock** at the bottom and click **OK**.

You only need to do this once.

If your antivirus flags it, that's because the app watches the clipboard and types into another window, which some antivirus programs treat as suspicious. You can allow it in Windows Security under **Protection history**.

## How to use it

1. Open a chat in your browser: [DeepSeek](https://chat.deepseek.com), [Claude](https://claude.ai), or [Gemini](https://gemini.google.com).
2. Open Study Buddy. The status line should say which chat it found, for example "Claude tab found".
3. Type your prompt in the **Prompt** box, for example `explain this step by step`.
4. Take a screenshot (Win + Shift + S is the easiest). Study Buddy switches to the chat, pastes the image, types your prompt and sends it.

Keep Study Buddy open or minimized while you study. Close it when you're done.

### Settings

| Setting             | What it does                                                                                                     |
| ------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Top switch          | Pauses or resumes watching for screenshots                                                                       |
| Prompt              | The text sent with every screenshot                                                                              |
| Wait before sending | How long to wait for the image to upload before pressing Enter. Raise it if messages get sent without the image. |
| Send automatically  | On: presses Enter for you. Off: only pastes, so you can add more text first.                                     |
| Notifications       | Shows a Windows notification when a screenshot is skipped                                                        |
| Appearance          | Light, Dark, or System (follows your Windows setting)                                                            |

Settings save as soon as you change them. They're stored in `%APPDATA%\Study Buddy\settings.json` and only on your PC.

### If you have several chats open

Study Buddy uses the first chat it finds. It checks your browser windows from the one you used most recently, and within a window it checks the tab you're viewing first, then the other tabs from left to right.

## Troubleshooting

**"Screenshot taken, but no ... tab is open"**
Study Buddy couldn't find a chat. Make sure one of the three chat sites is open in a supported browser.

**A ChatGPT chat in a background tab isn't found**
ChatGPT names its tabs after the conversation (for example "Photosynthesis questions") without "ChatGPT" in the title, so a background ChatGPT tab can't be recognised. Switch to that tab once so it's the one you're viewing in its window, or start a new chat (a new chat tab is titled "ChatGPT"). DeepSeek, Claude and Gemini chats are found in any tab.

**"Couldn't find the message box"**
Something is covering the chat box, such as a menu or a pop-up. Close it, click into the message box once, and take the screenshot again. In a narrow window, Gemini's side menu can cover the chat; Study Buddy tries closing it with Esc, but you may need to close it yourself.

**The message is sent before the image appears**
Increase **Wait before sending**.

**It reacted when I copied an image**
Study Buddy reacts to any image copied to the clipboard, not only screenshots, so "Copy image" in a browser triggers it too. Use the top switch to pause it while you do that.

**Chrome's split view**
If you use Chrome's split view (two tabs side by side inside one window) with a chat in each half, Study Buddy may paste into the wrong half. Two separate windows snapped side by side work fine.

## Privacy

Study Buddy doesn't send anything anywhere itself and has no account or internet connection of its own. It only reads screenshots you copy, pastes them into the chat tab in your own browser, and saves its settings locally.

## For developers

### Getting the code

```
git clone https://github.com/wtryab-re/studybuddy.git
cd studybuddy
```

To get the latest changes later:

```
git pull
```

### Building the .exe

The app is a C# / WPF program compiled with the C# compiler that ships with Windows, so no Visual Studio or SDK is needed:

```
powershell -ExecutionPolicy Bypass -File build.ps1
```

This creates `dist\Study Buddy.exe`. The app icon comes from `icon.png`; rebuild after replacing it.

### Project layout

| Path                   | Contents                                                             |
| ---------------------- | -------------------------------------------------------------------- |
| `src/StudyBuddy.cs`    | The app: clipboard watching, finding the chat tab, pasting, settings |
| `src/window.xaml`      | The window design and theme colours                                  |
| `icon.png`             | App icon used by the build                                           |
| `build.ps1`            | Build script                                                         |
| `dist/Study Buddy.exe` | The built app                                                        |
| `build/`               | Temporary files created by the build                                 |
| `StudyBuddy.ps1`       | The original PowerShell version (no longer used)                     |
