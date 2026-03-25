import Cocoa
import CoreGraphics

// --- Argument parsing ---

let knownArgs: Set<String> = ["--verbose", "-v", "--dump", "--no-tile", "--version"]
for arg in CommandLine.arguments.dropFirst() {
    if !knownArgs.contains(arg) {
        fputs("unknown argument: \(arg)\nusage: focus-follows-mouse [--verbose|-v] [--dump] [--no-tile] [--version]\n", stderr)
        exit(1)
    }
}

if CommandLine.arguments.contains("--version") {
    print("focus-follows-mouse \(appVersion)")
    exit(0)
}

// --- Single instance guard ---

let lockPath = "/tmp/focus-follows-mouse.lock"
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    fputs("focus-follows-mouse: another instance is already running\n", stderr)
    exit(1)
}

let verbose = CommandLine.arguments.contains("--verbose") || CommandLine.arguments.contains("-v")
let tilingEnabled = !CommandLine.arguments.contains("--no-tile")
let config = loadConfig()

// --- Global state (mutated only in executePlan) ---

var managedWindows: [UInt32: ManagedWindow] = [:]
var bspTrees: [DisplaySpaceKey: BSPTree] = [:]
var lastActiveSpace: CGSSpaceID = 0
var lastFocusedWindow: UInt32 = 0
var pendingWarpToWindow: UInt32 = 0
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

let mainRunLoop = CFRunLoopGetCurrent()!

func installSignalHandlers() {
    let handler: @convention(c) (Int32) -> Void = { sig in
        log("received signal \(sig), shutting down")
        CFRunLoopStop(mainRunLoop)
    }
    signal(SIGINT, handler)
    signal(SIGTERM, handler)
}

installSignalHandlers()

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

func tick() {
    let snap = readWorld()
    let plan = computePlan(snap)
    executePlan(plan, snap: snap)
}

let pollTimer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault,
    CFAbsoluteTimeGetCurrent(), config.pollInterval, 0, 0) { _ in
    tick()
}
CFRunLoopAddTimer(CFRunLoopGetCurrent(), pollTimer, .commonModes)

log("running\(verbose ? " (verbose)" : "")")
CFRunLoopRun()
log("stopped")
