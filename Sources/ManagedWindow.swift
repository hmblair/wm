import Cocoa
import ApplicationServices

class ManagedWindow {
    let id: UInt32
    let pid: Int32
    let name: String
    let axWindow: AXUIElement
    var spaceID: CGSSpaceID
    var frame: CGRect

    init(from info: ManagedWindowInfo) {
        self.id = info.window.id
        self.pid = info.window.pid
        self.name = info.window.name
        self.axWindow = info.axWindow
        self.spaceID = info.spaceID
        self.frame = info.window.frame
    }
}

var managedWindows: [UInt32: ManagedWindow] = [:]

func resolveManaged(for focused: Window) -> ManagedWindow? {
    if let win = managedWindows[focused.id] { return win }
    return managedWindows.values.first(where: { $0.pid == focused.pid })
}

func reconcileWindows(snapshot: OnScreenSnapshot, activeSpaceID: CGSSpaceID) {
    let snapshotIDs = Set(snapshot.manageable.map { $0.window.id })

    for id in managedWindows.keys where !snapshotIDs.contains(id) {
        let name = managedWindows[id]?.name ?? "?"
        log("reconcile: removed window [\(id)] (\(name))")
        managedWindows.removeValue(forKey: id)
    }

    for info in snapshot.manageable {
        var spaceID = info.spaceID
        if spaceID == 0 {
            spaceID = activeSpaceID
            warn("spaceForWindow returned nil for [\(info.window.id)] (\(info.window.name)), using active space \(activeSpaceID)")
        }

        if let existing = managedWindows[info.window.id] {
            if existing.spaceID != spaceID {
                log("reconcile: window [\(existing.id)] space changed \(existing.spaceID) -> \(spaceID)")
            }
            existing.spaceID = spaceID
            existing.frame = info.window.frame
        } else {
            let win = ManagedWindow(from: info)
            win.spaceID = spaceID
            managedWindows[win.id] = win
            log("reconcile: added window [\(win.id)] (\(win.name)) on space \(spaceID)")
        }
    }
}
