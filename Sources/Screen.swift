import Cocoa

func displayID(for point: CGPoint) -> CGDirectDisplayID {
    var displayID: CGDirectDisplayID = 0
    var count: UInt32 = 0
    CGGetDisplaysWithPoint(point, 1, &displayID, &count)
    return count > 0 ? displayID : CGMainDisplayID()
}

func displayIDForScreen(_ screen: NSScreen) -> CGDirectDisplayID {
    return screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
}

func screenForDisplayID(_ did: CGDirectDisplayID) -> NSScreen? {
    return NSScreen.screens.first(where: { displayIDForScreen($0) == did })
}

// AppKit's global coordinate origin is the bottom-left of the primary screen;
// Quartz/CG's is the top-left. Both flips mirror around the primary screen's
// height (so external monitors get the correct offset) and are their own
// inverse, converting in either direction.
func flipVertical(_ rect: CGRect) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: rect.minX, y: primaryHeight - rect.maxY,
                  width: rect.width, height: rect.height)
}

func flipVertical(_ point: CGPoint) -> CGPoint {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGPoint(x: point.x, y: primaryHeight - point.y)
}

func visibleFrame(for screen: NSScreen) -> CGRect {
    return flipVertical(screen.visibleFrame)
}
