import Cocoa
import CoreGraphics

// --- Argument parsing ---

let knownArgs: Set<String> = ["--verbose", "-v", "--dump", "--no-tile"]
for arg in CommandLine.arguments.dropFirst() {
    if !knownArgs.contains(arg) {
        fputs("unknown argument: \(arg)\nusage: focus-follows-mouse [--verbose|-v] [--dump]\n", stderr)
        exit(1)
    }
}

let verbose = CommandLine.arguments.contains("--verbose") || CommandLine.arguments.contains("-v")
let tilingEnabled = !CommandLine.arguments.contains("--no-tile")
let config = loadConfig()

// --- Logging ---

private let logFormatter = ISO8601DateFormatter()

func log(_ message: @autoclosure () -> String) {
    guard verbose else { return }
    let ts = logFormatter.string(from: Date())
    fputs("\(ts) \(message())\n", stderr)
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
var lastMousePosition: CGPoint = .zero
var pendingMouseUp = false

// --- Focus/navigation handlers ---

func handleFocusDirection(_ direction: Direction, focused info: FocusedWindowInfo, spaceID: CGSSpaceID) {
    guard let focused = resolveManaged(for: info) else { return }
    let candidates = managedWindows.values.filter { $0.id != focused.id && $0.spaceID == spaceID }
    guard let target = nearestWindow(from: focused.frame, direction: direction, among: Array(candidates)) else { return }
    log("cmd+arrow focus: \(target.id) (\(target.name))")
    focusWindow(target)
    warpMouse(to: target.frame)
}

func handleSwapDirection(_ direction: Direction, focused info: FocusedWindowInfo, spaceID: CGSSpaceID) {
    guard tilingEnabled else { return }
    guard let focused = resolveManaged(for: info) else { return }

    let focusCenter = CGPoint(x: focused.frame.midX, y: focused.frame.midY)
    let did = displayID(for: focusCenter)
    let key = DisplaySpaceKey(displayID: did, spaceID: spaceID)
    guard let tree = bspTrees[key] else { return }
    guard let result = tree.findCrossingSplit(windowID: focused.id, direction: direction) else { return }

    if result.focusedIsAlone {
        log("cmd+shift+arrow partition swap for \(focused.id)")
        bspTrees[key] = tree.swappingChildrenForCrossing(windowID: focused.id, direction: direction) ?? tree
    } else {
        let otherWindows = result.otherSideIDs.compactMap { managedWindows[$0] }
        guard let target = nearestWindow(from: focused.frame, direction: direction, among: otherWindows) else { return }
        log("cmd+shift+arrow window swap: \(focused.id) <-> \(target.id)")
        bspTrees[key] = tree.swappingWindows(focused.id, target.id)
    }

    applyTiling(spaceID: spaceID)
    // focused.frame was updated by applyTiling -> setWindowFrame
    warpMouse(to: focused.frame)
}

// --- Mouse/focus tracking ---

var lastFocusedWindow: UInt32 = 0
var lastSelfFocusTime: UInt64 = 0
let selfFocusCooldownNs: UInt64 = 150_000_000 // 150ms

func handleMousePosition(_ pos: CGPoint, spaceID: CGSSpaceID) {
    for win in managedWindows.values where win.spaceID == spaceID {
        if win.frame.contains(pos) {
            if win.id != lastFocusedWindow {
                log("mouse focus: \(win.id) (\(win.name)) at \(Int(pos.x)),\(Int(pos.y))")
                focusWindow(win)
            }
            return
        }
    }

    // Cursor is over the desktop — unfocus by activating Finder
    if lastFocusedWindow != 0 {
        log("mouse over desktop — unfocusing")
        lastFocusedWindow = 0
        if let finder = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" }) {
            finder.activate()
        }
    }
}

func checkExternalFocusChange(focused: FocusedWindowInfo) {
    guard focused.id != lastFocusedWindow else { return }
    // Don't warp when we intentionally unfocused to the desktop
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
    // Prefer managed frame (post-tiling), fall back to AX-reported frame
    let frame = managedWindows[focused.id]?.frame ?? focused.frame
    warpMouse(to: frame)
}

// --- Debug dump ---

if CommandLine.arguments.contains("--dump") {
    fputs("Dumping in 3 seconds — switch to the window you want to inspect.\n", stderr)
    Thread.sleep(forTimeInterval: 3)
    guard let frontApp = NSWorkspace.shared.frontmostApplication else {
        fputs("no frontmost app\n", stderr); exit(1)
    }
    print("Frontmost app: \(frontApp.localizedName ?? "?") (pid \(frontApp.processIdentifier))")

    if let focused = getFocusedWindowInfo() {
        print("Focused window: [\(focused.id)] \(focused.name) — pos=\(Int(focused.frame.origin.x)),\(Int(focused.frame.origin.y)) size=\(Int(focused.frame.width))x\(Int(focused.frame.height))")
    } else {
        print("Could not get focused window info")
    }

    print("\nCG on-screen windows:")
    for win in getOnScreenWindows().managed {
        print("  [\(win.id)] \(win.name) — pos=\(Int(win.frame.origin.x)),\(Int(win.frame.origin.y)) size=\(Int(win.frame.width))x\(Int(win.frame.height))")
    }
    exit(0)
}

// --- Event tap (captures input only, no data polling) ---

var globalTap: CFMachPort?

func handleEvent(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        fputs("focus-follows-mouse: event tap re-enabled after system disable\n", stderr)
        if let tap = globalTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    if type == .mouseMoved {
        lastMousePosition = event.location
    } else if type == .leftMouseUp {
        pendingMouseUp = true
    } else if type == .keyDown {
        let flags = event.flags
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if let direction = directionFromKeyCode(keyCode) {
            let hasCmd = flags.contains(.maskCommand)
            let hasShift = flags.contains(.maskShift)
            let noOtherMods = !flags.contains(.maskControl) && !flags.contains(.maskAlternate)

            if hasCmd && noOtherMods {
                pendingKeyCommands.append(PendingKeyCommand(direction: direction, swap: hasShift))
                return nil
            }
        }
    }

    return Unmanaged.passUnretained(event)
}

let eventMask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
              | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
              | CGEventMask(1 << CGEventType.keyDown.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
    eventsOfInterest: eventMask,
    callback: handleEvent, userInfo: nil
) else {
    fputs("focus-follows-mouse: failed to create event tap. Grant accessibility permissions.\n", stderr)
    exit(1)
}

globalTap = tap
let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

// --- Main loop: snapshot once, reconcile, process all pending input ---

let pollTimer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault,
    CFAbsoluteTimeGetCurrent(), 0.05, 0, 0) { _ in
    let snapshot = getOnScreenWindows()
    let focused = getFocusedWindowInfo()
    let spaceID = activeSpaceID()

    reconcileWindows(snapshot: snapshot)

    // Process queued key commands
    let commands = pendingKeyCommands
    pendingKeyCommands.removeAll()
    if let focused = focused {
        for cmd in commands {
            if cmd.swap {
                handleSwapDirection(cmd.direction, focused: focused, spaceID: spaceID)
            } else {
                handleFocusDirection(cmd.direction, focused: focused, spaceID: spaceID)
            }
        }
    }

    // Process mouse-up snap-back
    if pendingMouseUp {
        pendingMouseUp = false
        snapBackDisplacedWindows(snapshots: snapshot.managed)
    }

    // Focus-follows-mouse
    handleMousePosition(lastMousePosition, spaceID: spaceID)

    // External focus tracking
    if let focused = focused {
        checkExternalFocusChange(focused: focused)
    }

    // Tiling
    tileWindows(spaceID: spaceID)
}
CFRunLoopAddTimer(CFRunLoopGetCurrent(), pollTimer, .commonModes)

fputs("focus-follows-mouse: running\(verbose ? " (verbose)" : "")\n", stderr)
CFRunLoopRun()
