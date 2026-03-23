import Cocoa
import ApplicationServices

func focusWindow(_ win: ManagedWindow) {
    if let runningApp = NSRunningApplication(processIdentifier: win.pid) {
        runningApp.activate()
    }

    AXUIElementPerformAction(win.axWindow, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(win.axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    lastFocusedWindow = win.id
    lastSelfFocusTime = mach_absolute_time()
}

func setWindowFrame(_ win: ManagedWindow, frame: CGRect) {
    var position = frame.origin
    var size = CGSize(width: frame.width, height: frame.height)
    if let posValue = AXValueCreate(.cgPoint, &position) {
        AXUIElementSetAttributeValue(win.axWindow, kAXPositionAttribute as CFString, posValue)
    }
    if let sizeValue = AXValueCreate(.cgSize, &size) {
        AXUIElementSetAttributeValue(win.axWindow, kAXSizeAttribute as CFString, sizeValue)
    }

    // Read back actual size — the window may have refused to resize
    var actualSizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(win.axWindow, kAXSizeAttribute as CFString, &actualSizeRef) == .success,
          let sRef = actualSizeRef else {
        win.frame = frame
        return
    }
    var actualSize = CGSize.zero
    AXValueGetValue(sRef as! AXValue, .cgSize, &actualSize)

    let dw = frame.width - actualSize.width
    let dh = frame.height - actualSize.height
    if dw > 2 || dh > 2 {
        var centered = CGPoint(x: frame.origin.x + dw / 2, y: frame.origin.y + dh / 2)
        if let posValue = AXValueCreate(.cgPoint, &centered) {
            AXUIElementSetAttributeValue(win.axWindow, kAXPositionAttribute as CFString, posValue)
        }
        win.frame = CGRect(origin: centered, size: actualSize)
    } else {
        win.frame = frame
    }
}

func warpMouse(to frame: CGRect) {
    let center = CGPoint(x: frame.midX, y: frame.midY)
    log("warp mouse to \(Int(center.x)),\(Int(center.y))")
    CGWarpMouseCursorPosition(center)
    lastMousePosition = center
}
