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

var ignoredApps: Set<String> = []
var excludedApps: Set<String> = []
let manageableLayers: Set<Int> = [0, 1000]

struct CGWindowEntry {
    let id: UInt32
    let pid: Int32
    let name: String
    let frame: CGRect
    let layer: Int
}

func fetchCGWindowList() -> [CGWindowEntry] {
    guard let infoList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else {
        return []
    }

    var entries: [CGWindowEntry] = []
    for info in infoList {
        guard let id = info[kCGWindowNumber as String] as? UInt32,
              let pid = info[kCGWindowOwnerPID as String] as? Int32,
              let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
              let layer = info[kCGWindowLayer as String] as? Int,
              let name = info[kCGWindowOwnerName as String] as? String
        else { continue }
        let frame = CGRect(
            x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
        )
        entries.append(CGWindowEntry(id: id, pid: pid, name: name, frame: frame, layer: layer))
    }
    return entries
}

class TickState {
    lazy var spaceID: CGSSpaceID = activeSpaceID()

    lazy var cgWindows: [CGWindowEntry] = fetchCGWindowList()

    lazy var windows: [Window] = self.cgWindows
        .filter { !ignoredApps.contains($0.name) }
        .map { Window(id: $0.id, pid: $0.pid, name: $0.name, frame: $0.frame) }

    private var _focusedWindow: Window?? = nil
    var focusedWindow: Window? {
        if let cached = _focusedWindow { return cached }
        let value = getFocusedWindow(cgWindows: self.cgWindows)
        _focusedWindow = .some(value)
        return value
    }
}

func getFocusedWindow(cgWindows: [CGWindowEntry]) -> Window? {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
    let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

    var focusedRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
          let ref = focusedRef
    else { return nil }
    let axWindow = ref as! AXUIElement

    var windowID: CGWindowID = 0
    _ = _AXUIElementGetWindow(axWindow, &windowID)

    let frame = cgWindows.first(where: { $0.id == windowID })
        .map { CGRect(x: $0.frame.origin.x, y: $0.frame.origin.y, width: $0.frame.width, height: $0.frame.height) }
        ?? .zero

    return Window(id: windowID, pid: frontApp.processIdentifier, name: frontApp.localizedName ?? "unknown", frame: frame)
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

// Eager snapshot used only by --dump
struct DumpSnapshot {
    let windows: [Window]
    let layers: [UInt32: Int]
    let subroles: [UInt32: String]
    let excludeReasons: [UInt32: String]
    let manageableIDs: Set<UInt32>
}

func dumpWindowInfo() -> DumpSnapshot {
    let cgWindows = fetchCGWindowList()
    var allWindows: [Window] = []
    var layers: [UInt32: Int] = [:]
    var subroles: [UInt32: String] = [:]
    var excludeReasons: [UInt32: String] = [:]
    var manageableIDs: Set<UInt32> = []

    for entry in cgWindows {
        let win = Window(id: entry.id, pid: entry.pid, name: entry.name, frame: entry.frame)
        allWindows.append(win)
        layers[entry.id] = entry.layer

        if ignoredApps.contains(entry.name) {
            excludeReasons[entry.id] = "ignored app"
            continue
        }
        guard manageableLayers.contains(entry.layer) else { continue }
        if excludedApps.contains(entry.name) {
            excludeReasons[entry.id] = "excluded app"
            continue
        }
        guard let axWindow = findAXWindowByPidAndID(pid: entry.pid, windowID: entry.id) else {
            excludeReasons[entry.id] = "no AX handle"
            continue
        }
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = subroleRef as? String ?? "nil"
        subroles[entry.id] = subrole
        guard subrole == kAXStandardWindowSubrole as String else {
            excludeReasons[entry.id] = "subrole: \(subrole)"
            continue
        }
        var fullScreenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString, &fullScreenRef) == .success,
           let isFullScreen = fullScreenRef as? Bool, isFullScreen {
            excludeReasons[entry.id] = "full screen"
            continue
        }
        manageableIDs.insert(entry.id)
    }

    return DumpSnapshot(windows: allWindows, layers: layers, subroles: subroles,
                        excludeReasons: excludeReasons, manageableIDs: manageableIDs)
}
