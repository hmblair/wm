import Cocoa
import ApplicationServices

class ManagedWindow {
    let id: UInt32
    let pid: Int32
    let name: String
    let axWindow: AXUIElement
    var spaceID: CGSSpaceID
    var frame: CGRect

    init(id: UInt32, pid: Int32, name: String, axWindow: AXUIElement, spaceID: CGSSpaceID, frame: CGRect) {
        self.id = id
        self.pid = pid
        self.name = name
        self.axWindow = axWindow
        self.spaceID = spaceID
        self.frame = frame
    }
}

var managedWindows: [UInt32: ManagedWindow] = [:]

func resolveManaged(for focused: Window) -> ManagedWindow? {
    if let win = managedWindows[focused.id] { return win }
    return managedWindows.values.first(where: { $0.pid == focused.pid })
}

func reconcileWindows(cgWindows: [CGWindowEntry], activeSpaceID: CGSSpaceID) {
    let visibleIDs = Set(cgWindows.map { $0.id })

    for id in managedWindows.keys where !visibleIDs.contains(id) {
        let name = managedWindows[id]?.name ?? "?"
        log("reconcile: removed window [\(id)] (\(name))")
        managedWindows.removeValue(forKey: id)
    }

    for entry in cgWindows {
        guard !ignoredApps.contains(entry.name) else { continue }

        // Update existing managed windows from CG data (no AX calls)
        if let existing = managedWindows[entry.id] {
            let entrySpace = spaceForWindow(entry.id) ?? activeSpaceID
            if existing.spaceID != entrySpace {
                log("reconcile: window [\(existing.id)] space changed \(existing.spaceID) -> \(entrySpace)")
            }
            existing.spaceID = entrySpace
            existing.frame = entry.frame
            continue
        }

        // New window — check if it's a candidate for management
        guard manageableLayers.contains(entry.layer) else { continue }
        guard !excludedApps.contains(entry.name) else { continue }

        // AX lookup (expensive — only for new windows)
        guard let axWindow = findAXWindowByPidAndID(pid: entry.pid, windowID: entry.id) else { continue }

        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = subroleRef as? String ?? "nil"
        guard subrole == kAXStandardWindowSubrole as String else { continue }

        var fullScreenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString, &fullScreenRef) == .success,
           let isFullScreen = fullScreenRef as? Bool, isFullScreen { continue }

        var spaceID = spaceForWindow(entry.id) ?? 0
        if spaceID == 0 {
            spaceID = activeSpaceID
            warn("spaceForWindow returned nil for [\(entry.id)] (\(entry.name)), using active space \(activeSpaceID)")
        }

        let win = ManagedWindow(id: entry.id, pid: entry.pid, name: entry.name,
                                axWindow: axWindow, spaceID: spaceID, frame: entry.frame)
        managedWindows[win.id] = win
        log("reconcile: added window [\(win.id)] (\(win.name)) on space \(spaceID)")
    }
}
