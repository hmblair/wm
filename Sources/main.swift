import Cocoa
import CoreGraphics
import ApplicationServices

// --- Argument parsing & CLI subcommands ---

func printUsage(_ stream: UnsafeMutablePointer<FILE> = stdout) {
    fputs("""
    usage: wm [command] [flags]

    With no command, wm prints daemon status, open spaces, and config.

    commands:
      start            Start the wm background service
      stop             Stop the wm background service
      daemon           Run the window manager in the foreground (used by launchd)
      dump             Print on-screen window state and exit
      help             Show this help

    flags:
      --version        Print version and exit

    daemon flags (with 'wm daemon'):
      --verbose, -v    Print timestamped debug output to stderr
      --no-tile        Disable the tiling window manager

    """, stream)
}

// Global flags, handled regardless of subcommand.
if CommandLine.arguments.contains("-h") || CommandLine.arguments.contains("--help") {
    printUsage(); exit(0)
}
if CommandLine.arguments.contains("--version") {
    print("wm \(appVersion)")
    exit(0)
}

// The first non-flag argument selects the subcommand; with none, show status.
// Every command except `daemon` runs and exits here, before the daemon starts.
let subcommand = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") }
switch subcommand {
case .none:             runStatus()
case .some("start"):    runStart()
case .some("stop"):     runStop()
case .some("dump"):     runDump()
case .some("daemon"):   break  // fall through to daemon startup below
case .some("help"):     printUsage(); exit(0)
case .some(let cmd):
    fputs("unknown command: \(cmd)\n", stderr)
    printUsage(stderr); exit(1)
}

// From here on we run as the daemon: `wm daemon [flags]`.
let knownArgs: Set<String> = ["daemon", "--verbose", "-v", "--no-tile"]
for arg in CommandLine.arguments.dropFirst() {
    if !knownArgs.contains(arg) {
        fputs("unknown argument: \(arg)\n", stderr)
        printUsage(stderr); exit(1)
    }
}

// --- Single instance guard ---

let lockFD = open(wmLockPath, O_CREAT | O_RDWR, 0o600)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    fputs("wm: another instance is already running\n", stderr)
    exit(1)
}

let verbose = CommandLine.arguments.contains("--verbose") || CommandLine.arguments.contains("-v")
let tilingEnabled = !CommandLine.arguments.contains("--no-tile")
var config = loadConfig()

// Record runtime info in the lock file so `wm status` (a separate process) can
// report the daemon's pid, Accessibility grant, and tiling mode. The CLI can't
// query the daemon's Accessibility itself: AXIsProcessTrusted reflects the
// invoking process, not the launchd-launched app, so only the daemon knows.
let lockInfo = "pid=\(getpid())\naccessibility=\(AXIsProcessTrusted() ? 1 : 0)\ntiling=\(tilingEnabled ? 1 : 0)\n"
ftruncate(lockFD, 0)
_ = lockInfo.withCString { write(lockFD, $0, strlen($0)) }

// --- Global state (mutated only in executePlan) ---

var managedWindows: [UInt32: ManagedWindow] = [:]
var bspTrees: [DisplaySpaceKey: BSPTree] = [:]
var lastActiveSpace: CGSSpaceID = 0
var lastFocusedWindow: UInt32 = 0
var pendingWarpToWindow: UInt32 = 0
var tickNumber: UInt64 = 0
var lastMousePosition: CGPoint = {
    let nsPos = NSEvent.mouseLocation
    let screenHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGPoint(x: nsPos.x, y: screenHeight - nsPos.y)
}()

// --- Signal handling ---

func installSignalHandlers() {
    let handler: @convention(c) (Int32) -> Void = { sig in
        log("received signal \(sig), shutting down")
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }
    signal(SIGINT, handler)
    signal(SIGTERM, handler)
}

installSignalHandlers()

// --- Config file watcher ---

var configWatcher: DispatchSourceFileSystemObject?
var configFileWatcher: DispatchSourceFileSystemObject?
var pollTimer: CFRunLoopTimer?

// (Re)install the main-loop timer at the current poll interval. The interval is
// baked into a CFRunLoopTimer at creation, so a live poll_rate change means
// invalidating the old timer and scheduling a fresh one.
func installPollTimer() {
    if let existing = pollTimer { CFRunLoopTimerInvalidate(existing) }
    let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault,
        CFAbsoluteTimeGetCurrent(), config.pollInterval, 0, 0) { _ in
        tick()
    }
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
    pollTimer = timer
}

func reloadConfig() {
    let newConfig = loadConfig()
    let intervalChanged = newConfig.pollInterval != config.pollInterval
    let statusBarChanged = newConfig.statusBar != config.statusBar
    log("config: reloaded")
    config = newConfig
    if intervalChanged {
        log("config: poll rate → \(1.0 / config.pollInterval) Hz")
        installPollTimer()
    }
    if statusBarChanged {
        log("config: status bar → \(config.statusBar ? "on" : "off")")
        if config.statusBar { setupStatusBar() } else { teardownStatusBar() }
    }
}

// Watch the config file itself for in-place edits (truncate + write to the same
// inode), which the directory watch below cannot see. An atomic save (write
// temp + rename over) unlinks the watched inode, so re-arm on .delete/.rename;
// the directory watch re-arms it too as a backstop.
func armConfigFileWatcher() {
    configFileWatcher?.cancel()
    let fd = open(Config.defaultPath, O_EVTONLY)
    guard fd >= 0 else { configFileWatcher = nil; return }

    let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .delete, .rename],
        queue: .main)
    source.setEventHandler {
        let flags = source.data
        reloadConfig()
        if flags.contains(.delete) || flags.contains(.rename) {
            armConfigFileWatcher()
        }
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    configFileWatcher = source
}

func watchConfigFile() {
    // Directory watch: catches atomic saves (rename into the dir), file
    // creation, and deletion. It survives atomic replaces, so it also re-arms
    // the file watch when an editor swaps the inode out from under it.
    let dir = (Config.defaultPath as NSString).deletingLastPathComponent
    let fd = open(dir, O_EVTONLY)
    if fd >= 0 {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler {
            reloadConfig()
            armConfigFileWatcher()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configWatcher = source
    }

    armConfigFileWatcher()
}

watchConfigFile()

// --- Event tap ---

var eventMask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
if config.keybindings.enabled {
    eventMask |= CGEventMask(1 << CGEventType.keyDown.rawValue)
}

let tap = createEventTap(eventMask: eventMask)
globalTap = tap
let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

// --- Main loop (read → compute → execute) ---

// Idle-tick short-circuit. computePlan is a pure function of the snapshot, so
// when the snapshot is identical to the last one we acted on and no input is
// pending, recomputing would reproduce the already-applied state. In steady
// state (stationary cursor, unchanged windows/Space) this skips the entire
// reconcile → BSP → tile → status-bar pipeline, leaving only the cheap read.

struct WindowSig: Equatable {
    let id: UInt32
    let frame: CGRect
    let layer: Int
}

struct TickSignature: Equatable {
    let windows: [WindowSig]
    let spaceID: CGSSpaceID
    let mouse: CGPoint
    let mouseDown: Bool
    let missionControl: Bool
    let focusedID: UInt32
}

var lastSignature: TickSignature?

func tickSignature(_ snap: WorldSnapshot) -> TickSignature {
    TickSignature(
        windows: snap.cgWindows.map { WindowSig(id: $0.id, frame: $0.frame, layer: $0.layer) },
        spaceID: snap.spaceID,
        mouse: snap.mousePosition,
        mouseDown: snap.mouseDown,
        missionControl: snap.missionControlActive,
        focusedID: snap.focusedWindow?.id ?? 0
    )
}

func tick() {
    tickNumber += 1
    let snap = readWorld()
    let sig = tickSignature(snap)

    let noPendingInput = snap.commands.isEmpty && snap.moveCommands.isEmpty
        && !snap.rotate && pendingWarpToWindow == 0
    if noPendingInput, lastSignature == sig {
        return
    }

    let plan = computePlan(snap)
    executePlan(plan, snap: snap)
    if config.statusBar { updateStatusBar(activeSpace: snap.spaceID) }
    lastSignature = sig
}

installPollTimer()

if config.statusBar { setupStatusBar() }
log("running\(verbose ? " (verbose)" : "")")
NSApplication.shared.run()
log("stopped")
