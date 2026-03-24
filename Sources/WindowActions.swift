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

func setWindowFrame(_ win: ManagedWindow, frame: CGRect, fast: Bool = false) {
    // Skip if the window is already at the target frame
    if abs(win.frame.origin.x - frame.origin.x) <= sizeTolerance
        && abs(win.frame.origin.y - frame.origin.y) <= sizeTolerance
        && abs(win.frame.width - frame.width) <= sizeTolerance
        && abs(win.frame.height - frame.height) <= sizeTolerance {
        return
    }

    if fast {
        // Fast path: position first to avoid the window briefly extending in the wrong
        // direction, then size. No read-back or min-size clamping.
        var position = frame.origin
        if let posValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(win.axWindow, kAXPositionAttribute as CFString, posValue)
        }
        var size = frame.size
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(win.axWindow, kAXSizeAttribute as CFString, sizeValue)
        }
        win.frame = frame
        return
    }

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
