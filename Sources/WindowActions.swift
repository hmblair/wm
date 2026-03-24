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

    // Read back actual size — app may enforce a maximum
    var actualSizeRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(win.axWindow, kAXSizeAttribute as CFString, &actualSizeRef) == .success,
       let sRef = actualSizeRef {
        var readBack = CGSize.zero
        AXValueGetValue(sRef as! AXValue, .cgSize, &readBack)
        let dw = frame.width - readBack.width
        let dh = frame.height - readBack.height
        if dw > frameTolerance || dh > frameTolerance {
            win.actualSize = readBack
        }
    }

    win.frame = frame
}

func warpMouse(to frame: CGRect) {
    let center = CGPoint(x: frame.midX, y: frame.midY)
    log("warp mouse to \(Int(center.x)),\(Int(center.y))")
    CGWarpMouseCursorPosition(center)
    lastMousePosition = center
}
