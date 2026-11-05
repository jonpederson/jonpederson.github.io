import AppKit
import SwiftUI

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

    private var windows: [SaverWindow] = []
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

        NSApp.activate(ignoringOtherApps: true)
        makeWindows()
        installMonitors()
        NSCursor.hide()
        cursorHidden = true

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(screensChanged),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(self, selector: #selector(resignedActive),
                       name: NSApplication.didResignActiveNotification, object: nil)
    }

    private func makeWindows() {
        let screens = NSScreen.screens
        for screen in screens {
            let w = SaverWindow(screen: screen, config: config)
            windows.append(w)
            w.orderFrontRegardless()
        }
        // Keyboard focus goes to the display with the mouse on it.
        let mouse = NSEvent.mouseLocation
        let keyWindow = windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first
        keyWindow?.makeKeyAndOrderFront(nil)
    }

    private func closeWindows() {
        for w in windows {
            w.orderOut(nil)
            w.close()
        }
        windows.removeAll()
    }

    @objc private func screensChanged() {
        guard isShowing, !dismissing else { return }
        closeWindows()
        makeWindows()
    }

    @objc private func resignedActive() {
        // Something took focus (e.g. ⌘-Tab); don't leave an invisible wall over it.
        dismiss()
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
            if hypot(p.x - origin.x, p.y - origin.y) > Self.motionThreshold { dismiss() }
        case .flagsChanged:
            // Pressing a modifier dismisses; releasing one (the shortcut's keys) doesn't.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let pressed = !flags.subtracting(lastFlags).intersection(Shortcut.relevantModifiers).isEmpty
            lastFlags = flags
            if pressed { dismiss() }
        default:
            dismiss()
        }
    }

    func dismiss() {
        guard isShowing, !inGrace, !dismissing else { return }
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
