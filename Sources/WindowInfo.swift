import Cocoa
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

struct WindowInfo {
    let id: UInt32
    let pid: Int32
    let name: String
    let frame: CGRect
    let spaceID: CGSSpaceID
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
        let space = spaceForWindow(id) ?? 0
        windows.append(WindowInfo(id: id, pid: pid, name: name, frame: frame, spaceID: space))
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
