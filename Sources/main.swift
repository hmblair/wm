import Cocoa
import CoreGraphics
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

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

// --- Window snapshot ---

struct WindowInfo {
    let id: UInt32
    let pid: Int32
    let name: String
    let frame: CGRect
}

struct FocusedWindowInfo {
    let id: UInt32
    let frame: CGRect
    let name: String
}

let ignoredApps: Set<String> = ["borders", "Hammerspoon", "Alfred", "Raycast"]

func getOnScreenWindows() -> [WindowInfo] {
    guard let infoList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else { return [] }

    var windows: [WindowInfo] = []
    for info in infoList {
        guard let id = info[kCGWindowNumber as String] as? UInt32,
              let pid = info[kCGWindowOwnerPID as String] as? Int32,
              let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
              let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
              let name = info[kCGWindowOwnerName as String] as? String,
              !ignoredApps.contains(name)
        else { continue }
        let frame = CGRect(
            x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
        )
        if frame.width < 50 || frame.height < 50 { continue }
        windows.append(WindowInfo(id: id, pid: pid, name: name, frame: frame))
    }
    return windows
}

func getFocusedWindowInfo() -> FocusedWindowInfo? {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
    let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

    var focusedRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
          let ref = focusedRef
    else { return nil }
    let axWindow = ref as! AXUIElement

    var windowID: CGWindowID = 0
    _ = _AXUIElementGetWindow(axWindow, &windowID)

    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let pRef = posRef, let sRef = sizeRef
    else { return nil }

    var pos = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(pRef as! AXValue, .cgPoint, &pos)
    AXValueGetValue(sRef as! AXValue, .cgSize, &size)

    return FocusedWindowInfo(id: windowID, frame: CGRect(origin: pos, size: size), name: frontApp.localizedName ?? "unknown")
}

// --- AX window operations ---

func findAXWindow(for win: WindowInfo) -> AXUIElement? {
    let app = AXUIElementCreateApplication(win.pid)
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let axWindows = windowsRef as? [AXUIElement] else { return nil }

    for axWindow in axWindows {
        var windowID: CGWindowID = 0
        _ = _AXUIElementGetWindow(axWindow, &windowID)
        if windowID == win.id { return axWindow }
    }
    return nil
}

func focusWindow(_ win: WindowInfo) {
    if let runningApp = NSRunningApplication(processIdentifier: win.pid) {
        runningApp.activate()
    }

    guard let axWindow = findAXWindow(for: win) else {
        log("AX window not found for CG window \(win.id) (\(win.name))")
        return
    }

    AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
}

func setWindowFrame(_ win: WindowInfo, frame: CGRect) {
    guard let axWindow = findAXWindow(for: win) else {
        log("setWindowFrame: AX window not found for \(win.id) (\(win.name))")
        return
    }

    var position = frame.origin
    var size = CGSize(width: frame.width, height: frame.height)
    if let posValue = AXValueCreate(.cgPoint, &position) {
        AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)
    }
    if let sizeValue = AXValueCreate(.cgSize, &size) {
        AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
    }
}

func warpMouse(to frame: CGRect) {
    let center = CGPoint(x: frame.midX, y: frame.midY)
    log("warp mouse to \(Int(center.x)),\(Int(center.y))")
    CGWarpMouseCursorPosition(center)
}

// --- Screen utilities ---

func displayID(for point: CGPoint) -> CGDirectDisplayID {
    var displayID: CGDirectDisplayID = 0
    var count: UInt32 = 0
    CGGetDisplaysWithPoint(point, 1, &displayID, &count)
    return count > 0 ? displayID : CGMainDisplayID()
}

func displayIDForScreen(_ screen: NSScreen) -> CGDirectDisplayID {
    return screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
}

func visibleFrame(for screen: NSScreen) -> CGRect {
    let full = screen.frame
    let visible = screen.visibleFrame
    let y = full.height - visible.maxY
    return CGRect(x: visible.minX, y: y, width: visible.width, height: visible.height)
}

func screenForDisplayID(_ did: CGDirectDisplayID) -> NSScreen? {
    return NSScreen.screens.first(where: { displayIDForScreen($0) == did })
}

// --- BSP tiling ---

let tileGap: CGFloat = 8

indirect enum BSPTree {
    case leaf(id: UInt32)
    case split(left: BSPTree, right: BSPTree, vertical: Bool)

    var windowIDs: [UInt32] {
        switch self {
        case .leaf(let id): return [id]
        case .split(let l, let r, _): return l.windowIDs + r.windowIDs
        }
    }

    func contains(id: UInt32) -> Bool {
        switch self {
        case .leaf(let wid): return wid == id
        case .split(let l, let r, _): return l.contains(id: id) || r.contains(id: id)
        }
    }

    func computeFrames(rect: CGRect) -> [(UInt32, CGRect)] {
        switch self {
        case .leaf(let id):
            return [(id, CGRect(x: rect.minX + tileGap, y: rect.minY + tileGap,
                                width: rect.width - 2 * tileGap, height: rect.height - 2 * tileGap))]
        case .split(let left, let right, let vertical):
            let (leftRect, rightRect): (CGRect, CGRect)
            if vertical {
                let halfW = rect.width / 2
                leftRect = CGRect(x: rect.minX, y: rect.minY, width: halfW, height: rect.height)
                rightRect = CGRect(x: rect.minX + halfW, y: rect.minY, width: halfW, height: rect.height)
            } else {
                let halfH = rect.height / 2
                leftRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: halfH)
                rightRect = CGRect(x: rect.minX, y: rect.minY + halfH, width: rect.width, height: halfH)
            }
            return left.computeFrames(rect: leftRect) + right.computeFrames(rect: rightRect)
        }
    }

    func swappingWindows(_ id1: UInt32, _ id2: UInt32) -> BSPTree {
        switch self {
        case .leaf(let id):
            if id == id1 { return .leaf(id: id2) }
            if id == id2 { return .leaf(id: id1) }
            return self
        case .split(let l, let r, let v):
            return .split(left: l.swappingWindows(id1, id2),
                          right: r.swappingWindows(id1, id2), vertical: v)
        }
    }

    struct CrossingResult {
        let focusedIsAlone: Bool
        let otherSideIDs: [UInt32]
    }

    func findCrossingSplit(windowID: UInt32, direction: Direction) -> CrossingResult? {
        guard case .split(let left, let right, let vertical) = self else { return nil }

        let inLeft = left.contains(id: windowID)
        guard inLeft || right.contains(id: windowID) else { return nil }

        let child = inLeft ? left : right
        if let deeper = child.findCrossingSplit(windowID: windowID, direction: direction) {
            return deeper
        }

        let crosses: Bool
        switch direction {
        case .right: crosses = vertical && inLeft
        case .left:  crosses = vertical && !inLeft
        case .down:  crosses = !vertical && inLeft
        case .up:    crosses = !vertical && !inLeft
        }
        guard crosses else { return nil }

        let mySide = inLeft ? left : right
        let otherSide = inLeft ? right : left
        let isAlone: Bool
        if case .leaf = mySide { isAlone = true } else { isAlone = false }

        return CrossingResult(focusedIsAlone: isAlone, otherSideIDs: otherSide.windowIDs)
    }

    func swappingChildrenForCrossing(windowID: UInt32, direction: Direction) -> BSPTree? {
        guard case .split(let left, let right, let vertical) = self else { return nil }

        let inLeft = left.contains(id: windowID)
        guard inLeft || right.contains(id: windowID) else { return nil }

        if inLeft {
            if let newLeft = left.swappingChildrenForCrossing(windowID: windowID, direction: direction) {
                return .split(left: newLeft, right: right, vertical: vertical)
            }
        } else {
            if let newRight = right.swappingChildrenForCrossing(windowID: windowID, direction: direction) {
                return .split(left: left, right: newRight, vertical: vertical)
            }
        }

        let crosses: Bool
        switch direction {
        case .right: crosses = vertical && inLeft
        case .left:  crosses = vertical && !inLeft
        case .down:  crosses = !vertical && inLeft
        case .up:    crosses = !vertical && !inLeft
        }

        if crosses {
            return .split(left: right, right: left, vertical: vertical)
        }
        return nil
    }
}

func buildBSPTree(windowIDs: [UInt32], splitVertical: Bool) -> BSPTree? {
    guard !windowIDs.isEmpty else { return nil }
    if windowIDs.count == 1 { return .leaf(id: windowIDs[0]) }
    let mid = (windowIDs.count + 1) / 2
    return .split(
        left: buildBSPTree(windowIDs: Array(windowIDs[..<mid]), splitVertical: !splitVertical)!,
        right: buildBSPTree(windowIDs: Array(windowIDs[mid...]), splitVertical: !splitVertical)!,
        vertical: splitVertical
    )
}

// --- Tiling state and logic ---

var bspTrees: [CGDirectDisplayID: BSPTree] = [:]
var lastTiledFrames: [UInt32: CGRect] = [:]

func applyTiling(windows: [WindowInfo]) {
    let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })

    lastTiledFrames.removeAll()
    for (did, tree) in bspTrees {
        guard let screen = screenForDisplayID(did) else { continue }
        let rect = visibleFrame(for: screen)
        let frames = tree.computeFrames(rect: rect)
        for (id, frame) in frames {
            if let win = windowsByID[id] {
                setWindowFrame(win, frame: frame)
            }
            lastTiledFrames[id] = frame
        }
    }
}

func tileWindows(windows: [WindowInfo]) {
    guard tilingEnabled else { return }

    // Group windows by display using Quartz coordinates
    var windowsByDisplay: [CGDirectDisplayID: [WindowInfo]] = [:]
    for win in windows {
        let center = CGPoint(x: win.frame.midX, y: win.frame.midY)
        let did = displayID(for: center)
        windowsByDisplay[did, default: []].append(win)
    }

    let allDisplayIDs = Set(windowsByDisplay.keys).union(bspTrees.keys)
    var changed = false

    for did in allDisplayIDs {
        let screenWindows = windowsByDisplay[did] ?? []
        let currentIDs = Set(screenWindows.map { $0.id })
        let treeIDs = Set(bspTrees[did]?.windowIDs ?? [])

        guard currentIDs != treeIDs else { continue }
        changed = true

        if screenWindows.isEmpty {
            bspTrees.removeValue(forKey: did)
            continue
        }

        var orderedIDs: [UInt32] = []
        if let existingTree = bspTrees[did] {
            orderedIDs = existingTree.windowIDs.filter { currentIDs.contains($0) }
        }
        for win in screenWindows where !orderedIDs.contains(win.id) {
            orderedIDs.append(win.id)
        }

        bspTrees[did] = buildBSPTree(windowIDs: orderedIDs, splitVertical: true)
    }

    if changed {
        log("re-tiling \(windows.count) windows across \(windowsByDisplay.count) screens")
        applyTiling(windows: windows)
    }
}

func snapBackDisplacedWindows(windows: [WindowInfo]) {
    guard tilingEnabled else { return }
    for win in windows {
        guard let expected = lastTiledFrames[win.id] else { continue }
        if abs(win.frame.origin.x - expected.origin.x) > 2
            || abs(win.frame.origin.y - expected.origin.y) > 2
            || abs(win.frame.width - expected.width) > 2
            || abs(win.frame.height - expected.height) > 2 {
            log("snapping back \(win.id) (\(win.name))")
            setWindowFrame(win, frame: expected)
        }
    }
}

// --- Direction + keyboard navigation ---

enum Direction { case left, right, up, down }

func directionFromKeyCode(_ keyCode: UInt16) -> Direction? {
    switch keyCode {
    case 123: return .left
    case 124: return .right
    case 125: return .down
    case 126: return .up
    default: return nil
    }
}

func nearestWindow(from source: CGRect, direction: Direction, among windows: [WindowInfo]) -> WindowInfo? {
    let center = CGPoint(x: source.midX, y: source.midY)
    var best: WindowInfo?
    var bestDist = CGFloat.infinity

    for win in windows {
        let wc = CGPoint(x: win.frame.midX, y: win.frame.midY)
        let dx = wc.x - center.x
        let dy = wc.y - center.y

        let inDirection: Bool
        switch direction {
        case .left:  inDirection = dx < -10
        case .right: inDirection = dx > 10
        case .up:    inDirection = dy < -10
        case .down:  inDirection = dy > 10
        }
        guard inDirection else { continue }

        let dist = dx * dx + dy * dy
        if dist < bestDist {
            bestDist = dist
            best = win
        }
    }
    return best
}

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

    // Snapshot once per event
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
