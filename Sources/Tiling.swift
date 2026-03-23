import CoreGraphics

struct DisplaySpaceKey: Hashable {
    let displayID: CGDirectDisplayID
    let spaceID: CGSSpaceID
}

var bspTrees: [DisplaySpaceKey: BSPTree] = [:]
var lastTiledFrames: [UInt32: CGRect] = [:]
var lastActiveSpace: CGSSpaceID = 0

func applyTiling(windows: [WindowInfo], spaceID: CGSSpaceID) {
    let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })

    var newFrames: [UInt32: CGRect] = [:]
    for (key, tree) in bspTrees where key.spaceID == spaceID {
        guard let screen = screenForDisplayID(key.displayID) else { continue }
        let rect = visibleFrame(for: screen)
        let frames = tree.computeFrames(rect: rect, gap: config.gap)
        for (id, frame) in frames {
            if let win = windowsByID[id] {
                setWindowFrame(win, frame: frame)
            }
            newFrames[id] = frame
        }
    }
    lastTiledFrames = newFrames
}

func tileWindows(windows: [WindowInfo], spaceID: CGSSpaceID) {
    guard tilingEnabled else { return }

    // Detect space change — restore tiling for new space without rebuilding
    let spaceChanged = spaceID != lastActiveSpace
    if spaceChanged {
        log("space changed: \(lastActiveSpace) -> \(spaceID)")
        lastActiveSpace = spaceID
    }

    let spaceWindows = windows.filter { $0.spaceID == spaceID }

    var windowsByDisplay: [CGDirectDisplayID: [WindowInfo]] = [:]
    for win in spaceWindows {
        let center = CGPoint(x: win.frame.midX, y: win.frame.midY)
        let did = displayID(for: center)
        windowsByDisplay[did, default: []].append(win)
    }

    // Only check trees for the current space
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
        applyTiling(windows: spaceWindows, spaceID: spaceID)
    }
}

func snapBackDisplacedWindows(windows: [WindowInfo]) {
    guard tilingEnabled else { return }
    for win in windows {
        guard let expected = lastTiledFrames[win.id] else { continue }
        if abs(win.frame.origin.x - expected.origin.x) > 2
            || abs(win.frame.origin.y - expected.origin.y) > 2
            || abs(win.frame.width - expected.width) > 2
            || abs(win.frame.height - expected.height) > 2 {
            log("snapping back \(win.id) (\(win.name))")
            setWindowFrame(win, frame: expected)
        }
    }
}
