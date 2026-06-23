import Cocoa
import ApplicationServices

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

/// The daemon holds an exclusive flock on the lock file for its lifetime and
/// writes its pid there. A separate process can therefore tell whether the
/// daemon is running (the lock can't be acquired) and read its pid.
private func daemonStatus() -> (running: Bool, pid: pid_t?) {
    let fd = open(wmLockPath, O_RDWR)
    guard fd >= 0 else { return (false, nil) }
    defer { close(fd) }

    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
        flock(fd, LOCK_UN)
        return (false, nil) // acquired the lock → no daemon is holding it
    }

    var buf = [CChar](repeating: 0, count: 32)
    let n = pread(fd, &buf, 31, 0)
    if n > 0 {
        buf[Int(n)] = 0
        if let pid = pid_t(String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0 {
            return (true, pid)
        }
    }
    return (true, nil)
}

// MARK: - `wm status`

func runStatus() -> Never {
    let (running, pid) = daemonStatus()
    let active = activeSpaceID()
    let spaces = orderedSpaces()

    func row(_ label: String, _ value: String) {
        let padded = label.padding(toLength: 15, withPad: " ", startingAt: 0)
        print("  \(Style.grey(padded))\(value)")
    }

    print("")
    print("  \(running ? Style.green("●") : Style.red("●")) \(Style.bold("wm")) \(Style.grey(appVersion))")
    print("")

    if running {
        let detail = pid.map { Style.grey(" (pid \($0))") } ?? ""
        row("Daemon", Style.green("running") + detail)
    } else {
        row("Daemon", Style.red("stopped"))
    }

    let agent = ("~/Library/LaunchAgents/com.hmblair.wm.plist" as NSString).expandingTildeInPath
    let autostart = FileManager.default.fileExists(atPath: agent)
    row("Auto-start", autostart ? Style.green("enabled") : Style.red("disabled"))

    // Reflects the invoked binary; accurate when run as the installed signed app.
    row("Accessibility", AXIsProcessTrusted() ? Style.green("granted") : Style.yellow("not granted"))

    print("")

    // Spaces: desktops numbered, fullscreen shown by app initial, active bracketed.
    var desktop = 0
    var activeLabel = "?"
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
            activeLabel = label
            rendered.append(Style.bold(Style.green("[\(label)]")))
        } else {
            rendered.append(Style.grey(" \(label) "))
        }
    }
    row("Active space", "\(activeLabel)\(Style.grey(" of \(spaces.count)"))")
    row("Spaces", rendered.joined())

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
