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

    func computeFrames(rect: CGRect, gap: CGFloat) -> [(UInt32, CGRect)] {
        switch self {
        case .leaf(let id):
            return [(id, CGRect(x: rect.minX + gap, y: rect.minY + gap,
                                width: rect.width - 2 * gap, height: rect.height - 2 * gap))]
        case .split(let left, let right, let vertical, let ratio):
            let (leftRect, rightRect): (CGRect, CGRect)
            if vertical {
                let leftW = rect.width * ratio
                leftRect = CGRect(x: rect.minX, y: rect.minY, width: leftW, height: rect.height)
                rightRect = CGRect(x: rect.minX + leftW, y: rect.minY, width: rect.width - leftW, height: rect.height)
            } else {
                let leftH = rect.height * ratio
                leftRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: leftH)
                rightRect = CGRect(x: rect.minX, y: rect.minY + leftH, width: rect.width, height: rect.height - leftH)
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
        case .split(let l, let r, let v, let ratio):
            return .split(left: l.swappingWindows(id1, id2),
                          right: r.swappingWindows(id1, id2), vertical: v, ratio: ratio)
        }
    }

    struct CrossingResult {
        let focusedIsAlone: Bool
        let otherSideIDs: [UInt32]
    }

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

    /// Returns the minimum size this subtree needs along each axis,
    /// given the min sizes of individual windows.
    func minSize(minSizes: [UInt32: CGSize], gap: CGFloat) -> CGSize {
        switch self {
        case .leaf(let id):
            let ms = minSizes[id] ?? .zero
            return CGSize(width: ms.width + 2 * gap, height: ms.height + 2 * gap)
        case .split(let left, let right, let vertical, _):
            let lm = left.minSize(minSizes: minSizes, gap: gap)
            let rm = right.minSize(minSizes: minSizes, gap: gap)
            if vertical {
                return CGSize(width: lm.width + rm.width, height: max(lm.height, rm.height))
            } else {
                return CGSize(width: max(lm.width, rm.width), height: lm.height + rm.height)
            }
        }
    }

    /// Returns a new tree with split ratios adjusted so that each window
    /// gets at least its minimum size within the given rect.
    func adjustingRatios(rect: CGRect, minSizes: [UInt32: CGSize], gap: CGFloat) -> BSPTree {
        switch self {
        case .leaf:
            return self
        case .split(let left, let right, let vertical, let existingRatio):
            let lm = left.minSize(minSizes: minSizes, gap: gap)
            let rm = right.minSize(minSizes: minSizes, gap: gap)

            let total: CGFloat
            let leftMin: CGFloat
            let rightMin: CGFloat
            if vertical {
                total = rect.width
                leftMin = lm.width
                rightMin = rm.width
            } else {
                total = rect.height
                leftMin = lm.height
                rightMin = rm.height
            }

            // Preserve existing ratio, only clamp for minimum size constraints
            var ratio = existingRatio
            if total > 0 {
                let minRatio = leftMin / total
                let maxRatio = (total - rightMin) / total
                ratio = min(max(ratio, minRatio), maxRatio)
            }

            let (leftRect, rightRect): (CGRect, CGRect)
            if vertical {
                let leftW = total * ratio
                leftRect = CGRect(x: rect.minX, y: rect.minY, width: leftW, height: rect.height)
                rightRect = CGRect(x: rect.minX + leftW, y: rect.minY, width: total - leftW, height: rect.height)
            } else {
                let leftH = total * ratio
                leftRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: leftH)
                rightRect = CGRect(x: rect.minX, y: rect.minY + leftH, width: rect.width, height: total - leftH)
            }

            return .split(
                left: left.adjustingRatios(rect: leftRect, minSizes: minSizes, gap: gap),
                right: right.adjustingRatios(rect: rightRect, minSizes: minSizes, gap: gap),
                vertical: vertical,
                ratio: ratio
            )
        }
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
