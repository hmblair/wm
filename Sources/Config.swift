import CoreGraphics
import Foundation
import TOMLKit

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

struct Config: Codable {
    var gap: CGFloat = 8
    var pollInterval: CFTimeInterval = 0.016
    var ignoredApps: Set<String> = []
    var excludedApps: Set<String> = []
    var keybindings: KeybindingsConfig = KeybindingsConfig()

    static let defaultPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/focus-follows-mouse/config.toml"
    }()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? container.decode(Double.self, forKey: .gap) {
            gap = CGFloat(v)
        } else if let v = try? container.decode(Int.self, forKey: .gap) {
            gap = CGFloat(v)
        }
        if let v = try? container.decode(Double.self, forKey: .pollInterval) {
            pollInterval = v
        }
        if let v = try? container.decode([String].self, forKey: .ignoredApps) {
            ignoredApps = Set(v)
        }
        if let v = try? container.decode([String].self, forKey: .excludedApps) {
            excludedApps = Set(v)
        }
        if let v = try? container.decode(KeybindingsConfig.self, forKey: .keybindings) {
            keybindings = v
        }
    }

    enum CodingKeys: String, CodingKey {
        case gap
        case pollInterval = "poll_interval"
        case ignoredApps = "ignored_apps"
        case excludedApps = "excluded_apps"
        case keybindings
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
