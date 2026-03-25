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

private let kVK_ANSI_1: UInt16 = 18
private let kVK_ANSI_2: UInt16 = 19
private let kVK_ANSI_3: UInt16 = 20
private let kVK_ANSI_4: UInt16 = 21
private let kVK_ANSI_5: UInt16 = 23
private let kVK_ANSI_6: UInt16 = 22
private let kVK_ANSI_7: UInt16 = 26
private let kVK_ANSI_8: UInt16 = 28
private let kVK_ANSI_9: UInt16 = 25

func spaceIndexFromKeyCode(_ keyCode: UInt16) -> Int? {
    switch keyCode {
    case kVK_ANSI_1: return 0
    case kVK_ANSI_2: return 1
    case kVK_ANSI_3: return 2
    case kVK_ANSI_4: return 3
    case kVK_ANSI_5: return 4
    case kVK_ANSI_6: return 5
    case kVK_ANSI_7: return 6
    case kVK_ANSI_8: return 7
    case kVK_ANSI_9: return 8
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
