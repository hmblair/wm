import Cocoa
import ApplicationServices

func focusWindow(_ win: WindowInfo) {
    if let runningApp = NSRunningApplication(processIdentifier: win.pid) {
        runningApp.activate()
    }

    AXUIElementPerformAction(win.axWindow, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(win.axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    lastFocusedWindow = win.id
    lastSelfFocusTime = mach_absolute_time()
}

func setWindowFrame(_ win: WindowInfo, frame: CGRect) {
    var position = frame.origin
    var size = CGSize(width: frame.width, height: frame.height)
    if let posValue = AXValueCreate(.cgPoint, &position) {
        AXUIElementSetAttributeValue(win.axWindow, kAXPositionAttribute as CFString, posValue)
    }
    if let sizeValue = AXValueCreate(.cgSize, &size) {
        AXUIElementSetAttributeValue(win.axWindow, kAXSizeAttribute as CFString, sizeValue)
    }
}

func warpMouse(to frame: CGRect) {
    let center = CGPoint(x: frame.midX, y: frame.midY)
    log("warp mouse to \(Int(center.x)),\(Int(center.y))")
    CGWarpMouseCursorPosition(center)
    lastMousePosition = center
}
