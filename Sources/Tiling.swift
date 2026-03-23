import CoreGraphics

struct DisplaySpaceKey: Hashable {
    let displayID: CGDirectDisplayID
    let spaceID: CGSSpaceID
}

var bspTrees: [DisplaySpaceKey: BSPTree] = [:]
var lastActiveSpace: CGSSpaceID = 0

func applyTiling(spaceID: CGSSpaceID) {
    // Clear tile frames for this space — windows not in a tree get nil
    for win in managedWindows.values where win.spaceID == spaceID {
        win.tileFrame = nil
    }

    let minSizes = Dictionary(uniqueKeysWithValues:
        managedWindows.values.map { ($0.id, $0.minSize) })

    for (key, tree) in bspTrees where key.spaceID == spaceID {
        guard let screen = screenForDisplayID(key.displayID) else { continue }
        let rect = visibleFrame(for: screen)
        let adjusted = tree.adjustingRatios(rect: rect, minSizes: minSizes, gap: config.gap)
        bspTrees[key] = adjusted
        let frames = adjusted.computeFrames(rect: rect, gap: config.gap)
        for (id, tileRect) in frames {
            if let win = managedWindows[id] {
                win.tileFrame = tileRect
                setWindowFrame(win, frame: tileRect)
            }
        }
    }
}

func tileWindows(spaceID: CGSSpaceID) {
    guard tilingEnabled else { return }

    let spaceChanged = spaceID != lastActiveSpace
    if spaceChanged {
        log("space changed: \(lastActiveSpace) -> \(spaceID)")
        lastActiveSpace = spaceID
    }

    let spaceWindows = managedWindows.values.filter { $0.spaceID == spaceID }

    var windowsByDisplay: [CGDirectDisplayID: [ManagedWindow]] = [:]
    for win in spaceWindows {
        let center = CGPoint(x: win.frame.midX, y: win.frame.midY)
        let did = displayID(for: center)
        windowsByDisplay[did, default: []].append(win)
    }

    let currentSpaceKeys = Set(windowsByDisplay.keys.map { DisplaySpaceKey(displayID: $0, spaceID: spaceID) })
    let existingKeysForSpace = Set(bspTrees.keys.filter { $0.spaceID == spaceID })
    let allKeys = currentSpaceKeys.union(existingKeysForSpace)
    var changed = spaceChanged

    for key in allKeys {
        let screenWindows = windowsByDisplay[key.displayID] ?? []
        let currentIDs = Set(screenWindows.map { $0.id })
        let treeIDs = Set(bspTrees[key]?.windowIDs ?? [])

        guard currentIDs != treeIDs else { continue }
        changed = true

        if screenWindows.isEmpty {
            bspTrees.removeValue(forKey: key)
            continue
        }

        var orderedIDs: [UInt32] = []
        if let existingTree = bspTrees[key] {
            orderedIDs = existingTree.windowIDs.filter { currentIDs.contains($0) }
        }
        for win in screenWindows where !orderedIDs.contains(win.id) {
            orderedIDs.append(win.id)
        }

        bspTrees[key] = buildBSPTree(windowIDs: orderedIDs, splitVertical: true)
    }

    if changed {
        log("re-tiling \(spaceWindows.count) windows on space \(spaceID)")
        applyTiling(spaceID: spaceID)
    }
}

func snapBackDisplacedWindows(snapshots: [WindowInfo]) {
    guard tilingEnabled else { return }
    for snapshot in snapshots {
        guard let managed = managedWindows[snapshot.id],
              let tileRect = managed.tileFrame else { continue }
        if abs(snapshot.frame.origin.x - managed.frame.origin.x) > 2
            || abs(snapshot.frame.origin.y - managed.frame.origin.y) > 2
            || abs(snapshot.frame.width - managed.frame.width) > 2
            || abs(snapshot.frame.height - managed.frame.height) > 2 {
            log("snapping back \(managed.id) (\(managed.name))")
            setWindowFrame(managed, frame: tileRect)
        }
    }
}
