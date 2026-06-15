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

func visibleFrame(for screen: NSScreen) -> CGRect {
    let visible = screen.visibleFrame
    // AppKit's global coordinate origin is the bottom-left of the primary screen.
    // Quartz/CG's origin is the top-left of the primary screen. Flip around the
    // primary screen's height so external monitors get the correct y-offset.
    let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
    let y = primaryHeight - visible.maxY
    return CGRect(x: visible.minX, y: y, width: visible.width, height: visible.height)
}
