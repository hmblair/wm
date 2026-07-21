import Cocoa
import CoreGraphics
import Foundation
import TOMLKit

// Parse a "#rrggbb" / "#rgb" hex string into an NSColor. Returns nil on any
// malformed input so callers can fall back to a default.
func nsColor(fromHex hex: String) -> NSColor? {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }  // #rgb → #rrggbb
    guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
    return NSColor(
        srgbRed: CGFloat((value >> 16) & 0xff) / 255,
        green: CGFloat((value >> 8) & 0xff) / 255,
        blue: CGFloat(value & 0xff) / 255,
        alpha: 1)
}

struct ModifierConfig: Decodable, Equatable {
    var cmd: Bool = false
    var shift: Bool = false
    var ctrl: Bool = false
    var option: Bool = false

    init() {}

    // Decode leniently: a partial table (e.g. only `cmd = true`) keeps the
    // other flags at their defaults. Synthesized Decodable would instead throw
    // on any missing key, silently reverting the whole modifier to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decode(Bool.self, forKey: .cmd) { cmd = v }
        if let v = try? c.decode(Bool.self, forKey: .shift) { shift = v }
        if let v = try? c.decode(Bool.self, forKey: .ctrl) { ctrl = v }
        if let v = try? c.decode(Bool.self, forKey: .option) { option = v }
    }

    enum CodingKeys: String, CodingKey { case cmd, shift, ctrl, option }

    func matches(_ flags: CGEventFlags) -> Bool {
        let hasCmd = flags.contains(.maskCommand)
        let hasShift = flags.contains(.maskShift)
        let hasCtrl = flags.contains(.maskControl)
        let hasOption = flags.contains(.maskAlternate)
        return hasCmd == cmd && hasShift == shift && hasCtrl == ctrl && hasOption == option
    }

    // CGEventFlags for synthesizing key events with these modifiers.
    var eventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if cmd { flags.insert(.maskCommand) }
        if shift { flags.insert(.maskShift) }
        if ctrl { flags.insert(.maskControl) }
        if option { flags.insert(.maskAlternate) }
        return flags
    }

    // Bitmask in NSEvent's device-independent modifier flags, as stored in the
    // com.apple.symbolichotkeys parameters array.
    var symbolicHotkeyMask: Int {
        var mask = 0
        if cmd { mask |= 1 << 20 }
        if shift { mask |= 1 << 17 }
        if ctrl { mask |= 1 << 18 }
        if option { mask |= 1 << 19 }
        return mask
    }
}

struct KeybindingsConfig: Decodable {
    var focusModifier: ModifierConfig = {
        var m = ModifierConfig(); m.cmd = true; return m
    }()
    var swapModifier: ModifierConfig = {
        var m = ModifierConfig(); m.cmd = true; m.shift = true; return m
    }()
    var moveToSpaceModifier: ModifierConfig = {
        var m = ModifierConfig(); m.cmd = true; m.shift = true; return m
    }()
    // Modifier for the system "Switch to Desktop N" shortcuts (Ctrl by default).
    // wm both registers these shortcuts and posts them to switch Spaces, so this
    // drives the symbolic-hotkey registration and wm's own key events together.
    var spaceSwitchModifier: ModifierConfig = {
        var m = ModifierConfig(); m.ctrl = true; return m
    }()
    var enabled: Bool = true

    init() {}

    // Decode leniently so a table specifying only some bindings keeps the rest
    // at their defaults (synthesized Decodable would throw on the first missing
    // key, reverting every binding to defaults).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decode(ModifierConfig.self, forKey: .focusModifier) { focusModifier = v }
        if let v = try? c.decode(ModifierConfig.self, forKey: .swapModifier) { swapModifier = v }
        if let v = try? c.decode(ModifierConfig.self, forKey: .moveToSpaceModifier) { moveToSpaceModifier = v }
        if let v = try? c.decode(ModifierConfig.self, forKey: .spaceSwitchModifier) { spaceSwitchModifier = v }
        if let v = try? c.decode(Bool.self, forKey: .enabled) { enabled = v }
    }

    enum CodingKeys: String, CodingKey {
        case focusModifier = "focus_modifier"
        case swapModifier = "swap_modifier"
        case moveToSpaceModifier = "move_to_space_modifier"
        case spaceSwitchModifier = "space_switch_modifier"
        case enabled
    }
}

enum SplitPreference: String, Codable {
    case none
    case vertical
    case horizontal
}

struct Config: Decodable {
    var gap: CGFloat = 8
    var pollInterval: CFTimeInterval = 0.016
    var ignoredApps: Set<String> = []
    var excludedApps: Set<String> = []
    var statusBar: Bool = true
    var prefer: SplitPreference = .none
    var keybindings: KeybindingsConfig = KeybindingsConfig()
    // Whether wm manages global macOS settings (native tiling, Space reordering,
    // switch-to-Desktop shortcuts, window corner radius). Applied on start and
    // reverted on clean stop / `wm reset`. Set false to leave the system alone.
    var manageSystemSettings: Bool = true
    var focusBorder: Bool = false
    var borderColor: NSColor = NSColor(srgbRed: 137 / 255, green: 244 / 255, blue: 152 / 255, alpha: 1)
    var borderWidth: CGFloat = 1
    // Corner radius. wm pins the global window corner radius
    // (NSConvolutionOverride1 on Tahoe) to this, so config.toml is the single
    // source of truth for both the rendered corners and the outline.
    var cornerRadius: CGFloat = 12

    static let defaultPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/wm/config.toml"
    }()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? container.decode(Double.self, forKey: .gap) {
            gap = CGFloat(v)
        } else if let v = try? container.decode(Int.self, forKey: .gap) {
            gap = CGFloat(v)
        }
        // Config exposes the rate in Hz (more intuitive than an interval in
        // seconds); convert to the internal poll interval here. Ignore
        // non-positive rates, which would produce a non-firing timer.
        if let v = try? container.decode(Double.self, forKey: .pollInterval), v > 0 {
            pollInterval = 1.0 / v
        } else if let v = try? container.decode(Int.self, forKey: .pollInterval), v > 0 {
            pollInterval = 1.0 / CFTimeInterval(v)
        }
        if let v = try? container.decode([String].self, forKey: .ignoredApps) {
            ignoredApps = Set(v)
        }
        if let v = try? container.decode([String].self, forKey: .excludedApps) {
            excludedApps = Set(v)
        }
        if let v = try? container.decode(Bool.self, forKey: .statusBar) {
            statusBar = v
        }
        if let v = try? container.decode(SplitPreference.self, forKey: .prefer) {
            prefer = v
        }
        if let v = try? container.decode(KeybindingsConfig.self, forKey: .keybindings) {
            keybindings = v
        }
        if let v = try? container.decode(Bool.self, forKey: .manageSystemSettings) {
            manageSystemSettings = v
        }
        if let v = try? container.decode(Bool.self, forKey: .focusBorder) {
            focusBorder = v
        }
        if let v = try? container.decode(String.self, forKey: .borderColor),
           let color = nsColor(fromHex: v) {
            borderColor = color
        }
        if let v = try? container.decode(Double.self, forKey: .borderWidth), v > 0 {
            borderWidth = CGFloat(v)
        } else if let v = try? container.decode(Int.self, forKey: .borderWidth), v > 0 {
            borderWidth = CGFloat(v)
        }
        if let v = try? container.decode(Double.self, forKey: .cornerRadius), v >= 0 {
            cornerRadius = CGFloat(v)
        } else if let v = try? container.decode(Int.self, forKey: .cornerRadius), v >= 0 {
            cornerRadius = CGFloat(v)
        }
    }

    enum CodingKeys: String, CodingKey {
        case gap
        case pollInterval = "poll_rate"
        case ignoredApps = "ignored_apps"
        case excludedApps = "excluded_apps"
        case statusBar = "status_bar"
        case prefer
        case keybindings
        case manageSystemSettings = "manage_system_settings"
        case focusBorder = "focus_border"
        case borderColor = "border_color"
        case borderWidth = "border_width"
        case cornerRadius = "corner_radius"
    }
}

// A missing file means "use defaults" and returns Config(). A file that exists
// but fails to parse returns `fallbackOnError` if given, so a live reload keeps
// the last-good config rather than resetting every setting on a transient typo;
// only the initial load (no prior config) falls back to defaults.
func loadConfig(from path: String = Config.defaultPath, fallbackOnError: Config? = nil) -> Config {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
        return Config()
    }

    do {
        return try TOMLDecoder().decode(Config.self, from: contents)
    } catch {
        warn("config: failed to parse \(path): \(error) — \(fallbackOnError != nil ? "keeping current config" : "using defaults")")
        return fallbackOnError ?? Config()
    }
}
