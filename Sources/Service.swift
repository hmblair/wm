import Foundation

// launchd service control for the `wm start` / `wm stop` subcommands. These drive
// the same launchd agent that `make install` sets up, so they mirror
// `make load` / `make unload`.

let launchAgentPlistPath =
    "\(NSHomeDirectory())/Library/LaunchAgents/com.hmblair.wm.plist"

// `launchctl load`/`unload` exit 0 even when they fail (the error only goes to
// stderr), so we never trust their status — we verify the daemon's actual state
// via its lock instead, and only surface launchctl's output when a check fails.
private func launchctl(_ args: [String]) -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    do {
        try proc.run()
    } catch {
        return "failed to run launchctl: \(error.localizedDescription)"
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

// The daemon holds an exclusive flock on the lock file for its lifetime, so a
// separate process can detect it by failing to acquire that lock. Returns
// whether another process holds the lock on the given open descriptor.
func daemonHoldsLock(_ fd: Int32) -> Bool {
    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
        flock(fd, LOCK_UN)
        return false
    }
    return true
}

func daemonIsRunning() -> Bool {
    let fd = open(wmLockPath, O_RDWR)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    return daemonHoldsLock(fd)
}

// The daemon starts (RunAtLoad) and stops (SIGTERM) asynchronously, so poll the
// lock for up to ~3s until it reaches the desired state.
private func waitForDaemon(running target: Bool) -> Bool {
    for _ in 0..<30 {
        if daemonIsRunning() == target { return true }
        usleep(100_000)
    }
    return daemonIsRunning() == target
}

private func requireInstalled() {
    guard FileManager.default.fileExists(atPath: launchAgentPlistPath) else {
        fputs("wm: service not installed (\(launchAgentPlistPath) not found).\n", stderr)
        fputs("Run 'make install' first.\n", stderr)
        exit(1)
    }
}

func runStart() -> Never {
    requireInstalled()
    if daemonIsRunning() {
        print("wm: already running")
        exit(0)
    }
    let output = launchctl(["load", "-w", launchAgentPlistPath])
    if waitForDaemon(running: true) {
        print("wm: service started")
        exit(0)
    }
    fputs("wm: service failed to start\n", stderr)
    if !output.isEmpty { fputs("launchctl: \(output)\n", stderr) }
    exit(1)
}

func runStop() -> Never {
    requireInstalled()
    if !daemonIsRunning() {
        print("wm: not running")
        exit(0)
    }
    let output = launchctl(["unload", "-w", launchAgentPlistPath])
    if waitForDaemon(running: false) {
        print("wm: service stopped")
        exit(0)
    }
    fputs("wm: service failed to stop\n", stderr)
    if !output.isEmpty { fputs("launchctl: \(output)\n", stderr) }
    exit(1)
}
