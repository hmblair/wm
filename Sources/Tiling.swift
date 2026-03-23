import CoreGraphics

var bspTrees: [CGDirectDisplayID: BSPTree] = [:]
var lastTiledFrames: [UInt32: CGRect] = [:]

func applyTiling(windows: [WindowInfo]) {
    let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })

    var newFrames: [UInt32: CGRect] = [:]
    for (did, tree) in bspTrees {
        guard let screen = screenForDisplayID(did) else { continue }
        let rect = visibleFrame(for: screen)
        let frames = tree.computeFrames(rect: rect)
        for (id, frame) in frames {
            if let win = windowsByID[id] {
                setWindowFrame(win, frame: frame)
            }
            newFrames[id] = frame
        }
    }
    lastTiledFrames = newFrames
}

func tileWindows(windows: [WindowInfo]) {
    guard tilingEnabled else { return }

    var windowsByDisplay: [CGDirectDisplayID: [WindowInfo]] = [:]
    for win in windows {
        let center = CGPoint(x: win.frame.midX, y: win.frame.midY)
        let did = displayID(for: center)
        windowsByDisplay[did, default: []].append(win)
    }

    let allDisplayIDs = Set(windowsByDisplay.keys).union(bspTrees.keys)
    var changed = false

    for did in allDisplayIDs {
        let screenWindows = windowsByDisplay[did] ?? []
        let currentIDs = Set(screenWindows.map { $0.id })
        let treeIDs = Set(bspTrees[did]?.windowIDs ?? [])

        guard currentIDs != treeIDs else { continue }
        changed = true

        if screenWindows.isEmpty {
            bspTrees.removeValue(forKey: did)
            continue
        }

        var orderedIDs: [UInt32] = []
        if let existingTree = bspTrees[did] {
            orderedIDs = existingTree.windowIDs.filter { currentIDs.contains($0) }
        }
        for win in screenWindows where !orderedIDs.contains(win.id) {
            orderedIDs.append(win.id)
        }

        bspTrees[did] = buildBSPTree(windowIDs: orderedIDs, splitVertical: true)
    }

    if changed {
        log("re-tiling \(windows.count) windows across \(windowsByDisplay.count) screens")
        applyTiling(windows: windows)
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
