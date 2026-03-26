import Cocoa
import ApplicationServices

enum FocusAction {
    case window(ManagedWindow)
    case activate(NSRunningApplication)
}

func executeFocus(_ action: FocusAction) {
    switch action {
    case .window(let win):
        log("exec: focusWindow [\(win.id)] (\(win.name))")
        if let runningApp = NSRunningApplication(processIdentifier: win.pid) {
            let ok = runningApp.activate()
            log("  activate pid \(win.pid) (\(win.name)): \(ok)")
        }
        let raiseErr = AXUIElementPerformAction(win.axWindow, kAXRaiseAction as CFString)
        let focusErr = AXUIElementSetAttributeValue(win.axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if raiseErr != .success || focusErr != .success {
            log("  AX focus [\(win.id)]: raise=\(raiseErr.rawValue) focused=\(focusErr.rawValue)")
        }
    case .activate(let app):
        log("exec: activateApp \(app.localizedName ?? "?") (pid \(app.processIdentifier))")
        app.activate()
    }
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
}
