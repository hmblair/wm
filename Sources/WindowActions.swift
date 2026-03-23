import Cocoa
import ApplicationServices

func focusWindow(_ win: WindowInfo) {
    if let runningApp = NSRunningApplication(processIdentifier: win.pid) {
        runningApp.activate()
    }

    guard let axWindow = findAXWindow(for: win) else {
        log("AX window not found for CG window \(win.id) (\(win.name))")
        return
    }

    AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
}

func setWindowFrame(_ win: WindowInfo, frame: CGRect) {
    guard let axWindow = findAXWindow(for: win) else {
        log("setWindowFrame: AX window not found for \(win.id) (\(win.name))")
        return
    }

    var position = frame.origin
    var size = CGSize(width: frame.width, height: frame.height)
    if let posValue = AXValueCreate(.cgPoint, &position) {
        AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)
    }
    if let sizeValue = AXValueCreate(.cgSize, &size) {
        AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
    }
}

func warpMouse(to frame: CGRect) {
    let center = CGPoint(x: frame.midX, y: frame.midY)
    log("warp mouse to \(Int(center.x)),\(Int(center.y))")
    CGWarpMouseCursorPosition(center)
    lastMousePosition = center
}
