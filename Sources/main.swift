import Cocoa
import CoreGraphics
import os

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

// --- Logging ---

private let logger = Logger(subsystem: "com.hmblair.focus-follows-mouse", category: "general")

private func emit(_ msg: String, level: OSLogType = .info) {
    logger.log(level: level, "\(msg, privacy: .public)")
    if verbose { fputs("\(msg)\n", stderr) }
}

func log(_ message: @autoclosure () -> String) { emit(message()) }
func warn(_ message: @autoclosure () -> String) { emit(message(), level: .error) }

// --- Global state (mutated only in executePlan) ---

var managedWindows: [UInt32: ManagedWindow] = [:]
var bspTrees: [DisplaySpaceKey: BSPTree] = [:]
var lastActiveSpace: CGSSpaceID = 0
var lastFocusedWindow: UInt32 = 0
var pendingWarpToWindow: UInt32 = 0

// --- Pending input state (written by event tap, consumed by readWorld) ---

struct PendingKeyCommand {
    let direction: Direction
    let swap: Bool
}

var pendingKeyCommands: [PendingKeyCommand] = []
var pendingMoveToSpace: [Int] = []
var pendingRotate = false
var lastMousePosition: CGPoint = {
    let nsPos = NSEvent.mouseLocation
    let screenHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGPoint(x: nsPos.x, y: screenHeight - nsPos.y)
}()

// --- Debug dump ---

if CommandLine.arguments.contains("--dump") {
    let dumpDelay: TimeInterval = 3
    fputs("Dumping in \(Int(dumpDelay)) seconds — switch to the window you want to inspect.\n", stderr)
    Thread.sleep(forTimeInterval: dumpDelay)
    guard let frontApp = NSWorkspace.shared.frontmostApplication else {
        fputs("no frontmost app\n", stderr); exit(1)
    }
    let spaceID = activeSpaceID()
    print("Frontmost app: \(frontApp.localizedName ?? "?") (pid \(frontApp.processIdentifier))")
    print("Active space: \(spaceID)")

    if let focused = getFocusedWindow(cgWindows: fetchCGWindowList()) {
        print("Focused window: [\(focused.id)] \(focused.name) — \(formatFrame(focused.frame))")
    } else {
        print("Could not get focused window info")
    }

    let dump = dumpWindowInfo()
    let cgWindows = fetchCGWindowList()
    let reconciled = computeReconciliation(current: [:], cgWindows: cgWindows)
    let trees = computeBSPTrees(managedWindows: reconciled, currentTrees: [:],
                                spaceID: spaceID, lastActiveSpace: 0)
    let tileFrames = tilingEnabled
        ? computeTileFrames(trees: trees, managedWindows: reconciled, spaceID: spaceID)
        : [:]

    print("\nAll on-screen windows (z-order):")
    for win in dump.windows {
        let rawSpace = spaceForWindow(win.id)
        let spaceStr = rawSpace.map { String($0) } ?? "nil"
        let layer = dump.layers[win.id] ?? 0
        let subroleStr = dump.subroles[win.id].map { " subrole=\($0)" } ?? ""

        let status: String
        if let reason = dump.excludeReasons[win.id] {
            status = "excluded: \(reason)"
        } else if dump.manageableIDs.contains(win.id) {
            if let tile = tileFrames[win.id] {
                status = "managed, tile=\(formatFrame(tile))"
            } else {
                status = "managed, not tiled"
            }
        } else {
            status = "not manageable"
        }

        print("  [\(win.id)] \(win.name) — \(formatFrame(win.frame)) layer=\(layer) space=\(spaceStr)\(subroleStr) [\(status)]")
    }
    exit(0)
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

// --- Event tap (captures input only, no data polling) ---

var globalTap: CFMachPort?

func handleEvent(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        warn("event tap re-enabled after system disable")
        if let tap = globalTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    if type == .mouseMoved {
        lastMousePosition = event.location
    } else if type == .keyDown && config.keybindings.enabled {
        let flags = event.flags
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if let direction = directionFromKeyCode(keyCode) {
            if config.keybindings.swapModifier.matches(flags) {
                pendingKeyCommands.append(PendingKeyCommand(direction: direction, swap: true))
                return nil
            } else if config.keybindings.focusModifier.matches(flags) {
                pendingKeyCommands.append(PendingKeyCommand(direction: direction, swap: false))
                return nil
            }
        }
        if keyCode == 15 && config.keybindings.swapModifier.matches(flags) { // R key
            pendingRotate = true
            return nil
        }
        if let spaceIndex = spaceIndexFromKeyCode(keyCode),
           config.keybindings.moveToSpaceModifier.matches(flags) {
            pendingMoveToSpace.append(spaceIndex)
            return nil
        }
    }

    return Unmanaged.passUnretained(event)
}

var eventMask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
if config.keybindings.enabled {
    eventMask |= CGEventMask(1 << CGEventType.keyDown.rawValue)
}

func createEventTap(eventMask: CGEventMask, maxRetries: Int = 10, baseDelay: UInt32 = 500_000) -> CFMachPort {
    for attempt in 0..<maxRetries {
        if let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: handleEvent, userInfo: nil
        ) {
            if attempt > 0 {
                log("event tap created after \(attempt + 1) attempts")
            }
            return tap
        }
        let delay = baseDelay * UInt32(1 << min(attempt, 4))
        warn("event tap failed (attempt \(attempt + 1)/\(maxRetries)), retrying...")
        usleep(delay)
    }
    warn("failed to create event tap after \(maxRetries) attempts — grant accessibility permissions")
    exit(1)
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

// Trigger an immediate tick on space change so returning to a space
// that lost a window re-tiles without waiting for the next poll.
log("running\(verbose ? " (verbose)" : "")")
CFRunLoopRun()
log("stopped")
