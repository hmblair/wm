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

// --- Focus/navigation handlers ---

func handleFocusDirection(_ direction: Direction, focused: FocusedWindowInfo, windows: [WindowInfo]) {
    let candidates = windows.filter { $0.id != focused.id }
    guard let target = nearestWindow(from: focused.frame, direction: direction, among: candidates) else { return }
    log("cmd+arrow focus: \(target.id) (\(target.name))")
    lastFocusedWindow = target.id
    lastSelfFocusTime = mach_absolute_time()
    focusWindow(target)
    warpMouse(to: target.frame)
}

func handleSwapDirection(_ direction: Direction, focused: FocusedWindowInfo, windows: [WindowInfo]) {
    guard tilingEnabled else { return }

    let focusCenter = CGPoint(x: focused.frame.midX, y: focused.frame.midY)
    let did = displayID(for: focusCenter)
    guard let tree = bspTrees[did] else { return }
    guard let result = tree.findCrossingSplit(windowID: focused.id, direction: direction) else { return }

    if result.focusedIsAlone {
        log("cmd+shift+arrow partition swap for \(focused.id)")
        bspTrees[did] = tree.swappingChildrenForCrossing(windowID: focused.id, direction: direction) ?? tree
    } else {
        let otherWindows = windows.filter { result.otherSideIDs.contains($0.id) }
        guard let target = nearestWindow(from: focused.frame, direction: direction, among: otherWindows) else { return }
        log("cmd+shift+arrow window swap: \(focused.id) <-> \(target.id)")
        bspTrees[did] = tree.swappingWindows(focused.id, target.id)
    }

    applyTiling(windows: windows)
    if let newFrame = lastTiledFrames[focused.id] {
        warpMouse(to: newFrame)
    }
}

// --- Mouse/focus tracking ---

var lastFocusedWindow: UInt32 = 0
var lastSelfFocusTime: UInt64 = 0
let selfFocusCooldownNs: UInt64 = 150_000_000 // 150ms

func handleMouseMoved(_ event: CGEvent, windows: [WindowInfo]) {
    let pos = event.location

    for win in windows {
        if win.frame.contains(pos) {
            if win.id != lastFocusedWindow {
                log("mouse focus: \(win.id) (\(win.name)) at \(Int(pos.x)),\(Int(pos.y))")
                lastFocusedWindow = win.id
                lastSelfFocusTime = mach_absolute_time()
                focusWindow(win)
            }
            break
        }
    }
}

func checkExternalFocusChange(focused: FocusedWindowInfo) {
    guard focused.id != lastFocusedWindow else { return }

    if elapsedNsSince(lastSelfFocusTime) < selfFocusCooldownNs {
        log("external focus change to \(focused.id), but within cooldown — updating state only")
        lastFocusedWindow = focused.id
        return
    }

    log("external focus change: warp to \(focused.id) (\(focused.name))")
    lastFocusedWindow = focused.id
    warpMouse(to: focused.frame)
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
    for win in getOnScreenWindows() {
        print("  [\(win.id)] \(win.name) — pos=\(Int(win.frame.origin.x)),\(Int(win.frame.origin.y)) size=\(Int(win.frame.width))x\(Int(win.frame.height))")
    }
    exit(0)
}

// --- Event tap + run loop ---

var globalTap: CFMachPort?

func handleEvent(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        fputs("focus-follows-mouse: event tap re-enabled after system disable\n", stderr)
        if let tap = globalTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    let windows = getOnScreenWindows()

    if type == .keyDown {
        let flags = event.flags
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if let direction = directionFromKeyCode(keyCode) {
            let hasCmd = flags.contains(.maskCommand)
            let hasShift = flags.contains(.maskShift)
            let noOtherMods = !flags.contains(.maskControl) && !flags.contains(.maskAlternate)

            if hasCmd && noOtherMods, let focused = getFocusedWindowInfo() {
                if !hasShift {
                    handleFocusDirection(direction, focused: focused, windows: windows)
                } else {
                    handleSwapDirection(direction, focused: focused, windows: windows)
                }
                return nil
            }
        }
    }

    if type == .leftMouseUp {
        snapBackDisplacedWindows(windows: windows)
    } else if type == .mouseMoved {
        handleMouseMoved(event, windows: windows)
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

let pollTimer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault,
    CFAbsoluteTimeGetCurrent(), 0.05, 0, 0) { _ in
    let windows = getOnScreenWindows()
    if let focused = getFocusedWindowInfo() {
        checkExternalFocusChange(focused: focused)
    }
    tileWindows(windows: windows)
}
CFRunLoopAddTimer(CFRunLoopGetCurrent(), pollTimer, .commonModes)

fputs("focus-follows-mouse: running\(verbose ? " (verbose)" : "")\n", stderr)
CFRunLoopRun()
