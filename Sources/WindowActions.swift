import Cocoa
import ApplicationServices

func axPosition(of element: AXUIElement) -> CGPoint {
    var ref: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &ref)
    var point = CGPoint.zero
    if let r = ref { AXValueGetValue(r as! AXValue, .cgPoint, &point) }
    return point
}

func axSize(of element: AXUIElement) -> CGSize {
    var ref: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref)
    var size = CGSize.zero
    if let r = ref { AXValueGetValue(r as! AXValue, .cgSize, &size) }
    return size
}

@discardableResult
func setAXPosition(of element: AXUIElement, to point: CGPoint) -> AXError {
    var p = point
    guard let value = AXValueCreate(.cgPoint, &p) else { return .failure }
    return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
}

@discardableResult
func setAXSize(of element: AXUIElement, to size: CGSize) -> AXError {
    var s = size
    guard let value = AXValueCreate(.cgSize, &s) else { return .failure }
    return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
}

private func updateConstraint(current: CGFloat?, actual: CGFloat, unconstrained: CGFloat) -> (CGFloat?, Bool) {
    if current != actual { return (actual, true) }
    return (current, false)
}

private func detectSizeConstraints(win: ManagedWindow, requested: CGSize) -> Bool {
    let actual = axSize(of: win.axWindow)
    let dw = requested.width - actual.width
    let dh = requested.height - actual.height
    var discovered = false

    if dw > frameTolerance {
        let (val, changed) = updateConstraint(current: win.maxSize?.width, actual: actual.width, unconstrained: .infinity)
        win.maxSize = CGSize(width: val ?? .infinity, height: win.maxSize?.height ?? .infinity)
        discovered = discovered || changed
    }
    if dh > frameTolerance {
        let (val, changed) = updateConstraint(current: win.maxSize?.height, actual: actual.height, unconstrained: .infinity)
        win.maxSize = CGSize(width: win.maxSize?.width ?? .infinity, height: val ?? .infinity)
        discovered = discovered || changed
    }
    if -dw > frameTolerance {
        let (val, changed) = updateConstraint(current: win.minSize?.width, actual: actual.width, unconstrained: 0)
        win.minSize = CGSize(width: val ?? 0, height: win.minSize?.height ?? 0)
        discovered = discovered || changed
    }
    if -dh > frameTolerance {
        let (val, changed) = updateConstraint(current: win.minSize?.height, actual: actual.height, unconstrained: 0)
        win.minSize = CGSize(width: win.minSize?.width ?? 0, height: val ?? 0)
        discovered = discovered || changed
    }

    return discovered
}

enum FocusAction {
    case window(ManagedWindow)
    case activate(NSRunningApplication)
}

func executeFocus(_ action: FocusAction) {
    switch action {
    case .window(let win):
        debug("focus: window [\(win.id)] (\(win.name))")
        if let runningApp = NSRunningApplication(processIdentifier: win.pid) {
            let ok = runningApp.activate()
            debug("focus: activate pid \(win.pid) (\(win.name)): \(ok)")
        }
        let raiseErr = AXUIElementPerformAction(win.axWindow, kAXRaiseAction as CFString)
        let focusErr = AXUIElementSetAttributeValue(win.axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if raiseErr != .success || focusErr != .success {
            debug("focus: AX [\(win.id)] raise=\(raiseErr.rawValue) focused=\(focusErr.rawValue)")
        }
    case .activate(let app):
        debug("focus: activate \(app.localizedName ?? "?") (pid \(app.processIdentifier))")
        app.activate()
    }
}

@discardableResult
func setWindowFrame(_ win: ManagedWindow, frame: CGRect) -> Bool {
    let posErr = setAXPosition(of: win.axWindow, to: frame.origin)
    if posErr != .success {
        warn("tile: AX set position failed for [\(win.id)] (\(win.name)): \(posErr.rawValue)")
    }
    let sizeErr = setAXSize(of: win.axWindow, to: frame.size)
    if sizeErr != .success {
        warn("tile: AX set size failed for [\(win.id)] (\(win.name)): \(sizeErr.rawValue)")
    }

    let constraintDiscovered = detectSizeConstraints(win: win, requested: frame.size)
    win.frame = frame
    return constraintDiscovered
}

func warpMouse(to frame: CGRect) {
    let center = CGPoint(x: frame.midX, y: frame.midY)
    debug("warp: mouse to \(Int(center.x)),\(Int(center.y))")
    CGWarpMouseCursorPosition(center)
}
