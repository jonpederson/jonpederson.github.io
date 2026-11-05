import AppKit
import SwiftUI

@main
enum ScreenieMain {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--unregister-login-item") {  // used by uninstall.sh
            LoginItem.set(false)
            return
        }
        if let i = args.firstIndex(of: "--snapshot") {  // offscreen screenshot, used by CI
            exit(Snapshot.run(Array(args[(i + 1)...])))
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // menu bar only (LSUIElement)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = ConfigStore.shared
    private let saver = SaverController()
    private var watcher: IdleWatcher?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private let startItem = NSMenuItem(title: "Start Screensaver Now", action: #selector(startNow), keyEquivalent: "")
    private let idleItem = NSMenuItem(title: "Start When Idle", action: #selector(toggleIdle), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if offerToMoveToApplications() { return }  // relaunching from Applications
        buildMainMenu()
        buildStatusItem()

        HotKey.shared.onPress = { [weak self] in self?.startSaver() }
        store.applyHotKey()

        saver.onDismissed = { [weak self] in self?.saverDismissed() }

        let watcher = IdleWatcher(store: store,
                                  isShowing: { [weak self] in self?.saver.isShowing ?? false },
                                  fire: { [weak self] in self?.startSaver() })
        watcher.start()
        self.watcher = watcher

        // First run: start at every login (as the Linux installer's autostart entry does)
        // and show the settings so it's clear the app is running.
        // (Only from an Applications folder, so the login item doesn't point into a disk image.)
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "didFirstLaunch") && Self.isInApplicationsFolder {
            defaults.set(true, forKey: "didFirstLaunch")
            LoginItem.set(true)
            openSettings()
        }
    }

    /// Opening the app again (Finder, Spotlight, `open -a Screenie`) shows the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    /// `open screenie://show` starts the screensaver; `screenie://settings` opens settings.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "screenie" {
            switch url.host ?? url.path {
            case "show", "start": startSaver()
            case "settings": openSettings()
            default: break
            }
        }
    }

    // MARK: Install

    private static var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// When opened from a disk image or Downloads, offers to copy itself into
    /// Applications and relaunch from there. Returns true if it's relaunching.
    private func offerToMoveToApplications() -> Bool {
        guard !Self.isInApplicationsFolder else { return false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Screenie to your Applications folder?"
        alert.informativeText = "Screenie needs to be in Applications to start automatically when you log in."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let fm = FileManager.default
        let source = Bundle.main.bundleURL
        let candidates = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                          URL(fileURLWithPath: NSHomeDirectory() + "/Applications", isDirectory: true)]
        for dir in candidates {
            let dest = dir.appendingPathComponent("Screenie.app")
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) {
                    for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                    where app != NSRunningApplication.current {
                        app.terminate()
                    }
                    try fm.trashItem(at: dest, resultingItemURL: nil)
                }
                try fm.copyItem(at: source, to: dest)
                let open = Process()
                open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                open.arguments = ["-n", dest.path]
                try open.run()
                NSApp.terminate(nil)
                return true
            } catch {
                continue  // e.g. /Applications not writable; try ~/Applications
            }
        }
        let failed = NSAlert()
        failed.messageText = "Couldn't move Screenie"
        failed.informativeText = "Drag Screenie into your Applications folder in Finder, then open it from there."
        failed.runModal()
        return false
    }

    // MARK: Screensaver

    func startSaver() {
        store.reloadIfChanged()
        saver.show(config: store.config)
    }

    private func saverDismissed() {
        // Hand focus back to whatever was in front, unless the settings window is open.
        if settingsWindow?.isVisible != true {
            NSApp.hide(nil)
        }
    }

    // MARK: Menus

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Screenie")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Screenie"
        }
        let menu = NSMenu()
        menu.delegate = self
        startItem.target = self
        idleItem.target = self
        menu.addItem(startItem)
        menu.addItem(idleItem)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Screenie", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        idleItem.state = store.config.enabled ? .on : .off
        let minutes = store.config.idleMinutes
        idleItem.title = "Start When Idle (\(minutes) min)"
        if let s = Shortcut(string: store.config.shortcut), let ch = s.key?.character {
            startItem.keyEquivalent = ch
            startItem.keyEquivalentModifierMask = s.modifiers
        } else {
            startItem.keyEquivalent = ""
        }
    }

    /// Accessory apps have no visible menu bar, but this makes ⌘W and ⌘Q work in settings.
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Screenie", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileItem.submenu = fileMenu
        main.addItem(fileItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func startNow() {
        startSaver()
    }

    @objc private func toggleIdle() {
        store.config.enabled.toggle()
    }

    @objc private func showSettings() {
        openSettings()
    }

    // MARK: Settings

    func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(store: store, preview: { [weak self] in self?.startSaver() })
            let controller = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: controller)
            window.title = "Screenie"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("ScreenieSettings")
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
