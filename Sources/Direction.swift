import CoreGraphics

enum Direction { case left, right, up, down }

private let kVK_LeftArrow: UInt16 = 123
private let kVK_RightArrow: UInt16 = 124
private let kVK_DownArrow: UInt16 = 125
private let kVK_UpArrow: UInt16 = 126

func directionFromKeyCode(_ keyCode: UInt16) -> Direction? {
    switch keyCode {
    case kVK_LeftArrow:  return .left
    case kVK_RightArrow: return .right
    case kVK_DownArrow:  return .down
    case kVK_UpArrow:    return .up
    default: return nil
    }
}

private let directionThreshold: CGFloat = 10

func nearestWindow(from source: CGRect, direction: Direction, among windows: [ManagedWindow]) -> ManagedWindow? {
    let center = CGPoint(x: source.midX, y: source.midY)
    var best: ManagedWindow?
    var bestDist = CGFloat.infinity

    for win in windows {
        let wc = CGPoint(x: win.frame.midX, y: win.frame.midY)
        let dx = wc.x - center.x
        let dy = wc.y - center.y

        let inDirection: Bool
        switch direction {
        case .left:  inDirection = dx < -directionThreshold
        case .right: inDirection = dx > directionThreshold
        case .up:    inDirection = dy < -directionThreshold
        case .down:  inDirection = dy > directionThreshold
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
