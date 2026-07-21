import CoreGraphics

enum Direction { case left, right, up, down }

// Virtual keycodes (from Events.h)
let kVK_ANSI_R: UInt16 = 15
let kVK_LeftArrow: UInt16 = 123
let kVK_RightArrow: UInt16 = 124
let kVK_DownArrow: UInt16 = 125
let kVK_UpArrow: UInt16 = 126

func directionFromKeyCode(_ keyCode: UInt16) -> Direction? {
    switch keyCode {
    case kVK_LeftArrow:  return .left
    case kVK_RightArrow: return .right
    case kVK_DownArrow:  return .down
    case kVK_UpArrow:    return .up
    default: return nil
    }
}

// Virtual keycodes for the number-row digits 1-9, in that order. This is the
// single source of truth: it drives the move-to-space / space-switch key events,
// the Switch-to-Desktop shortcut registration, and the keycode → space-index
// lookup below.
let spaceKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

func spaceIndexFromKeyCode(_ keyCode: UInt16) -> Int? {
    return spaceKeyCodes.firstIndex(of: keyCode)
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
