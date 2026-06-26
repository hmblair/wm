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

private func updateConstraint(current: CGFloat?, actual: CGFloat) -> (CGFloat, Bool) {
    return (actual, current != actual)
}

private func detectSizeConstraints(win: ManagedWindow, requested: CGRect,
                                   beforeSize: CGSize) -> Bool {
    let actual = axSize(of: win.axWindow)

    // Constraints are inferred from a window falling short of the size we asked
    // for, which only reveals a real limit if the window is actually acting on
    // our requests. A live window lands at the position we set even when it
    // can't reach the requested size — that mismatch is its true min/max. A
    // window still launching or restoring its windows — e.g. just after logging
    // back in — ignores the position too and sits at its restored, often
    // minimum, size; reading a maximum off that would clamp it there on every
    // later tick until it is dropped from managedWindows (by switching Spaces)
    // and re-added fresh. So require evidence the window cooperated: it either
    // honored the requested position, or resized at all. Comparing position
    // against the request (not against where it started) still recognizes a
    // window that was already sitting at its constrained position.
    let actualPos = axPosition(of: win.axWindow)
    let honorsPosition = abs(actualPos.x - requested.origin.x) <= frameTolerance
                      && abs(actualPos.y - requested.origin.y) <= frameTolerance
    let resized = abs(actual.width - beforeSize.width) > frameTolerance
               || abs(actual.height - beforeSize.height) > frameTolerance
    guard honorsPosition || resized else { return false }

    let dw = requested.width - actual.width
    let dh = requested.height - actual.height
    var discovered = false

    if dw > frameTolerance {
        let (val, changed) = updateConstraint(current: win.maxSize?.width, actual: actual.width)
        win.maxSize = CGSize(width: val, height: win.maxSize?.height ?? .infinity)
        discovered = discovered || changed
    }
    if dh > frameTolerance {
        let (val, changed) = updateConstraint(current: win.maxSize?.height, actual: actual.height)
        win.maxSize = CGSize(width: win.maxSize?.width ?? .infinity, height: val)
        discovered = discovered || changed
    }
    if -dw > frameTolerance {
        let (val, changed) = updateConstraint(current: win.minSize?.width, actual: actual.width)
        win.minSize = CGSize(width: val, height: win.minSize?.height ?? 0)
        discovered = discovered || changed
    }
    if -dh > frameTolerance {
        let (val, changed) = updateConstraint(current: win.minSize?.height, actual: actual.height)
        win.minSize = CGSize(width: win.minSize?.width ?? 0, height: val)
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
    let beforeSize = axSize(of: win.axWindow)

    let posErr = setAXPosition(of: win.axWindow, to: frame.origin)
    if posErr != .success {
        warn("tile: AX set position failed for [\(win.id)] (\(win.name)): \(posErr.rawValue)")
    }
    let sizeErr = setAXSize(of: win.axWindow, to: frame.size)
    if sizeErr != .success {
        warn("tile: AX set size failed for [\(win.id)] (\(win.name)): \(sizeErr.rawValue)")
    }

    let constraintDiscovered = detectSizeConstraints(
        win: win, requested: frame, beforeSize: beforeSize)
    win.frame = frame
    return constraintDiscovered
}

func warpMouse(to frame: CGRect) {
    let center = CGPoint(x: frame.midX, y: frame.midY)
    debug("warp: mouse to \(Int(center.x)),\(Int(center.y))")
    CGWarpMouseCursorPosition(center)
}
