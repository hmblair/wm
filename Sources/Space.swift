import Cocoa
import ApplicationServices

typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

private let skylight: UnsafeMutableRawPointer = {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else {
        fatalError("Failed to load SkyLight framework")
    }
    return handle
}()

private let _SLSMainConnectionID: @convention(c) () -> CGSConnectionID = {
    unsafeBitCast(dlsym(skylight, "SLSMainConnectionID")!, to: (@convention(c) () -> CGSConnectionID).self)
}()

private let _SLSGetActiveSpace: @convention(c) (CGSConnectionID) -> CGSSpaceID = {
    unsafeBitCast(dlsym(skylight, "SLSGetActiveSpace")!, to: (@convention(c) (CGSConnectionID) -> CGSSpaceID).self)
}()

let slsConnectionID = _SLSMainConnectionID()

private let _SLSCopySpacesForWindows: @convention(c) (CGSConnectionID, UInt32, CFArray) -> CFArray? = {
    unsafeBitCast(dlsym(skylight, "SLSCopySpacesForWindows")!, to: (@convention(c) (CGSConnectionID, UInt32, CFArray) -> CFArray?).self)
}()

func activeSpaceID() -> CGSSpaceID {
    return _SLSGetActiveSpace(slsConnectionID)
}

private let _SLSCopyManagedDisplaySpaces: @convention(c) (CGSConnectionID) -> CFArray? = {
    unsafeBitCast(dlsym(skylight, "SLSCopyManagedDisplaySpaces")!, to: (@convention(c) (CGSConnectionID) -> CFArray?).self)
}()

func spaceForWindow(_ windowID: UInt32) -> CGSSpaceID? {
    let maskAll: UInt32 = 0x7 // kCGSAllSpacesMask: current + others + fullscreen
    guard let spaces = _SLSCopySpacesForWindows(slsConnectionID, maskAll, [windowID] as CFArray) as? [CGSSpaceID],
          let first = spaces.first else { return nil }
    return first
}

func orderedSpaceIDs() -> [CGSSpaceID] {
    guard let displays = _SLSCopyManagedDisplaySpaces(slsConnectionID) as? [[String: Any]] else { return [] }
    var result: [CGSSpaceID] = []
    for display in displays {
        guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
        for space in spaces {
            guard let type = space["type"] as? Int, type == 0 else { continue }
            if let id = space["id64"] as? CGSSpaceID {
                result.append(id)
            }
        }
    }
    return result
}

let spaceKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

func postKeyEvent(keyCode: UInt16, flags: CGEventFlags = .maskControl) {
    let source = CGEventSource(stateID: .hidSystemState)
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)!
    keyDown.flags = flags
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)!
    keyUp.flags = flags
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
}

func moveWindowToSpace(axWindow: AXUIElement, spaceIndex: Int) {
    let pos = axPosition(of: axWindow)
    let size = axSize(of: axWindow)

    let titleBar = CGPoint(x: pos.x + size.width / 2, y: pos.y + 15)
    let source = CGEventSource(stateID: .hidSystemState)

    CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: titleBar, mouseButton: .left)!
        .post(tap: .cghidEventTap)

    guard spaceIndex < spaceKeyCodes.count else { return }
    postKeyEvent(keyCode: spaceKeyCodes[spaceIndex])

    CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: titleBar, mouseButton: .left)!
        .post(tap: .cghidEventTap)
}
