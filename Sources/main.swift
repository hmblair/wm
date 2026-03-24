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

let verbose = CommandLine.arguments.contains("--verbose") || CommandLine.arguments.contains("-v")
let tilingEnabled = !CommandLine.arguments.contains("--no-tile")
let config = loadConfig()
ignoredApps = Set(config.ignoredApps)
excludedApps = Set(config.excludedApps)

// --- Logging ---

private let logger = Logger(subsystem: "com.hmblair.focus-follows-mouse", category: "general")

func log(_ message: @autoclosure () -> String) {
    guard verbose else { return }
    let msg = message()
    logger.debug("\(msg, privacy: .public)")
}

func warn(_ message: @autoclosure () -> String) {
    let msg = message()
    logger.warning("\(msg, privacy: .public)")
}

func info(_ message: @autoclosure () -> String) {
    let msg = message()
    logger.info("\(msg, privacy: .public)")
}

// --- Time utilities ---

private let machTimebaseInfo: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

func elapsedNsSince(_ timestamp: UInt64) -> UInt64 {
    return (mach_absolute_time() - timestamp) * UInt64(machTimebaseInfo.numer) / UInt64(machTimebaseInfo.denom)
}

// --- Pending input state (written by event tap, consumed by poll loop) ---

struct PendingKeyCommand {
    let direction: Direction
    let swap: Bool
}

var pendingKeyCommands: [PendingKeyCommand] = []
var lastMousePosition: CGPoint = {
    let nsPos = NSEvent.mouseLocation
    let screenHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGPoint(x: nsPos.x, y: screenHeight - nsPos.y)
}()

// --- Focus/navigation handlers ---

func handleFocusDirection(_ direction: Direction, focused: Window, spaceID: CGSSpaceID) {
    guard let managed = resolveManaged(for: focused) else { return }
    let candidates = managedWindows.values.filter { $0.id != managed.id }
    guard let target = nearestWindow(from: managed.frame, direction: direction, among: Array(candidates)) else { return }
    log("cmd+arrow focus: \(target.id) (\(target.name))")
    focusWindow(target)
    warpMouse(to: target.frame)
}

func handleSwapDirection(_ direction: Direction, focused: Window, spaceID: CGSSpaceID) -> [UInt32: CGRect]? {
    guard tilingEnabled else { return nil }
    guard let managed = resolveManaged(for: focused) else { return nil }

    let focusCenter = CGPoint(x: managed.frame.midX, y: managed.frame.midY)
    let did = displayID(for: focusCenter)
    let key = DisplaySpaceKey(displayID: did, spaceID: spaceID)
    guard let tree = bspTrees[key] else { return nil }
    guard let result = tree.findCrossingSplit(windowID: managed.id, direction: direction) else { return nil }

    if result.focusedIsAlone {
        log("cmd+shift+arrow partition swap for \(managed.id)")
        bspTrees[key] = tree.swappingChildrenForCrossing(windowID: managed.id, direction: direction) ?? tree
    } else {
        let otherWindows = result.otherSideIDs.compactMap { managedWindows[$0] }
        guard let target = nearestWindow(from: managed.frame, direction: direction, among: otherWindows) else { return nil }
        log("cmd+shift+arrow window swap: \(managed.id) <-> \(target.id)")
        bspTrees[key] = tree.swappingWindows(managed.id, target.id)
    }

    let tileFrames = computeTileFrames(spaceID: spaceID)
    enforceTileFrames(tileFrames)
    warpMouse(to: managed.frame)
    return tileFrames
}

// --- Mouse/focus tracking ---

var lastFocusedWindow: UInt32 = 0
var lastSelfFocusTime: UInt64 = 0
private let selfFocusCooldownNs: UInt64 = 150_000_000

func handleMousePosition(_ pos: CGPoint, windows: [Window]) {
    for win in windows {
        guard win.frame.contains(pos) else { continue }

        if let managed = managedWindows[win.id] {
            if managed.id != lastFocusedWindow {
                log("mouse focus: \(managed.id) (\(managed.name)) at \(Int(pos.x)),\(Int(pos.y))")
                focusWindow(managed)
            }
        } else {
            if let app = NSRunningApplication(processIdentifier: win.pid) {
                if !app.isActive {
                    log("mouse focus: \(win.id) (pid \(win.pid)) at \(Int(pos.x)),\(Int(pos.y))")
                    app.activate()
                }
                lastFocusedWindow = 0
            }
        }
        return
    }

    if lastFocusedWindow != 0 {
        log("mouse over desktop — unfocusing")
        lastFocusedWindow = 0
        if let finder = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" }) {
            finder.activate()
        }
    }
}

func checkExternalFocusChange(focused: Window) {
    guard focused.id != lastFocusedWindow else { return }
    guard lastFocusedWindow != 0 else {
        lastFocusedWindow = focused.id
        return
    }

    if elapsedNsSince(lastSelfFocusTime) < selfFocusCooldownNs {
        log("external focus change to \(focused.id), but within cooldown — updating state only")
        lastFocusedWindow = focused.id
        return
    }

    log("external focus change: warp to \(focused.id) (\(focused.name))")
    lastFocusedWindow = focused.id
    let frame = managedWindows[focused.id]?.frame ?? focused.frame
    warpMouse(to: frame)
}

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
    reconcileWindows(cgWindows: fetchCGWindowList())
    let tileFrames = tilingEnabled ? tileWindows(spaceID: spaceID) : [:]

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
        info("received signal \(sig), shutting down")
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
                info("event tap created after \(attempt + 1) attempts")
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

// --- Main loop ---

let pollTimer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault,
    CFAbsoluteTimeGetCurrent(), config.pollInterval, 0, 0) { _ in
    let tick = TickState()

    // 1. Reconcile managed windows with reality (AX lookups only for new windows)
    reconcileWindows(cgWindows: tick.cgWindows)

    // 2. Compute tile layout (rebuilds BSP if window set changed)
    var tileFrames = tileWindows(spaceID: tick.spaceID)

    // 3. Process queued key commands (accesses tick.focusedWindow only if commands pending)
    let commands = pendingKeyCommands
    pendingKeyCommands.removeAll()
    if !commands.isEmpty, let focused = tick.focusedWindow {
        for cmd in commands {
            if cmd.swap {
                if let newFrames = handleSwapDirection(cmd.direction, focused: focused, spaceID: tick.spaceID) {
                    tileFrames = newFrames
                }
            } else {
                handleFocusDirection(cmd.direction, focused: focused, spaceID: tick.spaceID)
            }
        }
    }

    // 4. Enforce tile positions
    enforceTileFrames(tileFrames)

    // 5. Focus-follows-mouse
    handleMousePosition(lastMousePosition, windows: tick.windows)

    // 6. External focus tracking
    if let focused = tick.focusedWindow {
        checkExternalFocusChange(focused: focused)
    }
}
CFRunLoopAddTimer(CFRunLoopGetCurrent(), pollTimer, .commonModes)

info("running\(verbose ? " (verbose)" : "")")
CFRunLoopRun()
info("stopped")
