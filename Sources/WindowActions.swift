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
    var size = frame.size
    if let posValue = AXValueCreate(.cgPoint, &position) {
        let err = AXUIElementSetAttributeValue(win.axWindow, kAXPositionAttribute as CFString, posValue)
        if err != .success {
            warn("AX set position failed for [\(win.id)] (\(win.name)): \(err.rawValue)")
        }
    }
    if let sizeValue = AXValueCreate(.cgSize, &size) {
        let err = AXUIElementSetAttributeValue(win.axWindow, kAXSizeAttribute as CFString, sizeValue)
        if err != .success {
            warn("AX set size failed for [\(win.id)] (\(win.name)): \(err.rawValue)")
        }
    }

    // Read back actual size — app may enforce a minimum
    var actualSizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(win.axWindow, kAXSizeAttribute as CFString, &actualSizeRef) == .success,
          let sRef = actualSizeRef else {
        win.frame = frame
        return
    }
    var actualSize = CGSize.zero
    AXValueGetValue(sRef as! AXValue, .cgSize, &actualSize)

    // If the app gave us a smaller size, center the window in the tile
    let dw = frame.width - actualSize.width
    let dh = frame.height - actualSize.height
    if dw > frameTolerance || dh > frameTolerance {
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
