import Cocoa
import CoreGraphics
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

// --- Argument parsing ---

let knownArgs: Set<String> = ["--verbose", "-v", "--dump"]
for arg in CommandLine.arguments.dropFirst() {
    if !knownArgs.contains(arg) {
        fputs("unknown argument: \(arg)\nusage: focus-follows-mouse [--verbose|-v] [--dump]\n", stderr)
        exit(1)
    }
}

let verbose = CommandLine.arguments.contains("--verbose") || CommandLine.arguments.contains("-v")

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

    handleMouseMoved(event)
    return Unmanaged.passUnretained(event)
}

guard let tap = CGEvent.tapCreate(
    tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
    eventsOfInterest: CGEventMask(1 << CGEventType.mouseMoved.rawValue),
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
}
CFRunLoopAddTimer(CFRunLoopGetCurrent(), pollTimer, .commonModes)

fputs("focus-follows-mouse: running\(verbose ? " (verbose)" : "")\n", stderr)
CFRunLoopRun()
