import Cocoa
import CoreGraphics

// Shared with main.swift's single-instance guard. Kept under ~/.cache rather
// than /tmp: macOS's periodic /tmp cleaner reaps files untouched for ~3 days,
// and a long-lived daemon never re-touches its lock (flock doesn't bump atime).
// If /tmp/wm.lock is swept while the daemon holds it, the daemon keeps its fd on
// the now-orphaned inode while `wm stop`/`wm status` open the vanished path, fail
// with ENOENT, and wrongly report the daemon stopped.
let wmLockPath = "\(NSHomeDirectory())/.cache/wm/wm.lock"

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

    guard daemonHoldsLock(fd) else { return info }
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

private func row(_ label: String, _ value: String) {
    let padded = label.padding(toLength: 15, withPad: " ", startingAt: 0)
    print("  \(Style.grey(padded))\(value)")
}

private func printHeader(_ info: DaemonInfo) {
    print("")
    print("  \(info.running ? Style.green("●") : Style.red("●")) \(Style.bold("wm")) \(Style.grey(appVersion))")
    print("")
}

private func printDaemonRows(_ info: DaemonInfo) {
    if info.running {
        let detail = info.pid.map { Style.grey(" (pid \($0))") } ?? ""
        row("Daemon", Style.green("running") + detail)
    } else {
        row("Daemon", Style.red("stopped"))
    }

    let autostart = FileManager.default.fileExists(atPath: launchAgentPlistPath)
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
}

// Spaces: desktops numbered, fullscreen shown by app initial, active bracketed.
private func printSpacesRow() {
    let active = activeSpaceID()
    let spaces = orderedSpaces()
    let rendered = zip(spaces, spaceLabels(for: spaces)).map { sp, label in
        sp.id == active ? Style.bold(Style.green("[\(label)]")) : Style.grey(label)
    }
    row("Spaces", rendered.joined(separator: " "))
}

private func printDisplaysRow() {
    let screens = NSScreen.screens
    let displays = screens.map { s -> String in
        let lw = Int(s.frame.width), lh = Int(s.frame.height)
        var res = "\(lw)×\(lh)"
        // On retina/scaled displays the frame is in logical points; show the
        // true backing pixels from the current mode, with the logical size grey.
        if let mode = CGDisplayCopyDisplayMode(displayID(for: s)),
           mode.pixelWidth != lw || mode.pixelHeight != lh {
            res = "\(mode.pixelWidth)×\(mode.pixelHeight)\(Style.grey(" (\(lw)×\(lh))"))"
        }
        return s == screens.first ? "\(res)\(Style.grey(" primary"))" : res
    }.joined(separator: Style.grey(", "))
    row("Displays", "\(screens.count)  \(Style.grey("·"))  \(displays)")
}

private func printWindowsRow() {
    let windows = fetchCGWindowList().filter { $0.layer == standardWindowLayer }.count
    row("Windows", "\(windows)\(Style.grey(" on active space"))")
}

private func printConfigRows() {
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
}

func runStatus() -> Never {
    let info = daemonStatus()
    printHeader(info)
    printDaemonRows(info)
    print("")
    printSpacesRow()
    printDisplaysRow()
    printWindowsRow()
    print("")
    printConfigRows()
    print("")
    exit(0)
}
