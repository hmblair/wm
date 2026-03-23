import CoreGraphics
import Foundation
import TOMLKit

struct Config: Codable {
    var gap: CGFloat = 8

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
    }
}

func loadConfig(from path: String = Config.defaultPath) -> Config {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
        return Config()
    }

    do {
        return try TOMLDecoder().decode(Config.self, from: contents)
    } catch {
        fputs("focus-follows-mouse: failed to parse \(path): \(error)\n", stderr)
        return Config()
    }
}
