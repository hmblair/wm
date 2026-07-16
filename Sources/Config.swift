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

struct ModifierConfig: Codable {
    var cmd: Bool = false
    var shift: Bool = false
    var ctrl: Bool = false
    var option: Bool = false

    func matches(_ flags: CGEventFlags) -> Bool {
        let hasCmd = flags.contains(.maskCommand)
        let hasShift = flags.contains(.maskShift)
        let hasCtrl = flags.contains(.maskControl)
        let hasOption = flags.contains(.maskAlternate)
        return hasCmd == cmd && hasShift == shift && hasCtrl == ctrl && hasOption == option
    }
}

struct KeybindingsConfig: Codable {
    var focusModifier: ModifierConfig = {
        var m = ModifierConfig(); m.cmd = true; return m
    }()
    var swapModifier: ModifierConfig = {
        var m = ModifierConfig(); m.cmd = true; m.shift = true; return m
    }()
    var moveToSpaceModifier: ModifierConfig = {
        var m = ModifierConfig(); m.cmd = true; m.shift = true; return m
    }()
    var enabled: Bool = true

    enum CodingKeys: String, CodingKey {
        case focusModifier = "focus_modifier"
        case swapModifier = "swap_modifier"
        case moveToSpaceModifier = "move_to_space_modifier"
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
    var focusBorder: Bool = false
    var borderColor: NSColor = .systemGreen
    var borderWidth: CGFloat = 1
    // Outline corner radius. Match this to the system window corner radius
    // (NSConvolutionOverride1 on Tahoe, ~12 by default) so it hugs the corners.
    var borderRadius: CGFloat = 12

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
        if let v = try? container.decode(Double.self, forKey: .borderRadius), v >= 0 {
            borderRadius = CGFloat(v)
        } else if let v = try? container.decode(Int.self, forKey: .borderRadius), v >= 0 {
            borderRadius = CGFloat(v)
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
        case focusBorder = "focus_border"
        case borderColor = "border_color"
        case borderWidth = "border_width"
        case borderRadius = "border_radius"
    }
}

func loadConfig(from path: String = Config.defaultPath) -> Config {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
        return Config()
    }

    do {
        return try TOMLDecoder().decode(Config.self, from: contents)
    } catch {
        warn("config: failed to parse \(path): \(error)")
        return Config()
    }
}
