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
        .filter { !config.ignoredApps.contains($0.name) }
        .map { Window(id: $0.id, pid: $0.pid, name: $0.name, frame: $0.frame) }

    lazy var focusedWindow: Window? = getFocusedWindow(cgWindows: self.cgWindows)
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

    let frame = cgWindows.first(where: { $0.id == windowID })?.frame ?? .zero

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

enum WindowExcludeReason: CustomStringConvertible {
    case ignoredApp, excludedApp, noAXHandle, subrole(String), fullScreen

    var description: String {
        switch self {
        case .ignoredApp: return "ignored app"
        case .excludedApp: return "excluded app"
        case .noAXHandle: return "no AX handle"
        case .subrole(let s): return "subrole: \(s)"
        case .fullScreen: return "full screen"
        }
    }
}

struct EligibilityResult {
    let axWindow: AXUIElement?
    let subrole: String?
    let reason: WindowExcludeReason?
}

func checkWindowEligibility(entry: CGWindowEntry) -> EligibilityResult {
    if config.ignoredApps.contains(entry.name) { return EligibilityResult(axWindow: nil, subrole: nil, reason: .ignoredApp) }
    guard manageableLayers.contains(entry.layer) else { return EligibilityResult(axWindow: nil, subrole: nil, reason: nil) }
    if config.excludedApps.contains(entry.name) { return EligibilityResult(axWindow: nil, subrole: nil, reason: .excludedApp) }

    guard let axWindow = findAXWindowByPidAndID(pid: entry.pid, windowID: entry.id) else {
        return EligibilityResult(axWindow: nil, subrole: nil, reason: .noAXHandle)
    }

    var subroleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subroleRef)
    let subrole = subroleRef as? String

    guard (subrole ?? "nil") == kAXStandardWindowSubrole as String else {
        return EligibilityResult(axWindow: axWindow, subrole: subrole, reason: .subrole(subrole ?? "nil"))
    }

    var fullScreenRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString, &fullScreenRef) == .success,
       let isFullScreen = fullScreenRef as? Bool, isFullScreen {
        return EligibilityResult(axWindow: axWindow, subrole: subrole, reason: .fullScreen)
    }

    return EligibilityResult(axWindow: axWindow, subrole: subrole, reason: nil)
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
        allWindows.append(Window(id: entry.id, pid: entry.pid, name: entry.name, frame: entry.frame))
        layers[entry.id] = entry.layer

        let result = checkWindowEligibility(entry: entry)

        if let s = result.subrole { subroles[entry.id] = s }

        if let reason = result.reason {
            excludeReasons[entry.id] = reason.description
        } else if result.axWindow != nil {
            manageableIDs.insert(entry.id)
        }
    }

    return DumpSnapshot(windows: allWindows, layers: layers, subroles: subroles,
                        excludeReasons: excludeReasons, manageableIDs: manageableIDs)
}
