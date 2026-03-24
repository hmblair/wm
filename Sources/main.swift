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

func warn(_ message: @autoclosure () -> String) {
    fputs("warning: \(message())\n", stderr)
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
    let candidates = managedWindows.values.filter { $0.id != managed.id && $0.spaceID == spaceID }
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

    let tileFrames = computeTileFrames(spaceID: spaceID, popupSizeByPid: [:])
    enforceTileFrames(tileFrames)
    warpMouse(to: managed.frame)
    return tileFrames
}

// --- Mouse/focus tracking ---

var lastFocusedWindow: UInt32 = 0
var lastSelfFocusTime: UInt64 = 0
private let selfFocusCooldownNs: UInt64 = 150_000_000

func handleMousePosition(_ pos: CGPoint, windows: [Window], spaceID: CGSSpaceID) {
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

    if let focused = getFocusedWindow() {
        print("Focused window: [\(focused.id)] \(focused.name) — pos=\(Int(focused.frame.origin.x)),\(Int(focused.frame.origin.y)) size=\(Int(focused.frame.width))x\(Int(focused.frame.height))")
    } else {
        print("Could not get focused window info")
    }

    let snapshot = getOnScreenWindows()
    reconcileWindows(snapshot: snapshot, activeSpaceID: spaceID)
    let tileFrames = tilingEnabled ? tileWindows(spaceID: spaceID, popupSizeByPid: snapshot.popupSizeByPid) : [:]

    let manageableIDs = Set(snapshot.manageable.map { $0.window.id })
    let manageableSpaces = Dictionary(uniqueKeysWithValues: snapshot.manageable.map { ($0.window.id, $0.spaceID) })

    print("\nAll on-screen windows (z-order):")
    for win in snapshot.windows {
        let rawSpace = spaceForWindow(win.id)
        let spaceStr = rawSpace.map { String($0) } ?? "nil"
        let layer = snapshot.layers[win.id] ?? 0

        var subroleStr = ""
        if let ax = findAXWindowByPidAndID(pid: win.pid, windowID: win.id) {
            var subroleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(ax, kAXSubroleAttribute as CFString, &subroleRef)
            subroleStr = " subrole=\(subroleRef as? String ?? "nil")"
        }

        var status: String
        if manageableIDs.contains(win.id) {
            let managed = managedWindows[win.id] != nil
            if let tile = tileFrames[win.id] {
                status = "managed, tile=\(Int(tile.origin.x)),\(Int(tile.origin.y)) \(Int(tile.width))x\(Int(tile.height))"
            } else if managed {
                let winSpace = manageableSpaces[win.id] ?? 0
                if winSpace != spaceID && winSpace != 0 {
                    status = "managed, not tiled (space \(winSpace) != active \(spaceID))"
                } else {
                    status = "managed, not tiled"
                }
            } else {
                status = "manageable, not yet managed"
            }
        } else {
            if ignoredApps.contains(win.name) {
                status = "excluded: ignored app"
            } else if findAXWindowByPidAndID(pid: win.pid, windowID: win.id) == nil {
                status = "excluded: no AX handle"
            } else {
                status = "excluded: non-standard subrole"
            }
        }

        print("  [\(win.id)] \(win.name) — pos=\(Int(win.frame.origin.x)),\(Int(win.frame.origin.y)) size=\(Int(win.frame.width))x\(Int(win.frame.height)) layer=\(layer) space=\(spaceStr)\(subroleStr) [\(status)]")
    }
    exit(0)
}

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

// --- Main loop ---

let pollTimer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault,
    CFAbsoluteTimeGetCurrent(), config.pollInterval, 0, 0) { _ in
    // 1. Observe
    let snapshot = getOnScreenWindows()
    let focused = getFocusedWindow()
    let spaceID = activeSpaceID()

    // 2. Reconcile managed windows with reality
    reconcileWindows(snapshot: snapshot, activeSpaceID: spaceID)

    // 3. Compute tile layout (rebuilds BSP if window set changed)
    var tileFrames = tileWindows(spaceID: spaceID, popupSizeByPid: snapshot.popupSizeByPid)

    // 4. Process queued key commands
    let commands = pendingKeyCommands
    pendingKeyCommands.removeAll()
    if let focused = focused {
        for cmd in commands {
            if cmd.swap {
                if let newFrames = handleSwapDirection(cmd.direction, focused: focused, spaceID: spaceID) {
                    tileFrames = newFrames
                }
            } else {
                handleFocusDirection(cmd.direction, focused: focused, spaceID: spaceID)
            }
        }
    }

    // 5. Enforce tile positions
    enforceTileFrames(tileFrames)

    // 6. Focus-follows-mouse
    handleMousePosition(lastMousePosition, windows: snapshot.windows, spaceID: spaceID)

    // 7. External focus tracking
    if let focused = focused {
        checkExternalFocusChange(focused: focused)
    }
}
CFRunLoopAddTimer(CFRunLoopGetCurrent(), pollTimer, .commonModes)

fputs("focus-follows-mouse: running\(verbose ? " (verbose)" : "")\n", stderr)
CFRunLoopRun()
