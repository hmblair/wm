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

func reconcileWindows(snapshots: [WindowInfo]) {
    let snapshotIDs = Set(snapshots.map { $0.id })

    // Remove windows that are no longer on screen
    for id in managedWindows.keys where !snapshotIDs.contains(id) {
        managedWindows.removeValue(forKey: id)
    }

    // Add new windows, update existing
    for snapshot in snapshots {
        if let existing = managedWindows[snapshot.id] {
            existing.spaceID = snapshot.spaceID
            // For non-tiled windows, the OS frame is authoritative
            if existing.tileFrame == nil {
                existing.frame = snapshot.frame
            }
        } else {
            managedWindows[snapshot.id] = ManagedWindow(from: snapshot)
        }
    }
}
