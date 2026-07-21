import Cocoa
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

struct Window {
    let id: UInt32
    let pid: Int32
    let name: String
    let frame: CGRect
    var isFullScreen: Bool = false
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

    let ownPID = getpid()
    var entries: [CGWindowEntry] = []
    for info in infoList {
        guard let id = info[kCGWindowNumber as String] as? UInt32,
              let pid = info[kCGWindowOwnerPID as String] as? Int32,
              let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
              let layer = info[kCGWindowLayer as String] as? Int,
              let name = info[kCGWindowOwnerName as String] as? String
        else { continue }
        // Skip the daemon's own windows (focus-border overlay, status item) so
        // they never enter reconciliation or the idle-tick signature.
        if pid == ownPID { continue }
        let frame = CGRect(
            x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
        )
        entries.append(CGWindowEntry(id: id, pid: pid, name: name, frame: frame, layer: layer))
    }
    return entries
}


// AXUIElementCreateApplication rebuilds a fresh Accessibility handle on every
// call, which getFocusedWindow does each tick (~60 Hz). The handle only
// references the process, so it stays valid for the app's lifetime — cache it
// per pid. A handle for a quit app simply makes subsequent queries fail, which
// callers already treat as "no focus", so stale entries are harmless.
private var axAppElementCache: [pid_t: AXUIElement] = [:]

func axAppElement(for pid: pid_t) -> AXUIElement {
    if let cached = axAppElementCache[pid] { return cached }
    let element = AXUIElementCreateApplication(pid)
    axAppElementCache[pid] = element
    return element
}

func getFocusedWindow(cgWindows: [CGWindowEntry]) -> Window? {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
    let appElement = axAppElement(for: frontApp.processIdentifier)

    var focusedRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
          let ref = focusedRef
    else { return nil }
    let axWindow = ref as! AXUIElement

    var windowID: CGWindowID = 0
    _ = _AXUIElementGetWindow(axWindow, &windowID)

    let frame = cgWindows.first(where: { $0.id == windowID })?.frame ?? .zero

    // Only the focus border consumes this, so skip the extra AX read otherwise.
    var isFullScreen = false
    if config.focusBorder {
        var fsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString, &fsRef) == .success {
            isFullScreen = (fsRef as? Bool) == true
        }
    }

    return Window(id: windowID, pid: frontApp.processIdentifier,
                  name: frontApp.localizedName ?? "unknown", frame: frame, isFullScreen: isFullScreen)
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

enum EligibilityResult {
    case manageable(axWindow: AXUIElement, subrole: String?)
    case excluded(reason: String, subrole: String?)
    case notManageable
}

func checkWindowEligibility(entry: CGWindowEntry) -> EligibilityResult {
    if config.ignoredApps.contains(entry.name) { return .excluded(reason: "ignored app", subrole: nil) }
    guard manageableLayers.contains(entry.layer) else { return .notManageable }
    if config.excludedApps.contains(entry.name) { return .excluded(reason: "excluded app", subrole: nil) }

    guard let axWindow = findAXWindowByPidAndID(pid: entry.pid, windowID: entry.id) else {
        return .excluded(reason: "no AX handle", subrole: nil)
    }

    var subroleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subroleRef)
    let subrole = subroleRef as? String

    guard (subrole ?? "nil") == kAXStandardWindowSubrole as String else {
        return .excluded(reason: "subrole: \(subrole ?? "nil")", subrole: subrole)
    }

    var fullScreenRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString, &fullScreenRef) == .success,
       let isFullScreen = fullScreenRef as? Bool, isFullScreen {
        return .excluded(reason: "full screen", subrole: subrole)
    }

    return .manageable(axWindow: axWindow, subrole: subrole)
}
