import Cocoa
import CoreGraphics
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

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

    // Activate the application
    if let runningApp = NSRunningApplication(processIdentifier: win.pid) {
        runningApp.activate()
    }

    // Find the AXWindow matching our CG window ID and raise it
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let axWindows = windowsRef as? [AXUIElement] else { return }

    for axWindow in axWindows {
        var windowID: CGWindowID = 0
        _ = _AXUIElementGetWindow(axWindow, &windowID)
        if windowID == win.id {
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            break
        }
    }
}

// --- Mouse warp ---

func warpMouse(to frame: CGRect) {
    let center = CGPoint(x: frame.midX, y: frame.midY)
    CGWarpMouseCursorPosition(center)
}

// --- State ---

var lastFocusedWindow: UInt32 = 0
var selfTriggered = false

func frontmostWindowID() -> UInt32? {
    return getOnScreenWindows().first?.id
}

// --- Event tap ---

func handleEvent(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = globalTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    if type == .mouseMoved {
        let pos = event.location
        let windows = getOnScreenWindows()

        for win in windows {
            if win.frame.contains(pos) {
                if win.id != lastFocusedWindow {
                    selfTriggered = true
                    lastFocusedWindow = win.id
                    focusWindow(win)
                }
                break
            }
        }
    }

    if type == .keyDown {
        // After a key press, check if focus changed externally
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let front = frontmostWindowID(), front != lastFocusedWindow else { return }
            let shouldWarp = !selfTriggered
            selfTriggered = false
            lastFocusedWindow = front
            if shouldWarp {
                let windows = getOnScreenWindows()
                if let win = windows.first(where: { $0.id == front }) {
                    warpMouse(to: win.frame)
                }
            }
        }
    }

    return Unmanaged.passUnretained(event)
}

var globalTap: CFMachPort?

let eventMask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
    | CGEventMask(1 << CGEventType.keyDown.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
    eventsOfInterest: eventMask, callback: handleEvent, userInfo: nil
) else {
    fputs("Failed to create event tap. Grant accessibility permissions to this binary.\n", stderr)
    exit(1)
}

globalTap = tap
let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
fputs("focus-follows-mouse: running\n", stderr)
CFRunLoopRun()
