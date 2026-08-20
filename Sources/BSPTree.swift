import CoreGraphics

indirect enum BSPTree {
    case leaf(id: UInt32)
    case split(left: BSPTree, right: BSPTree, vertical: Bool, ratio: CGFloat = 0.5)

    private static func crossesSplit(direction: Direction, vertical: Bool, inLeft: Bool) -> Bool {
        switch direction {
        case .right: return vertical && inLeft
        case .left:  return vertical && !inLeft
        case .down:  return !vertical && inLeft
        case .up:    return !vertical && !inLeft
        }
    }

    var windowIDs: [UInt32] {
        switch self {
        case .leaf(let id): return [id]
        case .split(let l, let r, _, _): return l.windowIDs + r.windowIDs
        }
    }

    func contains(id: UInt32) -> Bool {
        switch self {
        case .leaf(let wid): return wid == id
        case .split(let l, let r, _, _): return l.contains(id: id) || r.contains(id: id)
        }
    }

    typealias SizeConstraints = [UInt32: (min: CGSize?, max: CGSize?)]

    private func extentRange(vertical: Bool, gap: CGFloat,
                             constraints: SizeConstraints) -> (min: CGFloat?, max: CGFloat?) {
        switch self {
        case .leaf(let id):
            guard let c = constraints[id] else { return (nil, nil) }
            let rawMin = vertical ? c.min?.width : c.min?.height
            let rawMax = vertical ? c.max?.width : c.max?.height
            return (
                rawMin.flatMap { $0 > 0 ? $0 + gap : nil },
                rawMax.flatMap { $0 < .infinity ? $0 + gap : nil }
            )
        case .split(let left, let right, let v, _):
            let l = left.extentRange(vertical: vertical, gap: gap, constraints: constraints)
            let r = right.extentRange(vertical: vertical, gap: gap, constraints: constraints)
            if v == vertical {
                return combineCoaxial(l, r)
            } else {
                return combinePerpendicular(l, r)
            }
        }
    }

    func computeFrames(rect: CGRect, gap: CGFloat,
                        constraints: SizeConstraints = [:]) -> [(UInt32, CGRect)] {
        return tileFrames(rect: rect.insetBy(dx: gap / 2, dy: gap / 2),
                          gap: gap, constraints: constraints)
    }

    private func tileFrames(rect: CGRect, gap: CGFloat,
                            constraints: SizeConstraints) -> [(UInt32, CGRect)] {
        switch self {
        case .leaf(let id):
            let inner = rect.insetBy(dx: gap / 2, dy: gap / 2)
            var w = inner.width, h = inner.height
            if let c = constraints[id] {
                if let maxW = c.max?.width { w = min(w, maxW) }
                if let maxH = c.max?.height { h = min(h, maxH) }
            }
            let x = inner.minX + (inner.width - w) / 2
            let y = inner.minY + (inner.height - h) / 2
            return [(id, roundEdges(CGRect(x: x, y: y, width: w, height: h)))]
        case .split(let left, let right, let vertical, let ratio):
            let total = vertical ? rect.width : rect.height
            let splitPos = constrainedSplitPos(
                total: total, ratio: ratio,
                leftRange: left.extentRange(vertical: vertical, gap: gap, constraints: constraints),
                rightRange: right.extentRange(vertical: vertical, gap: gap, constraints: constraints))

            let (leftRect, rightRect) = splitRects(rect: rect, vertical: vertical, at: splitPos)
            return left.tileFrames(rect: leftRect, gap: gap, constraints: constraints)
                 + right.tileFrames(rect: rightRect, gap: gap, constraints: constraints)
        }
    }

    /// Round each edge of the rect to a whole point. Splits and gap insets can
    /// produce fractional coordinates, which apps round unpredictably; rounding
    /// the edges (not origin and size separately) keeps adjacent tiles flush.
    private func roundEdges(_ rect: CGRect) -> CGRect {
        let minX = rect.minX.rounded()
        let minY = rect.minY.rounded()
        return CGRect(x: minX, y: minY,
                      width: rect.maxX.rounded() - minX,
                      height: rect.maxY.rounded() - minY)
    }

    private func splitRects(rect: CGRect, vertical: Bool, at splitPos: CGFloat) -> (CGRect, CGRect) {
        if vertical {
            return (
                CGRect(x: rect.minX, y: rect.minY, width: splitPos, height: rect.height),
                CGRect(x: rect.minX + splitPos, y: rect.minY, width: rect.width - splitPos, height: rect.height)
            )
        } else {
            return (
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: splitPos),
                CGRect(x: rect.minX, y: rect.minY + splitPos, width: rect.width, height: rect.height - splitPos)
            )
        }
    }

    func swappingWindows(_ id1: UInt32, _ id2: UInt32) -> BSPTree {
        switch self {
        case .leaf(let id):
            if id == id1 { return .leaf(id: id2) }
            if id == id2 { return .leaf(id: id1) }
            return self
        case .split(let l, let r, let v, let ratio):
            return .split(left: l.swappingWindows(id1, id2),
                          right: r.swappingWindows(id1, id2), vertical: v, ratio: ratio)
        }
    }

    struct CrossingResult {
        let focusedIsAlone: Bool
        let otherSideIDs: [UInt32]
    }

}

private typealias ExtentRange = (min: CGFloat?, max: CGFloat?)

private func combineCoaxial(_ l: ExtentRange, _ r: ExtentRange) -> ExtentRange {
    let minSum: CGFloat? = {
        if let lv = l.min, let rv = r.min { return lv + rv }
        return l.min ?? r.min
    }()
    let maxSum: CGFloat? = {
        if let lv = l.max, let rv = r.max { return lv + rv }
        return nil
    }()
    return (minSum, maxSum)
}

private func combinePerpendicular(_ l: ExtentRange, _ r: ExtentRange) -> ExtentRange {
    let minVal: CGFloat? = {
        if let lv = l.min, let rv = r.min { return Swift.max(lv, rv) }
        return l.min ?? r.min
    }()
    let maxVal: CGFloat? = {
        if let lv = l.max, let rv = r.max { return Swift.min(lv, rv) }
        return l.max ?? r.max
    }()
    return (minVal, maxVal)
}

private func constrainedSplitPos(total: CGFloat, ratio: CGFloat,
                                  leftRange: ExtentRange, rightRange: ExtentRange) -> CGFloat {
    var pos = total * ratio
    if let mv = leftRange.max, pos > mv { pos = mv }
    if let mv = leftRange.min, pos < mv { pos = mv }
    if let mv = rightRange.max, total - pos > mv { pos = total - mv }
    if let mv = rightRange.min, total - pos < mv { pos = total - mv }
    return pos
}

extension BSPTree {

    func findCrossingSplit(windowID: UInt32, direction: Direction) -> CrossingResult? {
        guard case .split(let left, let right, let vertical, _) = self else { return nil }

        let inLeft = left.contains(id: windowID)
        guard inLeft || right.contains(id: windowID) else { return nil }

        let child = inLeft ? left : right
        if let deeper = child.findCrossingSplit(windowID: windowID, direction: direction) {
            return deeper
        }

        guard Self.crossesSplit(direction: direction, vertical: vertical, inLeft: inLeft) else { return nil }

        let mySide = inLeft ? left : right
        let otherSide = inLeft ? right : left
        let isAlone: Bool
        if case .leaf = mySide { isAlone = true } else { isAlone = false }

        return CrossingResult(focusedIsAlone: isAlone, otherSideIDs: otherSide.windowIDs)
    }

    func swappingChildrenForCrossing(windowID: UInt32, direction: Direction) -> BSPTree? {
        guard case .split(let left, let right, let vertical, let ratio) = self else { return nil }

        let inLeft = left.contains(id: windowID)
        guard inLeft || right.contains(id: windowID) else { return nil }

        if inLeft {
            if let newLeft = left.swappingChildrenForCrossing(windowID: windowID, direction: direction) {
                return .split(left: newLeft, right: right, vertical: vertical, ratio: ratio)
            }
        } else {
            if let newRight = right.swappingChildrenForCrossing(windowID: windowID, direction: direction) {
                return .split(left: left, right: newRight, vertical: vertical, ratio: ratio)
            }
        }

        if Self.crossesSplit(direction: direction, vertical: vertical, inLeft: inLeft) {
            return .split(left: right, right: left, vertical: vertical, ratio: 1 - ratio)
        }
        return nil
    }

    private var flipped: BSPTree {
        switch self {
        case .leaf: return self
        case .split(let l, let r, let v, let ratio):
            return .split(left: l.flipped, right: r.flipped, vertical: !v, ratio: ratio)
        }
    }

    func rotatingParent(of windowID: UInt32) -> BSPTree? {
        guard case .split(let left, let right, let vertical, let ratio) = self else { return nil }

        let leftContains = left.contains(id: windowID)
        let rightContains = right.contains(id: windowID)
        guard leftContains || rightContains else { return nil }

        let child = leftContains ? left : right
        if case .leaf = child {
            return .split(left: left.flipped, right: right.flipped, vertical: !vertical, ratio: ratio)
        }

        if leftContains, let newLeft = left.rotatingParent(of: windowID) {
            return .split(left: newLeft, right: right, vertical: vertical, ratio: ratio)
        }
        if rightContains, let newRight = right.rotatingParent(of: windowID) {
            return .split(left: left, right: newRight, vertical: vertical, ratio: ratio)
        }
        return nil
    }

}

func buildBSPTree(windowIDs: [UInt32], splitVertical: Bool) -> BSPTree? {
    guard !windowIDs.isEmpty else { return nil }
    if windowIDs.count == 1 { return .leaf(id: windowIDs[0]) }
    let mid = (windowIDs.count + 1) / 2
    return .split(
        left: buildBSPTree(windowIDs: Array(windowIDs[..<mid]), splitVertical: !splitVertical)!,
        right: buildBSPTree(windowIDs: Array(windowIDs[mid...]), splitVertical: !splitVertical)!,
        vertical: splitVertical
    )
}

// MARK: - Spatial BSP fitting

/// Build a template tree with placeholder leaf IDs (0..<n) for a given
/// split-orientation bitmask. Bit i controls whether internal node i
/// splits vertically (1) or horizontally (0).
private func buildTemplate(count: Int, splitMask: UInt32) -> BSPTree {
    var nextBit = 0
    func build(_ n: Int, parentVertical: Bool?) -> BSPTree {
        if n == 1 { return .leaf(id: 0) }
        let bit = nextBit
        nextBit += 1
        let vertical = (splitMask >> bit) & 1 == 1
        let leftCount = (n + 1) / 2
        let rightCount = n - leftCount
        return .split(left: build(leftCount, parentVertical: vertical),
                      right: build(rightCount, parentVertical: vertical),
                      vertical: vertical)
    }
    return build(count, parentVertical: nil)
}

/// Check that every split whose children are both leaves uses the preferred orientation.
private func respectsPreference(_ tree: BSPTree, prefer: SplitPreference) -> Bool {
    switch tree {
    case .leaf: return true
    case .split(let l, let r, let v, _):
        if case .leaf = l, case .leaf = r {
            switch prefer {
            case .none: return true
            case .vertical: return v
            case .horizontal: return !v
            }
        }
        return respectsPreference(l, prefer: prefer) && respectsPreference(r, prefer: prefer)
    }
}

private func alternates(_ tree: BSPTree, parentVertical: Bool? = nil) -> Bool {
    switch tree {
    case .leaf: return true
    case .split(let l, let r, let v, _):
        if let pv = parentVertical, pv == v { return false }
        return alternates(l, parentVertical: v) && alternates(r, parentVertical: v)
    }
}

/// Replace placeholder leaf IDs (in tree-order) with the given window IDs.
private func assignIDs(_ tree: BSPTree, ids: [UInt32]) -> BSPTree {
    var idx = 0
    func walk(_ node: BSPTree) -> BSPTree {
        switch node {
        case .leaf:
            let id = ids[idx]
            idx += 1
            return .leaf(id: id)
        case .split(let l, let r, let v, let ratio):
            return .split(left: walk(l), right: walk(r), vertical: v, ratio: ratio)
        }
    }
    return walk(tree)
}

private func l2Cost(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let dx = a.midX - b.midX
    let dy = a.midY - b.midY
    let dw = a.width - b.width
    let dh = a.height - b.height
    return dx * dx + dy * dy + dw * dw + dh * dh
}

/// Greedily assign windows to tile slots by closest match.
/// Returns (assignment, totalCost) where assignment[i] is the window index for tile i.
private func greedyMatch(tileFrames: [CGRect], windowFrames: [CGRect]) -> (assignment: [Int], cost: CGFloat) {
    let n = tileFrames.count
    var pairs: [(tile: Int, window: Int, cost: CGFloat)] = []
    for t in 0..<n {
        for w in 0..<n {
            pairs.append((t, w, l2Cost(tileFrames[t], windowFrames[w])))
        }
    }
    pairs.sort { $0.cost < $1.cost }

    var assignedTiles = Set<Int>()
    var assignedWindows = Set<Int>()
    var assignment = [Int](repeating: 0, count: n)
    var totalCost: CGFloat = 0

    for pair in pairs {
        guard !assignedTiles.contains(pair.tile), !assignedWindows.contains(pair.window) else { continue }
        assignment[pair.tile] = pair.window
        assignedTiles.insert(pair.tile)
        assignedWindows.insert(pair.window)
        totalCost += pair.cost
        if assignedTiles.count == n { break }
    }

    return (assignment, totalCost)
}

/// Build the BSP tree that best matches the current window positions.
func buildBSPTreeFitting(windows: [ManagedWindow], rect: CGRect, gap: CGFloat, prefer: SplitPreference = .none) -> BSPTree? {
    let n = windows.count
    guard n > 0 else { return nil }
    if n == 1 { return .leaf(id: windows[0].id) }

    let windowFrames = windows.map { $0.frame }
    let internalNodes = n - 1
    let configCount = 1 << internalNodes

    var bestTree: BSPTree?
    var bestCost: CGFloat = .infinity

    for mask in 0..<UInt32(configCount) {
        let template = buildTemplate(count: n, splitMask: mask)
        guard alternates(template), respectsPreference(template, prefer: prefer) else { continue }
        let tileFrames = template.computeFrames(rect: rect, gap: gap).map { $0.1 }
        let (assignment, cost) = greedyMatch(tileFrames: tileFrames, windowFrames: windowFrames)
        debug("tile: topology mask=\(mask) cost=\(cost)")
        if cost < bestCost {
            bestCost = cost
            let orderedIDs = (0..<n).map { windows[assignment[$0]].id }
            bestTree = assignIDs(template, ids: orderedIDs)
        }
    }

    return bestTree
}
