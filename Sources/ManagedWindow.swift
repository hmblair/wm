import Cocoa
import ApplicationServices

class ManagedWindow {
    let id: UInt32
    let pid: Int32
    let name: String
    let axWindow: AXUIElement
    var spaceID: CGSSpaceID
    var frame: CGRect       // actual position (post-constraint, updated by setWindowFrame)
    var tileFrame: CGRect?  // assigned tile area (for hit-testing and snap-back)
    var minSize: CGSize = .zero  // minimum size constraint (from popups or other non-managed windows)

    init(from snapshot: WindowInfo) {
        self.id = snapshot.id
        self.pid = snapshot.pid
        self.name = snapshot.name
        self.axWindow = snapshot.axWindow
        self.spaceID = snapshot.spaceID
        self.frame = snapshot.frame
    }
}

var managedWindows: [UInt32: ManagedWindow] = [:]

/// Resolves a focused window to its managed window. If the focused window
/// itself isn't managed (e.g. a popup), falls back to the managed window
/// for the same app.
func resolveManaged(for focused: FocusedWindowInfo) -> ManagedWindow? {
    if let win = managedWindows[focused.id] { return win }
    return managedWindows.values.first(where: { $0.pid == focused.pid })
}

func reconcileWindows(snapshot: OnScreenSnapshot) {
    let snapshotIDs = Set(snapshot.managed.map { $0.id })

    // Remove windows that are no longer on screen
    for id in managedWindows.keys where !snapshotIDs.contains(id) {
        managedWindows.removeValue(forKey: id)
    }

    // Add new windows, update existing
    for info in snapshot.managed {
        if let existing = managedWindows[info.id] {
            existing.spaceID = info.spaceID
            existing.minSize = snapshot.popupSizeByPid[info.pid] ?? .zero
            // For non-tiled windows, the OS frame is authoritative
            if existing.tileFrame == nil {
                existing.frame = info.frame
            }
        } else {
            let win = ManagedWindow(from: info)
            win.minSize = snapshot.popupSizeByPid[info.pid] ?? .zero
            managedWindows[win.id] = win
        }
    }
}
