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
    let full = screen.frame
    let visible = screen.visibleFrame
    let y = full.height - visible.maxY
    return CGRect(x: visible.minX, y: y, width: visible.width, height: visible.height)
}
