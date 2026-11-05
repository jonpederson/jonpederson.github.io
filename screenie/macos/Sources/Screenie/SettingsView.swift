import AppKit
import ServiceManagement
import SwiftUI

/// The settings window, matching the Linux libadwaita one (`settings.py`).
struct SettingsView: View {
    @ObservedObject var store: ConfigStore
    let preview: () -> Void

    @State private var loginEnabled = LoginItem.isEnabled
    @State private var loginNeedsApproval = LoginItem.status == .requiresApproval

    var body: some View {
        Form {
            Section {
                Toggle("Start when idle", isOn: $store.config.enabled)
                Stepper(value: $store.config.idleMinutes, in: 1...240) {
                    LabeledContent("Idle time") {
                        Text(store.config.idleMinutes == 1 ? "1 minute" : "\(store.config.idleMinutes) minutes")
                    }
                }
                .disabled(!store.config.enabled)
                LabeledContent {
                    ShortcutRecorder(store: store)
                } label: {
                    Text("Keyboard shortcut")
                    Text("Start the screensaver right away")
                }
                if let problem = store.shortcutProblem {
                    Text(problem).font(.callout).foregroundStyle(.orange)
                }
            } header: {
                Text("Activation")
            } footer: {
                Text("Screenie watches real keyboard and mouse activity, so it starts even while other apps keep the Mac awake.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Style", selection: styleBinding) {
                    ForEach(StyleID.allCases.filter(\.isAvailable)) { style in
                        Text(style.title).tag(style)
                    }
                }
                Toggle("Show clock", isOn: $store.config.showClock)
                Button("Preview", action: preview)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Farm, HUD and Agents are coming in a later version.")
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Toggle(isOn: $store.config.lockOnDismiss) {
                    Text("Require password to dismiss")
                    Text("Shows the login window when you return. Your apps keep running.")
                }
            }

            Section("General") {
                Toggle("Open at login", isOn: Binding(
                    get: { loginEnabled },
                    set: { on in
                        LoginItem.set(on)
                        refreshLoginState()
                    }))
                if loginNeedsApproval {
                    HStack {
                        Text("Allow Screenie in Login Items to finish turning this on.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshLoginState()
        }
    }

    private var styleBinding: Binding<StyleID> {
        Binding(get: { store.config.renderStyle },
                set: { store.config.style = $0.rawValue })
    }

    private func refreshLoginState() {
        loginEnabled = LoginItem.isEnabled
        loginNeedsApproval = LoginItem.status == .requiresApproval
    }
}

/// Click "Change", then press the new combination. Esc cancels; Delete turns the shortcut off.
struct ShortcutRecorder: View {
    @ObservedObject var store: ConfigStore
    @StateObject private var recorder = Recorder()

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(recorder.isRecording || shortcut == nil ? .secondary : .primary)
                .monospacedDigit()
            Button(recorder.isRecording ? "Cancel" : "Change") {
                if recorder.isRecording {
                    recorder.stop()
                    store.applyHotKey()
                } else {
                    recorder.start { result in
                        if let result {
                            store.config.shortcut = result
                        }
                        store.applyHotKey()  // re-register (it's paused while recording)
                    }
                }
            }
        }
    }

    private var shortcut: Shortcut? { Shortcut(string: store.config.shortcut) }

    private var label: String {
        if recorder.isRecording { return "Press keys…" }
        return shortcut?.display ?? "Disabled"
    }
}

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var isRecording = false
    private var monitor: Any?
    private var done: ((String?) -> Void)?

    /// `done` gets the new accelerator, "" to disable, or nil when cancelled.
    func start(_ done: @escaping (String?) -> Void) {
        stop()
        self.done = done
        isRecording = true
        HotKey.shared.unregister()  // so pressing the current shortcut can be recorded
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(Shortcut.relevantModifiers)
        let result: String?
        if mods.isEmpty && event.keyCode == 53 {           // Esc
            result = nil
        } else if mods.isEmpty && (event.keyCode == 51 || event.keyCode == 117) {  // Delete
            result = ""
        } else if let s = Shortcut(event: event) {
            result = s.string
        } else {
            NSSound.beep()  // still waiting for a real combination
            return
        }
        let done = self.done
        self.done = nil
        stop()
        done?(result)
    }
}
