import Cocoa
import CoreGraphics
import ApplicationServices

// --- Argument parsing & CLI subcommands ---

func printUsage(_ stream: UnsafeMutablePointer<FILE> = stdout) {
    fputs("""
    usage: wm [command] [flags]

    commands:
      status           Print daemon status, open spaces, and config
      help             Show this help

    flags (daemon):
      --verbose, -v    Print timestamped debug output to stderr
      --dump           Dump window info for the current space and exit
      --no-tile        Disable the tiling window manager
      --version        Print version and exit

    With no command, wm runs as the window-manager daemon.

    """, stream)
}

// CLI subcommands run and exit before the daemon starts.
if CommandLine.arguments.count > 1, !CommandLine.arguments[1].hasPrefix("-") {
    switch CommandLine.arguments[1] {
    case "status": runStatus()
    case "help":   printUsage(); exit(0)
    default:
        fputs("unknown command: \(CommandLine.arguments[1])\n", stderr)
        printUsage(stderr); exit(1)
    }
}

if CommandLine.arguments.contains("-h") || CommandLine.arguments.contains("--help") {
    printUsage(); exit(0)
}

let knownArgs: Set<String> = ["--verbose", "-v", "--dump", "--no-tile", "--version"]
for arg in CommandLine.arguments.dropFirst() {
    if !knownArgs.contains(arg) {
        fputs("unknown argument: \(arg)\n", stderr)
        printUsage(stderr); exit(1)
    }
}

if CommandLine.arguments.contains("--version") {
    print("wm \(appVersion)")
    exit(0)
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

// --- Debug dump ---

if CommandLine.arguments.contains("--dump") {
    runDump()
}

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

func watchConfigFile() {
    let dir = (Config.defaultPath as NSString).deletingLastPathComponent
    let fd = open(dir, O_EVTONLY)
    guard fd >= 0 else { return }

    let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd, eventMask: .write,
        queue: .main)

    source.setEventHandler {
        let newConfig = loadConfig()
        log("config: reloaded")
        config = newConfig
    }

    source.setCancelHandler { close(fd) }
    source.resume()
    configWatcher = source
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

let pollTimer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault,
    CFAbsoluteTimeGetCurrent(), config.pollInterval, 0, 0) { _ in
    tick()
}
CFRunLoopAddTimer(CFRunLoopGetCurrent(), pollTimer, .commonModes)

if config.statusBar { setupStatusBar() }
log("running\(verbose ? " (verbose)" : "")")
NSApplication.shared.run()
log("stopped")
