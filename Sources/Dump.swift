import Cocoa

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

        switch checkWindowEligibility(entry: entry) {
        case .manageable(_, let subrole):
            manageableIDs.insert(entry.id)
            if let s = subrole { subroles[entry.id] = s }
        case .excluded(let reason, let subrole):
            excludeReasons[entry.id] = reason
            if let s = subrole { subroles[entry.id] = s }
        case .notManageable:
            break
        }
    }

    return DumpSnapshot(windows: allWindows, layers: layers, subroles: subroles,
                        excludeReasons: excludeReasons, manageableIDs: manageableIDs)
}

func runDump() {
    let dumpDelay: TimeInterval = 3
    fputs("Dumping in \(Int(dumpDelay)) seconds — switch to the window you want to inspect.\n", stderr)
    Thread.sleep(forTimeInterval: dumpDelay)
    guard let frontApp = NSWorkspace.shared.frontmostApplication else {
        fputs("no frontmost app\n", stderr); exit(1)
    }
    let spaceID = activeSpaceID()
    print("Frontmost app: \(frontApp.localizedName ?? "?") (pid \(frontApp.processIdentifier))")
    print("Active space: \(spaceID)")

    if let focused = getFocusedWindow(cgWindows: fetchCGWindowList()) {
        print("Focused window: [\(focused.id)] \(focused.name) — \(formatFrame(focused.frame))")
    } else {
        print("Could not get focused window info")
    }

    let dump = dumpWindowInfo()
    let cgWindows = fetchCGWindowList()
    let reconciled = computeReconciliation(current: [:], cgWindows: cgWindows)
    let trees = computeBSPTrees(managedWindows: reconciled, currentTrees: [:],
                                spaceID: spaceID, lastActiveSpace: 0)
    let tileFrames = tilingEnabled
        ? computeTileFrames(trees: trees, managedWindows: reconciled, spaceID: spaceID)
        : [:]

    print("\nAll on-screen windows (z-order):")
    for win in dump.windows {
        let rawSpace = spaceForWindow(win.id)
        let spaceStr = rawSpace.map { String($0) } ?? "nil"
        let layer = dump.layers[win.id] ?? 0
        let subroleStr = dump.subroles[win.id].map { " subrole=\($0)" } ?? ""

        let status: String
        if let reason = dump.excludeReasons[win.id] {
            status = "excluded: \(reason)"
        } else if dump.manageableIDs.contains(win.id) {
            if let tile = tileFrames[win.id] {
                status = "managed, tile=\(formatFrame(tile))"
            } else {
                status = "managed, not tiled"
            }
        } else {
            status = "not manageable"
        }

        print("  [\(win.id)] \(win.name) — \(formatFrame(win.frame)) layer=\(layer) space=\(spaceStr)\(subroleStr) [\(status)]")
    }
    exit(0)
}
