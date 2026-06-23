import Cocoa

// Shared with main.swift's single-instance guard.
let wmLockPath = "/tmp/wm.lock"

// MARK: - ANSI styling (only when stdout is a terminal)

private enum Style {
    static let enabled = isatty(STDOUT_FILENO) != 0
    private static func wrap(_ code: String, _ s: String) -> String {
        enabled ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s
    }
    static func bold(_ s: String) -> String   { wrap("1;37", s) }
    static func green(_ s: String) -> String  { wrap("0;32", s) }
    static func red(_ s: String) -> String    { wrap("0;31", s) }
    static func yellow(_ s: String) -> String { wrap("0;33", s) }
    static func grey(_ s: String) -> String   { wrap("90", s) }
}

// MARK: - Daemon detection via the single-instance lock

private struct DaemonInfo {
    var running = false
    var pid: pid_t?
    var accessibility: Bool?  // nil when unknown
    var tiling: Bool?
}

/// The daemon holds an exclusive flock on the lock file for its lifetime and
/// records its pid, Accessibility grant, and tiling mode there as key=value
/// lines. A separate process can therefore tell whether the daemon is running
/// (the lock can't be acquired) and read its self-reported state.
private func daemonStatus() -> DaemonInfo {
    var info = DaemonInfo()
    let fd = open(wmLockPath, O_RDWR)
    guard fd >= 0 else { return info }
    defer { close(fd) }

    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
        flock(fd, LOCK_UN)
        return info // acquired the lock → no daemon is holding it
    }
    info.running = true

    var buf = [CChar](repeating: 0, count: 256)
    let n = pread(fd, &buf, 255, 0)
    guard n > 0 else { return info }
    buf[Int(n)] = 0
    for line in String(cString: buf).split(separator: "\n") {
        // Legacy format: a bare pid on the first line.
        if let p = pid_t(line.trimmingCharacters(in: .whitespaces)) { info.pid = p; continue }
        let kv = line.split(separator: "=", maxSplits: 1)
        guard kv.count == 2 else { continue }
        let value = kv[1].trimmingCharacters(in: .whitespaces)
        switch kv[0].trimmingCharacters(in: .whitespaces) {
        case "pid":           info.pid = pid_t(value)
        case "accessibility": info.accessibility = (value == "1")
        case "tiling":        info.tiling = (value == "1")
        default:              break
        }
    }
    return info
}

// MARK: - `wm status`

func runStatus() -> Never {
    let info = daemonStatus()
    let active = activeSpaceID()
    let spaces = orderedSpaces()

    func row(_ label: String, _ value: String) {
        let padded = label.padding(toLength: 15, withPad: " ", startingAt: 0)
        print("  \(Style.grey(padded))\(value)")
    }

    print("")
    print("  \(info.running ? Style.green("●") : Style.red("●")) \(Style.bold("wm")) \(Style.grey(appVersion))")
    print("")

    if info.running {
        let detail = info.pid.map { Style.grey(" (pid \($0))") } ?? ""
        row("Daemon", Style.green("running") + detail)
    } else {
        row("Daemon", Style.red("stopped"))
    }

    let agent = ("~/Library/LaunchAgents/com.hmblair.wm.plist" as NSString).expandingTildeInPath
    let autostart = FileManager.default.fileExists(atPath: agent)
    row("Auto-start", autostart ? Style.green("enabled") : Style.red("disabled"))

    // Reported by the daemon itself (the CLI process can't see the daemon's grant).
    switch info.accessibility {
    case .some(true):  row("Accessibility", Style.green("granted"))
    case .some(false): row("Accessibility", Style.yellow("not granted"))
    case .none:        row("Accessibility", Style.grey("unknown"))
    }

    if let tiling = info.tiling {
        row("Tiling", tiling ? Style.green("on") : Style.grey("off"))
    }

    print("")

    // Spaces: desktops numbered, fullscreen shown by app initial, active bracketed.
    var desktop = 0
    var rendered: [String] = []
    for sp in spaces {
        let label: String
        if sp.isFullScreen {
            label = appNameForSpace(sp.id).flatMap { $0.first.map(String.init) } ?? "·"
        } else {
            desktop += 1
            label = "\(desktop)"
        }
        if sp.id == active {
            rendered.append(Style.bold(Style.green("[\(label)]")))
        } else {
            rendered.append(Style.grey(label))
        }
    }
    row("Spaces", rendered.joined(separator: " "))

    let screens = NSScreen.screens
    let displays = screens.map { s -> String in
        let res = "\(Int(s.frame.width))×\(Int(s.frame.height))"
        return s == screens.first ? "\(res)\(Style.grey(" primary"))" : res
    }.joined(separator: Style.grey(", "))
    row("Displays", "\(screens.count)  \(Style.grey("·"))  \(displays)")

    let windows = fetchCGWindowList().filter { $0.layer == 0 }.count
    row("Windows", "\(windows)\(Style.grey(" on active space"))")

    print("")

    let cfgPath = Config.defaultPath
    let abbrev = cfgPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    let cfg = loadConfig()
    if FileManager.default.fileExists(atPath: cfgPath) {
        row("Config", abbrev)
    } else {
        row("Config", Style.grey("defaults (no \(abbrev))"))
    }
    row("Gap", "\(Int(cfg.gap))px")
    row("Keybindings", cfg.keybindings.enabled ? Style.green("on") : Style.grey("off"))
    row("Status bar", cfg.statusBar ? Style.green("on") : Style.grey("off"))

    print("")
    exit(0)
}
