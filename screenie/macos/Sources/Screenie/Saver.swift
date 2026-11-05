import AppKit
import os
import SwiftUI

let saverLog = Logger(subsystem: "local.screenie.Screenie", category: "saver")

/// A borderless window covering one display, above the menu bar and Dock.
/// Native fullscreen is avoided on purpose: it animates into a new Space.
final class SaverWindow: NSWindow {
    init(screen: NSScreen, config: Config) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        title = "Screenie"
        contentView = NSHostingView(rootView: SceneView(model: SceneModel(config: config)))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Shows the screensaver on every display and dismisses it on input (`saver.py`).
@MainActor
final class SaverController: NSObject {
    static let graceSeconds = 1.0   // ignore input right after showing (e.g. releasing the shortcut keys)
    static let motionThreshold = 12.0  // points of mouse movement before dismissing

    /// Called after the screensaver has gone away.
    var onDismissed: (() -> Void)?

    /// One window per display, keyed by display ID.
    private var windows: [CGDirectDisplayID: SaverWindow] = [:]
    private var monitors: [Any] = []
    private var config = Config()
    private var shownAt: TimeInterval = 0
    private var motionOrigin: NSPoint?
    private var lastFlags: NSEvent.ModifierFlags = []
    private var dismissing = false
    private var cursorHidden = false

    var isShowing: Bool { !windows.isEmpty }

    func show(config: Config) {
        guard !isShowing else { return }  // a second trigger is ignored
        self.config = config
        shownAt = ProcessInfo.processInfo.systemUptime
        dismissing = false
        motionOrigin = nil
        lastFlags = NSEvent.modifierFlags

        saverLog.notice("show: style \(config.style, privacy: .public), \(NSScreen.screens.count) display(s)")
        NSApp.activate(ignoringOtherApps: true)
        syncWindows()
        installMonitors()
        NSCursor.hide()
        cursorHidden = true

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Makes the windows match the displays: adds and removes windows only for displays
    /// that appeared or went away, and moves or resizes the rest in place, so the
    /// animation never restarts. (macOS posts screen-parameter changes for many things
    /// that aren't display changes, such as menu bar and Dock visibility.)
    private func syncWindows() {
        var seen: Set<CGDirectDisplayID> = []
        for screen in NSScreen.screens {
            guard let id = Self.displayID(screen) else { continue }
            seen.insert(id)
            if let w = windows[id] {
                if w.frame != screen.frame {
                    saverLog.notice("display \(id) moved or resized to \(screen.frame.debugDescription, privacy: .public)")
                    w.setFrame(screen.frame, display: true)
                }
            } else {
                let w = SaverWindow(screen: screen, config: config)
                windows[id] = w
                w.orderFrontRegardless()
            }
        }
        for (id, w) in windows where !seen.contains(id) {
            saverLog.notice("display \(id) went away")
            w.orderOut(nil)
            w.close()
            windows[id] = nil
        }
        // Keyboard focus goes to the display with the mouse on it.
        if !windows.values.contains(where: \.isKeyWindow) {
            let mouse = NSEvent.mouseLocation
            let key = windows.values.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.values.first
            key?.makeKeyAndOrderFront(nil)
        }
    }

    private func closeWindows() {
        for w in windows.values {
            w.orderOut(nil)
            w.close()
        }
        windows.removeAll()
    }

    @objc private func screensChanged() {
        guard isShowing, !dismissing else { return }
        saverLog.notice("screen parameters changed")
        syncWindows()
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [
            .keyDown, .flagsChanged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return nil  // swallow it
        }) {
            monitors.append(local)
        }
        // Events while another app still has focus (if activation was refused). Mouse
        // events always arrive here; key events only with Accessibility permission.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
        }) {
            monitors.append(global)
        }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private var inGrace: Bool {
        ProcessInfo.processInfo.systemUptime - shownAt < Self.graceSeconds
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let p = NSEvent.mouseLocation
            guard !inGrace, let origin = motionOrigin else {
                motionOrigin = p
                return
            }
            if hypot(p.x - origin.x, p.y - origin.y) > Self.motionThreshold { dismiss(reason: "mouse moved") }
        case .flagsChanged:
            // Pressing a modifier dismisses; releasing one (the shortcut's keys) doesn't.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let pressed = !flags.subtracting(lastFlags).intersection(Shortcut.relevantModifiers).isEmpty
            lastFlags = flags
            if pressed { dismiss(reason: "modifier key") }
        default:
            dismiss(reason: "\(event.type.rawValue)")
        }
    }

    func dismiss(reason: String = "requested") {
        guard isShowing, !inGrace, !dismissing else { return }
        saverLog.notice("dismiss: \(reason, privacy: .public)")
        dismissing = true
        if config.lockOnDismiss {
            ScreenLock.lockNow()
            // Give the login window a moment to cover everything before we vanish.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000)
                self?.teardown()
            }
        } else {
            teardown()
        }
    }

    private func teardown() {
        NotificationCenter.default.removeObserver(self)
        removeMonitors()
        closeWindows()
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
        dismissing = false
        onDismissed?()
    }
}
