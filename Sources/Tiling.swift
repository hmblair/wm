import Cocoa
import ApplicationServices

let frameTolerance: CGFloat = 2

struct DisplaySpaceKey: Hashable {
    let displayID: CGDirectDisplayID
    let spaceID: CGSSpaceID
}

func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
    return abs(a.origin.x - b.origin.x) <= frameTolerance
        && abs(a.origin.y - b.origin.y) <= frameTolerance
        && abs(a.width - b.width) <= frameTolerance
        && abs(a.height - b.height) <= frameTolerance
}

// MARK: - Tile computation (pure)

func computeTileFrames(
    trees: [DisplaySpaceKey: BSPTree],
    managedWindows: [UInt32: ManagedWindow],
    spaceID: CGSSpaceID
) -> [UInt32: CGRect] {
    var tileFrames: [UInt32: CGRect] = [:]

    for (key, tree) in trees where key.spaceID == spaceID {
        guard let screen = screenForDisplayID(key.displayID) else { continue }
        let rect = visibleFrame(for: screen)
        var constraints: [UInt32: (min: CGSize?, max: CGSize?)] = [:]
        for (id, win) in managedWindows where win.minSize != nil || win.maxSize != nil {
            constraints[id] = (min: win.minSize, max: win.maxSize)
        }
        for (id, tileRect) in tree.computeFrames(rect: rect, gap: config.gap, constraints: constraints) {
            tileFrames[id] = tileRect
        }
    }

    return tileFrames
}

// MARK: - BSP tree management (pure)

func computeBSPTrees(
    managedWindows: [UInt32: ManagedWindow],
    currentTrees: [DisplaySpaceKey: BSPTree],
    spaceID: CGSSpaceID,
    lastActiveSpace: CGSSpaceID
) -> [DisplaySpaceKey: BSPTree] {
    var trees = currentTrees

    let spaceChanged = spaceID != lastActiveSpace
    if spaceChanged {
        log("space: changed \(lastActiveSpace) -> \(spaceID)")
    }

    var windowsByDisplay: [CGDirectDisplayID: [ManagedWindow]] = [:]
    for win in managedWindows.values {
        let center = CGPoint(x: win.frame.midX, y: win.frame.midY)
        let did = displayID(for: center)
        windowsByDisplay[did, default: []].append(win)
    }

    let currentSpaceKeys = Set(windowsByDisplay.keys.map { DisplaySpaceKey(displayID: $0, spaceID: spaceID) })
    let existingKeysForSpace = Set(trees.keys.filter { $0.spaceID == spaceID })
    let allKeys = currentSpaceKeys.union(existingKeysForSpace)
    var changed = spaceChanged

    for key in allKeys {
        let screenWindows = windowsByDisplay[key.displayID] ?? []
        let currentIDs = Set(screenWindows.map { $0.id })
        let treeIDs = Set(trees[key]?.windowIDs ?? [])

        guard currentIDs != treeIDs else { continue }
        changed = true

        if screenWindows.isEmpty {
            trees.removeValue(forKey: key)
            continue
        }

        var orderedIDs: [UInt32] = []
        if let existingTree = trees[key] {
            orderedIDs = existingTree.windowIDs.filter { currentIDs.contains($0) }
        }
        for win in screenWindows where !orderedIDs.contains(win.id) {
            orderedIDs.append(win.id)
        }

        let orderedWindows = orderedIDs.compactMap { managedWindows[$0] }
        debug("tile: rebuild BSP display \(key.displayID) space \(key.spaceID) — \(orderedIDs.count) windows: \(orderedIDs)")
        if let screen = screenForDisplayID(key.displayID) {
            let rect = visibleFrame(for: screen)
            trees[key] = buildBSPTreeFitting(windows: orderedWindows, rect: rect, gap: config.gap)
        } else {
            trees[key] = buildBSPTree(windowIDs: orderedIDs, splitVertical: true)
        }
    }

    if changed {
        debug("tile: re-tiling \(managedWindows.count) windows on space \(spaceID)")
    }

    return trees
}
