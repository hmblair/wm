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

func log(_ message: @autoclosure () -> String) {
    guard verbose else { return }
    let ts = ISO8601DateFormatter().string(from: Date())
    fputs("\(ts) \(message())\n", stderr)
}

// --- Window lookup ---

let ignoredApps: Set<String> = ["borders", "Hammerspoon", "Alfred", "Raycast"]

struct WindowInfo {
    let id: UInt32
    let pid: Int32
    let name: String
    let frame: CGRect
}

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

// --- Focus via Accessibility API ---

func focusWindow(_ win: WindowInfo) {
    let app = AXUIElementCreateApplication(win.pid)

    if let runningApp = NSRunningApplication(processIdentifier: win.pid) {
        runningApp.activate()
    }

    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let axWindows = windowsRef as? [AXUIElement] else {
        log("failed to get AX windows for pid \(win.pid) (\(win.name))")
        return
    }

    for axWindow in axWindows {
        var windowID: CGWindowID = 0
        _ = _AXUIElementGetWindow(axWindow, &windowID)
        if windowID == win.id {
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            return
        }
    }
    log("AX window not found for CG window \(win.id) (\(win.name))")
}

// --- Focused window via Accessibility API ---

func getFocusedWindowInfo() -> (id: UInt32, frame: CGRect, name: String)? {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
    let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

    var focusedRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success
    else { return nil }

    let axWindow = focusedRef as! AXUIElement

    var windowID: CGWindowID = 0
    _ = _AXUIElementGetWindow(axWindow, &windowID)

    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success
    else { return nil }

    var pos = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
    AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

    return (id: windowID, frame: CGRect(origin: pos, size: size), name: frontApp.localizedName ?? "unknown")
}

// --- Mouse warp ---

func warpMouse(to frame: CGRect) {
    let center = CGPoint(x: frame.midX, y: frame.midY)
    log("warp mouse to \(Int(center.x)),\(Int(center.y))")
    CGWarpMouseCursorPosition(center)
}

// --- Elapsed time helper ---

func elapsedNsSince(_ timestamp: UInt64) -> UInt64 {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return (mach_absolute_time() - timestamp) * UInt64(info.numer) / UInt64(info.denom)
}

// --- Window frame manipulation ---

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

// --- BSP tiling ---

let tileGap: CGFloat = 8

func visibleFrame(for screen: NSScreen) -> CGRect {
    let full = screen.frame
    let visible = screen.visibleFrame
    // Convert from NSScreen (bottom-left origin) to CG (top-left origin)
    let y = full.height - visible.maxY
    return CGRect(x: visible.minX, y: y, width: visible.width, height: visible.height)
}

func bspLayout(windows: Int, rect: CGRect, splitVertical: Bool) -> [CGRect] {
    guard windows > 0 else { return [] }
    if windows == 1 {
        return [CGRect(
            x: rect.minX + tileGap,
            y: rect.minY + tileGap,
            width: rect.width - 2 * tileGap,
            height: rect.height - 2 * tileGap
        )]
    }

    let leftCount = (windows + 1) / 2
    let rightCount = windows / 2

    var leftRect: CGRect
    var rightRect: CGRect

    if splitVertical {
        let halfW = rect.width / 2
        leftRect = CGRect(x: rect.minX, y: rect.minY, width: halfW, height: rect.height)
        rightRect = CGRect(x: rect.minX + halfW, y: rect.minY, width: halfW, height: rect.height)
    } else {
        let halfH = rect.height / 2
        leftRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: halfH)
        rightRect = CGRect(x: rect.minX, y: rect.minY + halfH, width: rect.width, height: halfH)
    }

    return bspLayout(windows: leftCount, rect: leftRect, splitVertical: !splitVertical)
         + bspLayout(windows: rightCount, rect: rightRect, splitVertical: !splitVertical)
}

func screenForWindow(_ win: WindowInfo) -> NSScreen? {
    let center = CGPoint(x: win.frame.midX, y: win.frame.midY)
    for screen in NSScreen.screens {
        let full = screen.frame
        // Convert screen frame to CG coordinates
        let cgFrame = CGRect(x: full.minX, y: NSScreen.screens[0].frame.height - full.maxY,
                             width: full.width, height: full.height)
        if cgFrame.contains(center) { return screen }
    }
    return NSScreen.main
}

var lastTiledWindowIDs: Set<UInt32> = []
var lastTiledFrames: [UInt32: CGRect] = [:]

func tileWindows() {
    guard tilingEnabled else { return }
    let windows = getOnScreenWindows()
    let currentIDs = Set(windows.map { $0.id })

    guard currentIDs != lastTiledWindowIDs else { return }
    lastTiledWindowIDs = currentIDs
    lastTiledFrames.removeAll()
    log("re-tiling \(windows.count) windows")

    var byScreen: [NSScreen: [WindowInfo]] = [:]
    for win in windows {
        let screen = screenForWindow(win) ?? NSScreen.main!
        byScreen[screen, default: []].append(win)
    }

    for (screen, screenWindows) in byScreen {
        let rect = visibleFrame(for: screen)
        let frames = bspLayout(windows: screenWindows.count, rect: rect, splitVertical: true)
        for (win, frame) in zip(screenWindows, frames) {
            setWindowFrame(win, frame: frame)
            lastTiledFrames[win.id] = frame
        }
    }
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

// --- State ---

var lastFocusedWindow: UInt32 = 0
var lastSelfFocusTime: UInt64 = 0
let selfFocusCooldownNs: UInt64 = 150_000_000 // 150ms

// --- Mouse movement handler ---

func handleMouseMoved(_ event: CGEvent) {
    let pos = event.location
    let windows = getOnScreenWindows()

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

// --- Poll for external focus changes ---

func checkExternalFocusChange() {
    guard let focused = getFocusedWindowInfo() else { return }
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

// --- Snap back displaced windows ---

func snapBackDisplacedWindows() {
    guard tilingEnabled else { return }
    for win in getOnScreenWindows() {
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

// --- Keyboard-driven focus and swap ---

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

func handleFocusDirection(_ direction: Direction) {
    guard let focused = getFocusedWindowInfo() else { return }
    let windows = getOnScreenWindows().filter { $0.id != focused.id }
    guard let target = nearestWindow(from: focused.frame, direction: direction, among: windows) else { return }
    log("cmd+arrow focus: \(target.id) (\(target.name))")
    lastFocusedWindow = target.id
    lastSelfFocusTime = mach_absolute_time()
    focusWindow(target)
    warpMouse(to: target.frame)
}

func handleSwapDirection(_ direction: Direction) {
    guard tilingEnabled else { return }
    guard let focused = getFocusedWindowInfo() else { return }
    let windows = getOnScreenWindows()
    let others = windows.filter { $0.id != focused.id }
    guard let target = nearestWindow(from: focused.frame, direction: direction, among: others) else { return }

    guard let focusedFrame = lastTiledFrames[focused.id],
          let targetFrame = lastTiledFrames[target.id] else { return }

    log("cmd+shift+arrow swap: \(focused.id) <-> \(target.id)")

    let focusedWin = windows.first { $0.id == focused.id }!
    let targetWin = target

    setWindowFrame(focusedWin, frame: targetFrame)
    setWindowFrame(targetWin, frame: focusedFrame)
    lastTiledFrames[focused.id] = targetFrame
    lastTiledFrames[target.id] = focusedFrame

    warpMouse(to: targetFrame)
}

// --- Event tap ---

var globalTap: CFMachPort?

func handleEvent(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        fputs("focus-follows-mouse: event tap re-enabled after system disable\n", stderr)
        if let tap = globalTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    if type == .keyDown {
        let flags = event.flags
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if let direction = directionFromKeyCode(keyCode) {
            let hasCmd = flags.contains(.maskCommand)
            let hasShift = flags.contains(.maskShift)
            let noOtherMods = !flags.contains(.maskControl) && !flags.contains(.maskAlternate)

            if hasCmd && !hasShift && noOtherMods {
                handleFocusDirection(direction)
                return nil
            }
            if hasCmd && hasShift && noOtherMods {
                handleSwapDirection(direction)
                return nil
            }
        }
    }

    if type == .leftMouseUp {
        snapBackDisplacedWindows()
    } else if type == .mouseMoved {
        handleMouseMoved(event)
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
    checkExternalFocusChange()
    tileWindows()
}
CFRunLoopAddTimer(CFRunLoopGetCurrent(), pollTimer, .commonModes)

fputs("focus-follows-mouse: running\(verbose ? " (verbose)" : "")\n", stderr)
CFRunLoopRun()
