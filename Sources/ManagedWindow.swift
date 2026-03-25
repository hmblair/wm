import Cocoa
import ApplicationServices

class ManagedWindow {
    let id: UInt32
    let pid: Int32
    let name: String
    let axWindow: AXUIElement
    var frame: CGRect
    var actualSize: CGSize?

    init(id: UInt32, pid: Int32, name: String, axWindow: AXUIElement, frame: CGRect) {
        self.id = id
        self.pid = pid
        self.name = name
        self.axWindow = axWindow
        self.frame = frame
    }
}

func resolveManaged(for focused: Window, in windows: [UInt32: ManagedWindow]) -> ManagedWindow? {
    if let win = windows[focused.id] { return win }
    return windows.values.first(where: { $0.pid == focused.pid })
}

func computeReconciliation(
    current: [UInt32: ManagedWindow],
    cgWindows: [CGWindowEntry]
) -> [UInt32: ManagedWindow] {
    var result = current
    let visibleIDs = Set(cgWindows.map { $0.id })

    for id in result.keys where !visibleIDs.contains(id) {
        let name = result[id]?.name ?? "?"
        log("reconcile: removed window [\(id)] (\(name))")
        result.removeValue(forKey: id)
    }

    for entry in cgWindows {
        if let existing = result[entry.id] {
            existing.frame = entry.frame
            continue
        }

        let elig = checkWindowEligibility(entry: entry)
        guard elig.reason == nil, let axWindow = elig.axWindow else { continue }

        let win = ManagedWindow(id: entry.id, pid: entry.pid, name: entry.name,
                                axWindow: axWindow, frame: entry.frame)
        result[win.id] = win
        log("reconcile: added window [\(win.id)] (\(win.name))")
    }

    return result
}
