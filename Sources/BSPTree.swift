import CoreGraphics

indirect enum BSPTree {
    case leaf(id: UInt32)
    case split(left: BSPTree, right: BSPTree, vertical: Bool)

    var windowIDs: [UInt32] {
        switch self {
        case .leaf(let id): return [id]
        case .split(let l, let r, _): return l.windowIDs + r.windowIDs
        }
    }

    func contains(id: UInt32) -> Bool {
        switch self {
        case .leaf(let wid): return wid == id
        case .split(let l, let r, _): return l.contains(id: id) || r.contains(id: id)
        }
    }

    func computeFrames(rect: CGRect, gap: CGFloat) -> [(UInt32, CGRect)] {
        switch self {
        case .leaf(let id):
            return [(id, CGRect(x: rect.minX + gap, y: rect.minY + gap,
                                width: rect.width - 2 * gap, height: rect.height - 2 * gap))]
        case .split(let left, let right, let vertical):
            let (leftRect, rightRect): (CGRect, CGRect)
            if vertical {
                let halfW = rect.width / 2
                leftRect = CGRect(x: rect.minX, y: rect.minY, width: halfW, height: rect.height)
                rightRect = CGRect(x: rect.minX + halfW, y: rect.minY, width: halfW, height: rect.height)
            } else {
                let halfH = rect.height / 2
                leftRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: halfH)
                rightRect = CGRect(x: rect.minX, y: rect.minY + halfH, width: rect.width, height: halfH)
            }
            return left.computeFrames(rect: leftRect, gap: gap) + right.computeFrames(rect: rightRect, gap: gap)
        }
    }

    func swappingWindows(_ id1: UInt32, _ id2: UInt32) -> BSPTree {
        switch self {
        case .leaf(let id):
            if id == id1 { return .leaf(id: id2) }
            if id == id2 { return .leaf(id: id1) }
            return self
        case .split(let l, let r, let v):
            return .split(left: l.swappingWindows(id1, id2),
                          right: r.swappingWindows(id1, id2), vertical: v)
        }
    }

    struct CrossingResult {
        let focusedIsAlone: Bool
        let otherSideIDs: [UInt32]
    }

    func findCrossingSplit(windowID: UInt32, direction: Direction) -> CrossingResult? {
        guard case .split(let left, let right, let vertical) = self else { return nil }

        let inLeft = left.contains(id: windowID)
        guard inLeft || right.contains(id: windowID) else { return nil }

        let child = inLeft ? left : right
        if let deeper = child.findCrossingSplit(windowID: windowID, direction: direction) {
            return deeper
        }

        let crosses: Bool
        switch direction {
        case .right: crosses = vertical && inLeft
        case .left:  crosses = vertical && !inLeft
        case .down:  crosses = !vertical && inLeft
        case .up:    crosses = !vertical && !inLeft
        }
        guard crosses else { return nil }

        let mySide = inLeft ? left : right
        let otherSide = inLeft ? right : left
        let isAlone: Bool
        if case .leaf = mySide { isAlone = true } else { isAlone = false }

        return CrossingResult(focusedIsAlone: isAlone, otherSideIDs: otherSide.windowIDs)
    }

    func swappingChildrenForCrossing(windowID: UInt32, direction: Direction) -> BSPTree? {
        guard case .split(let left, let right, let vertical) = self else { return nil }

        let inLeft = left.contains(id: windowID)
        guard inLeft || right.contains(id: windowID) else { return nil }

        if inLeft {
            if let newLeft = left.swappingChildrenForCrossing(windowID: windowID, direction: direction) {
                return .split(left: newLeft, right: right, vertical: vertical)
            }
        } else {
            if let newRight = right.swappingChildrenForCrossing(windowID: windowID, direction: direction) {
                return .split(left: left, right: newRight, vertical: vertical)
            }
        }

        let crosses: Bool
        switch direction {
        case .right: crosses = vertical && inLeft
        case .left:  crosses = vertical && !inLeft
        case .down:  crosses = !vertical && inLeft
        case .up:    crosses = !vertical && !inLeft
        }

        if crosses {
            return .split(left: right, right: left, vertical: vertical)
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
