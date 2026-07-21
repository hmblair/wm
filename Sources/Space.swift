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

struct SpaceInfo {
    let id: CGSSpaceID
    let isFullScreen: Bool
}

func orderedSpaces() -> [SpaceInfo] {
    guard let displays = _SLSCopyManagedDisplaySpaces(slsConnectionID) as? [[String: Any]] else { return [] }
    var result: [SpaceInfo] = []
    for display in displays {
        guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
        for space in spaces {
            guard let type = space["type"] as? Int, type == 0 || type == 4 else { continue }
            if let id = space["id64"] as? CGSSpaceID {
                result.append(SpaceInfo(id: id, isFullScreen: type == 4))
            }
        }
    }
    return result
}

func orderedSpaceIDs() -> [CGSSpaceID] {
    return orderedSpaces().map { $0.id }
}

func postKeyEvent(keyCode: UInt16, flags: CGEventFlags = .maskControl) {
    let source = CGEventSource(stateID: .hidSystemState)
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)!
    keyDown.flags = flags
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)!
    keyUp.flags = flags
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
}

func appNameForSpace(_ spaceID: CGSSpaceID) -> String? {
    guard let infoList = CGWindowListCopyWindowInfo(
        [.optionAll, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else { return nil }

    for info in infoList {
        guard let wid = info[kCGWindowNumber as String] as? UInt32,
              let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
              let name = info[kCGWindowOwnerName as String] as? String
        else { continue }
        if spaceForWindow(wid) == spaceID { return name }
    }
    return nil
}

func moveWindowToSpace(axWindow: AXUIElement, spaceIndex: Int) {
    let pos = axPosition(of: axWindow)
    let size = axSize(of: axWindow)

    // Grab point for the synthetic drag: horizontally centered, and far enough
    // below the top edge to land on the title bar rather than a window control.
    let titleBarGrabInset: CGFloat = 15
    let titleBar = CGPoint(x: pos.x + size.width / 2, y: pos.y + titleBarGrabInset)
    let source = CGEventSource(stateID: .hidSystemState)

    CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: titleBar, mouseButton: .left)!
        .post(tap: .cghidEventTap)

    guard spaceIndex < spaceKeyCodes.count else { return }
    postKeyEvent(keyCode: spaceKeyCodes[spaceIndex],
                 flags: config.keybindings.spaceSwitchModifier.eventFlags)

    CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: titleBar, mouseButton: .left)!
        .post(tap: .cghidEventTap)
}
