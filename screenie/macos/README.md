# Screenie for macOS

A native Swift version of Screenie for Apple Silicon Macs on macOS 14 Sonoma or newer. Like the Linux version, it starts after a set time with no keyboard or mouse input, even while apps like Claude keep the Mac awake. Your apps keep running underneath; Screenie only covers the screen.

This is **phase 1** of the port described in [../MAC_PORT.md](../MAC_PORT.md): the menu bar app, idle watcher, global shortcut, settings, one window per display, and the Aurora, Starfield and Black styles. Farm, HUD and Agents come later.

## Download

**[Screenie.dmg](https://github.com/jonpederson/jonpederson.github.io/releases/download/screenie-macos-latest/Screenie.dmg)** (Apple Silicon, macOS 14+), always the newest build.

Open the disk image and drag Screenie into Applications (or just open it, and it offers to move itself there). The first time, macOS blocks it because it isn't notarized; see below.

## Build from source

Needs Xcode or the Command Line Tools (`xcode-select --install`).

```bash
./install.sh
```

This builds `build/Screenie.app`, copies it to `/Applications` (or `~/Applications`), and opens it. On first launch Screenie adds itself to Login Items and opens its settings. A ✨ icon in the menu bar shows it's running.

To build without installing, run `./build.sh`. CI (`.github/workflows/screenie-macos.yml`) also builds it on every push that touches this folder and publishes the disk image to the download link above.

## Use

- **Start it now:** press ⌃⌘S, or choose **Start Screensaver Now** from the menu bar icon
- **Dismiss it:** press any key, click, scroll, or move the mouse. Input in the first second is ignored, so releasing the shortcut keys doesn't dismiss it.
- **Settings:** choose **Settings…** from the menu bar icon, or open Screenie again from Finder or Spotlight
  - start when idle (on/off) and the idle time in minutes
  - the keyboard shortcut (click **Change**, press the new keys; Esc cancels, Delete turns it off)
  - style: Aurora, Starfield or Black
  - a clock that drifts so it won't burn in
  - require password to dismiss: shows the login window when you come back
  - open at login
- **From scripts:** `open screenie://show` starts it; `open screenie://settings` opens settings

Settings are saved to `~/Library/Application Support/Screenie/config.json`, with the same keys as the Linux `config.json`. A Linux shortcut such as `<Control><Super>s` is read as ⌃⌘S. Settings take effect right away.

## If macOS says "Screenie" Not Opened

Screenie isn't notarized by Apple (that needs a paid Apple Developer account), so the first time you open it macOS shows **"Screenie" Not Opened**. Click **Done**, then either:

- open **System Settings > Privacy & Security**, scroll to **Security**, click **Open Anyway** next to the Screenie message, and confirm with your password; or
- run `xattr -dr com.apple.quarantine /Applications/Screenie.app` in Terminal, then open it again.

You only need to do this once per download.

## Uninstall

```bash
./uninstall.sh
```

Add `--purge` to also delete your settings.

## How it works

| Concern | Implementation |
|---|---|
| Idle time | `CGEventSource.secondsSinceLastEventType(.hidSystemState, …)` for any input event, polled every 2 s; fires once per idle stretch, and not while the screen is locked (`System.swift`) |
| Background | `LSUIElement` menu bar app; launch at login through `SMAppService.mainApp` |
| Covering the screen | One borderless `NSWindow` per `NSScreen` at `.screenSaver` level, joining all Spaces, cursor hidden. Rebuilt when displays change (`Saver.swift`) |
| Dismiss | Local and global `NSEvent` monitors: key, modifier press, click, scroll, or more than 12 pt of mouse movement, after a 1 s grace period. Also dismisses if another app takes focus |
| Shortcut | Carbon `RegisterEventHotKey` (no Accessibility permission). Warns if another app holds the combination or macOS uses it (`Shortcut.swift`) |
| Require password | `SACLockScreenImmediate` from the login framework (what ⌃⌘Q uses), falling back to `pmset displaysleepnow` |
| Rendering | SwiftUI `Canvas` in a `TimelineView(.animation)`; Aurora's glows are pre-rendered once and scaled each frame (`Styles/`) |

## Testing checklist

- [ ] Starts after the idle time **while `caffeinate -d` is running**
- [ ] ⌃⌘S starts it immediately; releasing the keys doesn't dismiss it
- [ ] Covers every display, including the menu bar and Dock, with no Space-switch animation
- [ ] Key, click, scroll or mouse movement dismisses it; with "require password" on, the login window appears
- [ ] Launch at login works after a reboot
- [ ] Each style renders smoothly on a Retina display
