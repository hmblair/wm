import CoreGraphics

enum Direction { case left, right, up, down }

func directionFromKeyCode(_ keyCode: UInt16) -> Direction? {
    switch keyCode {
    case 123: return .left
    case 124: return .right
    case 125: return .down
    case 126: return .up
    default: return nil
    }
}

func nearestWindow(from source: CGRect, direction: Direction, among windows: [WindowInfo]) -> WindowInfo? {
    let center = CGPoint(x: source.midX, y: source.midY)
    var best: WindowInfo?
    var bestDist = CGFloat.infinity

    for win in windows {
        let wc = CGPoint(x: win.frame.midX, y: win.frame.midY)
        let dx = wc.x - center.x
        let dy = wc.y - center.y

        let inDirection: Bool
        switch direction {
        case .left:  inDirection = dx < -10
        case .right: inDirection = dx > 10
        case .up:    inDirection = dy < -10
        case .down:  inDirection = dy > 10
        }
        guard inDirection else { continue }

        let dist = dx * dx + dy * dy
        if dist < bestDist {
            bestDist = dist
            best = win
        }
    }
    return best
}
