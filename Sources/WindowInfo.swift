import Cocoa
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

struct Window {
    let id: UInt32
    let pid: Int32
    let name: String
    let frame: CGRect
}

func formatFrame(_ f: CGRect) -> String {
    return "\(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))"
}

let ignoredApps: Set<String> = ["borders", "Hammerspoon", "Alfred", "Raycast"]

struct ManagedWindowInfo {
    let window: Window
    let spaceID: CGSSpaceID
    let axWindow: AXUIElement
}

struct OnScreenSnapshot {
    let windows: [Window]
    let manageable: [ManagedWindowInfo]
    let layers: [UInt32: Int]
    let subroles: [UInt32: String]
    let excludeReasons: [UInt32: String]
}

func getOnScreenWindows() -> OnScreenSnapshot {
    guard let infoList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else {
        return OnScreenSnapshot(windows: [], manageable: [], layers: [:], subroles: [:], excludeReasons: [:])
    }

    let manageableLayers: Set<Int> = [0, 1000]
    var allWindows: [Window] = []
    var manageable: [ManagedWindowInfo] = []
    var layers: [UInt32: Int] = [:]
    var subroles: [UInt32: String] = [:]
    var excludeReasons: [UInt32: String] = [:]

    for info in infoList {
        guard let id = info[kCGWindowNumber as String] as? UInt32,
              let pid = info[kCGWindowOwnerPID as String] as? Int32,
              let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
              let layer = info[kCGWindowLayer as String] as? Int,
              let name = info[kCGWindowOwnerName as String] as? String,
              !ignoredApps.contains(name)
        else { continue }
        let frame = CGRect(
            x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
        )
        let win = Window(id: id, pid: pid, name: name, frame: frame)
        allWindows.append(win)
        layers[id] = layer

        guard manageableLayers.contains(layer) else { continue }
        guard let axWindow = findAXWindowByPidAndID(pid: pid, windowID: id) else {
            excludeReasons[id] = "no AX handle"
            continue
        }
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = subroleRef as? String ?? "nil"
        subroles[id] = subrole
        guard subrole == kAXStandardWindowSubrole as String else {
            excludeReasons[id] = "subrole: \(subrole)"
            continue
        }
        var fullScreenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString, &fullScreenRef) == .success,
           let isFullScreen = fullScreenRef as? Bool, isFullScreen {
            excludeReasons[id] = "full screen"
            continue
        }
        let space = spaceForWindow(id) ?? 0
        manageable.append(ManagedWindowInfo(window: win, spaceID: space, axWindow: axWindow))
    }

    return OnScreenSnapshot(windows: allWindows, manageable: manageable,
                            layers: layers, subroles: subroles, excludeReasons: excludeReasons)
}

func getFocusedWindow() -> Window? {
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

    return Window(id: windowID, pid: frontApp.processIdentifier, name: frontApp.localizedName ?? "unknown", frame: CGRect(origin: pos, size: size))
}

func findAXWindowByPidAndID(pid: Int32, windowID: UInt32) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let axWindows = windowsRef as? [AXUIElement] else { return nil }

    for axWindow in axWindows {
        var wid: CGWindowID = 0
        _ = _AXUIElementGetWindow(axWindow, &wid)
        if wid == windowID { return axWindow }
    }
    return nil
}
