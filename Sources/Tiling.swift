import Cocoa
import ApplicationServices

private let frameTolerance: CGFloat = 2

struct DisplaySpaceKey: Hashable {
    let displayID: CGDirectDisplayID
    let spaceID: CGSSpaceID
}

var bspTrees: [DisplaySpaceKey: BSPTree] = [:]
var lastActiveSpace: CGSSpaceID = 0

func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
    return abs(a.origin.x - b.origin.x) <= frameTolerance
        && abs(a.origin.y - b.origin.y) <= frameTolerance
        && abs(a.width - b.width) <= frameTolerance
        && abs(a.height - b.height) <= frameTolerance
}

// MARK: - Tile computation (pure — no AX calls)

func computeTileFrames(spaceID: CGSSpaceID, popupSizeByPid: [Int32: CGSize]) -> [UInt32: CGRect] {
    var tileFrames: [UInt32: CGRect] = [:]

    let minSizes = Dictionary(uniqueKeysWithValues:
        managedWindows.values.map { ($0.id, popupSizeByPid[$0.pid] ?? .zero) })

    for (key, tree) in bspTrees where key.spaceID == spaceID {
        guard let screen = screenForDisplayID(key.displayID) else { continue }
        let rect = visibleFrame(for: screen)
        let adjusted = tree.adjustingRatios(rect: rect, minSizes: minSizes, gap: config.gap)
        bspTrees[key] = adjusted
        for (id, tileRect) in adjusted.computeFrames(rect: rect, gap: config.gap) {
            tileFrames[id] = tileRect
        }
    }

    return tileFrames
}

// MARK: - BSP tree management

func tileWindows(spaceID: CGSSpaceID, popupSizeByPid: [Int32: CGSize]) -> [UInt32: CGRect] {
    guard tilingEnabled else { return [:] }

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

        guard currentIDs != treeIDs else {
            log("tile: no change for display \(key.displayID) space \(key.spaceID)")
            continue
        }
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

        log("tile: rebuilding BSP for display \(key.displayID) space \(key.spaceID) — \(orderedIDs.count) windows: \(orderedIDs)")
        bspTrees[key] = buildBSPTree(windowIDs: orderedIDs, splitVertical: true)
    }

    let tileFrames = computeTileFrames(spaceID: spaceID, popupSizeByPid: popupSizeByPid)

    if changed {
        log("re-tiling \(spaceWindows.count) windows on space \(spaceID)")
    }

    return tileFrames
}

// MARK: - Enforcement (compares CG reality to intent, issues AX commands)

func enforceTileFrames(_ tileFrames: [UInt32: CGRect]) {
    let mouseDown = NSEvent.pressedMouseButtons & 0x1 != 0
    if mouseDown { return }

    for (id, tileFrame) in tileFrames {
        guard let win = managedWindows[id] else { continue }
        if !framesMatch(win.frame, tileFrame) {
            log("enforce: [\(id)] (\(win.name)) frame \(Int(win.frame.origin.x)),\(Int(win.frame.origin.y)) \(Int(win.frame.width))x\(Int(win.frame.height)) → \(Int(tileFrame.origin.x)),\(Int(tileFrame.origin.y)) \(Int(tileFrame.width))x\(Int(tileFrame.height))")
            setWindowFrame(win, frame: tileFrame)
        }
    }
}
