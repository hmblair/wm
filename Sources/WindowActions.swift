import Cocoa
import ApplicationServices

private let sizeTolerance: CGFloat = 2

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
    // Clamp frame to minimum size (from popups or other constraints), centered in tile
    let minW = max(frame.width, win.minSize.width)
    let minH = max(frame.height, win.minSize.height)
    let clampedFrame = CGRect(
        x: frame.origin.x - (minW - frame.width) / 2,
        y: frame.origin.y - (minH - frame.height) / 2,
        width: minW, height: minH
    )

    var position = clampedFrame.origin
    var size = clampedFrame.size
    if let posValue = AXValueCreate(.cgPoint, &position) {
        AXUIElementSetAttributeValue(win.axWindow, kAXPositionAttribute as CFString, posValue)
    }
    if let sizeValue = AXValueCreate(.cgSize, &size) {
        AXUIElementSetAttributeValue(win.axWindow, kAXSizeAttribute as CFString, sizeValue)
    }

    // Read back actual size — the window may have refused to resize further
    var actualSizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(win.axWindow, kAXSizeAttribute as CFString, &actualSizeRef) == .success,
          let sRef = actualSizeRef else {
        win.frame = clampedFrame
        return
    }
    var actualSize = CGSize.zero
    AXValueGetValue(sRef as! AXValue, .cgSize, &actualSize)

    let dw = clampedFrame.width - actualSize.width
    let dh = clampedFrame.height - actualSize.height
    if dw > sizeTolerance || dh > sizeTolerance {
        var centered = CGPoint(x: clampedFrame.origin.x + dw / 2, y: clampedFrame.origin.y + dh / 2)
        if let posValue = AXValueCreate(.cgPoint, &centered) {
            AXUIElementSetAttributeValue(win.axWindow, kAXPositionAttribute as CFString, posValue)
        }
        win.frame = CGRect(origin: centered, size: actualSize)
    } else {
        win.frame = clampedFrame
    }
}

func warpMouse(to frame: CGRect) {
    let center = CGPoint(x: frame.midX, y: frame.midY)
    log("warp mouse to \(Int(center.x)),\(Int(center.y))")
    CGWarpMouseCursorPosition(center)
    lastMousePosition = center
}
