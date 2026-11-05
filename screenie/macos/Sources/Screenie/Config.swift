import Foundation

/// The six styles of the Linux version. Phase 1 of the Mac port implements Aurora,
/// Starfield and Black; the others are kept in the model so the config stays compatible.
enum StyleID: String, CaseIterable, Identifiable {
    case aurora, starfield, farm, hud, agents, black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aurora: return "Aurora"
        case .starfield: return "Starfield"
        case .farm: return "Farm"
        case .hud: return "HUD"
        case .agents: return "Agents"
        case .black: return "Black"
        }
    }

    /// Styles that exist in this build.
    var isAvailable: Bool {
        switch self {
        case .aurora, .starfield, .black: return true
        case .farm, .hud, .agents: return false
        }
    }
}

/// Settings, with the same keys and defaults as `config.py` on Linux.
struct Config: Codable, Equatable {
    var enabled = true            // start automatically after idleMinutes of no input
    var idleMinutes = 5
    var style = StyleID.aurora.rawValue
    var showClock = true
    var lockOnDismiss = false     // show the login window when dismissed
    var shortcut = "<Control><Command>s"
    // HUD style
    var hudLocation = ""          // "lat, lon"; blank = estimate from IP address
    var hudUnits = "auto"         // auto | imperial | metric
    // Agents style
    var agentsDetails = true      // show session titles, project and file names

    enum CodingKeys: String, CodingKey {
        case enabled
        case idleMinutes = "idle_minutes"
        case style
        case showClock = "show_clock"
        case lockOnDismiss = "lock_on_dismiss"
        case shortcut
        case hudLocation = "hud_location"
        case hudUnits = "hud_units"
        case agentsDetails = "agents_details"
    }

    init() {}

    /// Missing or malformed keys fall back to their defaults, like `config.load()`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        enabled = value(.enabled, d.enabled)
        idleMinutes = value(.idleMinutes, d.idleMinutes)
        style = value(.style, d.style)
        showClock = value(.showClock, d.showClock)
        lockOnDismiss = value(.lockOnDismiss, d.lockOnDismiss)
        shortcut = value(.shortcut, d.shortcut)
        hudLocation = value(.hudLocation, d.hudLocation)
        hudUnits = value(.hudUnits, d.hudUnits)
        agentsDetails = value(.agentsDetails, d.agentsDetails)
        if StyleID(rawValue: style) == nil { style = d.style }
        idleMinutes = min(max(idleMinutes, 1), 240)
    }

    var styleID: StyleID { StyleID(rawValue: style) ?? .aurora }

    /// The style actually drawn: one that isn't built yet falls back to Aurora.
    var renderStyle: StyleID { styleID.isAvailable ? styleID : .aurora }

    static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Screenie", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("config.json")

    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return cfg
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard var data = try? enc.encode(self) else { return }
        data.append(0x0A)
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        try? data.write(to: Config.fileURL, options: .atomic)
    }

    static func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }
}

/// Holds the live settings for the whole app and writes every change to disk.
@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var config: Config {
        didSet {
            guard config != oldValue else { return }
            if !reloading {
                config.save()
                fileDate = Config.modificationDate()
            }
            if config.shortcut != oldValue.shortcut { applyHotKey() }
        }
    }

    /// Why the current shortcut can't be used, if it can't.
    @Published var shortcutProblem: String?

    private var fileDate: Date?
    private var reloading = false

    private init() {
        config = Config.load()
        fileDate = Config.modificationDate()
    }

    /// Picks up edits made to config.json by hand (the Linux daemon does the same).
    func reloadIfChanged() {
        let date = Config.modificationDate()
        guard date != fileDate else { return }
        fileDate = date
        reloading = true
        config = Config.load()
        reloading = false
    }

    /// Registers the configured shortcut, or explains why it can't be.
    func applyHotKey() {
        guard let shortcut = Shortcut(string: config.shortcut) else {
            HotKey.shared.unregister()
            shortcutProblem = nil
            return
        }
        let status = HotKey.shared.register(shortcut)
        if status == -9878 { // eventHotKeyExistsErr
            shortcutProblem = "Another app already uses \(shortcut.display)."
        } else if status != 0 {
            shortcutProblem = "Couldn't register \(shortcut.display) (error \(status))."
        } else if HotKey.isSystemShortcut(shortcut) {
            shortcutProblem = "macOS already uses \(shortcut.display), so it may not reach Screenie."
        } else {
            shortcutProblem = nil
        }
    }
}
