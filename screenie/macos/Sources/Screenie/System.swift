import AppKit
import CoreGraphics
import ServiceManagement

/// Starts the screensaver after N minutes without real keyboard or mouse input.
///
/// The HID idle time is what the user actually did, so it keeps counting while apps
/// hold `PreventUserIdleDisplaySleep` assertions (the ones that stop the system screen
/// saver). Port of `daemon.py`: poll every 2 s and fire once per idle stretch.
@MainActor
final class IdleWatcher: NSObject {
    static let pollSeconds: TimeInterval = 2

    private let store: ConfigStore
    private let isShowing: () -> Bool
    private let fire: () -> Void
    private var timer: Timer?
    private var fired = false  // already triggered during the current idle stretch

    init(store: ConfigStore, isShowing: @escaping () -> Bool, fire: @escaping () -> Void) {
        self.store = store
        self.isShowing = isShowing
        self.fire = fire
    }

    func start() {
        let t = Timer(timeInterval: Self.pollSeconds, target: self, selector: #selector(tick),
                      userInfo: nil, repeats: true)
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func tick() {
        store.reloadIfChanged()
        let cfg = store.config
        let idle = Self.idleSeconds()
        let threshold = Double(max(1, cfg.idleMinutes) * 60)
        if idle < threshold {
            fired = false
        } else if cfg.enabled && !fired && !isShowing() && !Self.screenLocked() {
            fired = true
            fire()
        }
    }

    /// Seconds since the last keyboard, mouse, trackpad or scroll event.
    static func idleSeconds() -> Double {
        // kCGAnyInputEventType (~0) covers every input event type.
        if let any = CGEventType(rawValue: ~0) {
            return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
        }
        let types: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown,
                                    .rightMouseDown, .otherMouseDown, .scrollWheel,
                                    .leftMouseDragged]
        return types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? 0
    }

    /// True while the login window is up or another user is on the console.
    static func screenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool, locked { return true }
        if let onConsole = session["kCGSSessionOnConsoleKey"] as? Bool, !onConsole { return true }
        return false
    }
}

/// "Require password to dismiss": show the login window, leaving apps running.
enum ScreenLock {
    static func lockNow() {
        // The same call the Lock Screen menu item (⌃⌘Q) makes. It's in a private
        // framework, so look it up at run time and fall back if it ever disappears.
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        if let handle = dlopen(path, RTLD_LAZY), let sym = dlsym(handle, "SACLockScreenImmediate") {
            typealias LockFn = @convention(c) () -> Int32
            _ = unsafeBitCast(sym, to: LockFn.self)()
            return
        }
        // Locks only if "Require password after screen saver begins or display is
        // turned off" is set to Immediately.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }
}

/// Launch at login, through the system's login items (System Settings > General > Login Items).
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Screenie: couldn't change the login item: \(error.localizedDescription)")
        }
    }
}
