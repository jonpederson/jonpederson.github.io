import AppKit
import Carbon.HIToolbox

/// A key combination, stored in config.json in the same accelerator syntax the Linux
/// version uses (e.g. "<Control><Command>s"). "<Super>" is read as Command, so a config
/// copied from Linux ("<Control><Super>s") gives the matching Mac shortcut.
struct Shortcut: Equatable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags

    static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Shortcut.relevantModifiers)
    }

    init?(string: String) {
        var rest = Substring(string.trimmingCharacters(in: .whitespaces))
        var mods: NSEvent.ModifierFlags = []
        while rest.hasPrefix("<"), let close = rest.firstIndex(of: ">") {
            let tag = rest[rest.index(after: rest.startIndex)..<close].lowercased()
            switch tag {
            case "control", "ctrl", "primary": mods.insert(.control)
            case "alt", "option": mods.insert(.option)
            case "shift": mods.insert(.shift)
            case "command", "cmd", "super", "meta": mods.insert(.command)
            default: return nil
            }
            rest = rest[rest.index(after: close)...]
        }
        guard !rest.isEmpty, let key = Key.named(String(rest)) else { return nil }
        self.init(keyCode: key.code, modifiers: mods)
    }

    /// A combination typed in the recorder, if it's usable as a global shortcut.
    init?(event: NSEvent) {
        let mods = event.modifierFlags.intersection(Shortcut.relevantModifiers)
        // Shift alone isn't a safe global modifier; a bare key isn't either.
        guard !mods.intersection([.control, .option, .command]).isEmpty,
              Key.byCode[event.keyCode] != nil else { return nil }
        self.init(keyCode: event.keyCode, modifiers: mods)
    }

    var key: Key? { Key.byCode[keyCode] }

    var string: String {
        var s = ""
        if modifiers.contains(.control) { s += "<Control>" }
        if modifiers.contains(.option) { s += "<Alt>" }
        if modifiers.contains(.shift) { s += "<Shift>" }
        if modifiers.contains(.command) { s += "<Command>" }
        return s + (key?.name ?? "")
    }

    /// Mac-style label, e.g. "⌃⌘S".
    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + (key?.label ?? "?")
    }

    var carbonModifiers: UInt32 {
        var m = 0
        if modifiers.contains(.control) { m |= controlKey }
        if modifiers.contains(.option) { m |= optionKey }
        if modifiers.contains(.shift) { m |= shiftKey }
        if modifiers.contains(.command) { m |= cmdKey }
        return UInt32(m)
    }

    /// A key, named the way GTK accelerators name it.
    struct Key {
        let code: UInt16
        let name: String
        let label: String
        /// Character for an NSMenuItem key equivalent, when there is a simple one.
        let character: String?

        static func named(_ name: String) -> Key? {
            byName[name.lowercased()]
        }

        static let all: [Key] = {
            var keys: [Key] = []
            func add(_ code: Int, _ name: String, _ label: String, _ ch: String? = nil) {
                keys.append(Key(code: UInt16(code), name: name, label: label, character: ch))
            }
            let letters: [(Int, String)] = [
                (kVK_ANSI_A, "a"), (kVK_ANSI_B, "b"), (kVK_ANSI_C, "c"), (kVK_ANSI_D, "d"),
                (kVK_ANSI_E, "e"), (kVK_ANSI_F, "f"), (kVK_ANSI_G, "g"), (kVK_ANSI_H, "h"),
                (kVK_ANSI_I, "i"), (kVK_ANSI_J, "j"), (kVK_ANSI_K, "k"), (kVK_ANSI_L, "l"),
                (kVK_ANSI_M, "m"), (kVK_ANSI_N, "n"), (kVK_ANSI_O, "o"), (kVK_ANSI_P, "p"),
                (kVK_ANSI_Q, "q"), (kVK_ANSI_R, "r"), (kVK_ANSI_S, "s"), (kVK_ANSI_T, "t"),
                (kVK_ANSI_U, "u"), (kVK_ANSI_V, "v"), (kVK_ANSI_W, "w"), (kVK_ANSI_X, "x"),
                (kVK_ANSI_Y, "y"), (kVK_ANSI_Z, "z"),
                (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
                (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"),
                (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
            ]
            for (code, ch) in letters { add(code, ch, ch.uppercased(), ch) }
            let punctuation: [(Int, String, String)] = [
                (kVK_ANSI_Minus, "minus", "-"), (kVK_ANSI_Equal, "equal", "="),
                (kVK_ANSI_LeftBracket, "bracketleft", "["), (kVK_ANSI_RightBracket, "bracketright", "]"),
                (kVK_ANSI_Semicolon, "semicolon", ";"), (kVK_ANSI_Quote, "apostrophe", "'"),
                (kVK_ANSI_Comma, "comma", ","), (kVK_ANSI_Period, "period", "."),
                (kVK_ANSI_Slash, "slash", "/"), (kVK_ANSI_Backslash, "backslash", "\\"),
                (kVK_ANSI_Grave, "grave", "`"),
            ]
            for (code, name, ch) in punctuation { add(code, name, ch, ch) }
            let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                                kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
                                kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
            for (i, code) in functionKeys.enumerated() { add(code, "F\(i + 1)", "F\(i + 1)") }
            add(kVK_Space, "space", "Space", " ")
            add(kVK_Return, "Return", "↩")
            add(kVK_Tab, "Tab", "⇥")
            add(kVK_Delete, "BackSpace", "⌫")
            add(kVK_ForwardDelete, "Delete", "⌦")
            add(kVK_Home, "Home", "↖")
            add(kVK_End, "End", "↘")
            add(kVK_PageUp, "Page_Up", "⇞")
            add(kVK_PageDown, "Page_Down", "⇟")
            add(kVK_LeftArrow, "Left", "←")
            add(kVK_RightArrow, "Right", "→")
            add(kVK_UpArrow, "Up", "↑")
            add(kVK_DownArrow, "Down", "↓")
            return keys
        }()

        static let byCode: [UInt16: Key] = Dictionary(all.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
        static let byName: [String: Key] = Dictionary(all.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
    }
}

/// The global shortcut, through Carbon's RegisterEventHotKey (no Accessibility
/// permission needed, unlike a global key event monitor).
final class HotKey {
    static let shared = HotKey()

    /// Called on the main thread when the shortcut is pressed.
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private func installHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.shared.onPress?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    /// Replaces any registered shortcut. Returns the Carbon status (0 = OK).
    @discardableResult
    func register(_ shortcut: Shortcut) -> OSStatus {
        unregister()
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x5343_524E), id: 1) // 'SCRN'
        // Option bit 0 is kEventHotKeyExclusive: fail if another app holds the combination.
        return RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, id,
                                   GetApplicationEventTarget(), OptionBits(1), &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    /// Whether an enabled macOS keyboard shortcut (System Settings > Keyboard >
    /// Keyboard Shortcuts) uses the same combination.
    static func isSystemShortcut(_ shortcut: Shortcut) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let list = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        let mask = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        for entry in list {
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let mods = entry[kHISymbolicHotKeyModifiers as String] as? Int else { continue }
            if code == Int(shortcut.keyCode) && UInt32(truncatingIfNeeded: mods) & mask == shortcut.carbonModifiers {
                return true
            }
        }
        return false
    }
}
