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

private let _SLSWindowQueryWindows: @convention(c) (CGSConnectionID, CFArray, Int32) -> Unmanaged<CFTypeRef>? = {
    unsafeBitCast(dlsym(skylight, "SLSWindowQueryWindows")!, to: (@convention(c) (CGSConnectionID, CFArray, Int32) -> Unmanaged<CFTypeRef>?).self)
}()

private let _SLSWindowQueryResultCopyWindows: @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>? = {
    unsafeBitCast(dlsym(skylight, "SLSWindowQueryResultCopyWindows")!, to: (@convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?).self)
}()

private let _SLSWindowIteratorAdvance: @convention(c) (CFTypeRef) -> Bool = {
    unsafeBitCast(dlsym(skylight, "SLSWindowIteratorAdvance")!, to: (@convention(c) (CFTypeRef) -> Bool).self)
}()

private let _SLSWindowIteratorGetAttributes: @convention(c) (CFTypeRef) -> UInt64 = {
    unsafeBitCast(dlsym(skylight, "SLSWindowIteratorGetAttributes")!, to: (@convention(c) (CFTypeRef) -> UInt64).self)
}()

private let _SLSWindowIteratorGetWindowID: @convention(c) (CFTypeRef) -> UInt32 = {
    unsafeBitCast(dlsym(skylight, "SLSWindowIteratorGetWindowID")!, to: (@convention(c) (CFTypeRef) -> UInt32).self)
}()

// SkyLight window attribute that is set while a window is shown on its Space.
// It is unset for a window that its app has hidden without destroying it, such
// as a closed window that the app keeps for reuse.
private let shownWindowAttribute: UInt64 = 0x2

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

// Label for a Space whose app cannot be resolved.
let unknownSpaceLabel = "·"

// Returns each Space's Mission Control desktop number, in order, or nil for a
// native-fullscreen Space. Mission Control numbers only desktops.
func desktopNumbers(for spaces: [SpaceInfo]) -> [Int?] {
    var desktop = 0
    return spaces.map { space in
        if space.isFullScreen { return nil }
        desktop += 1
        return desktop
    }
}

// Returns a display label per Space, in order: desktops get their number, and a
// native-fullscreen Space gets the first letter of its app's name (or
// unknownSpaceLabel when the app cannot be resolved). Shared by `wm status` and
// the status bar.
func spaceLabels(for spaces: [SpaceInfo]) -> [String] {
    return zip(spaces, desktopNumbers(for: spaces)).map { space, number in
        if let number { return "\(number)" }
        return appNameForSpace(space.id).flatMap { $0.first.map(String.init) } ?? unknownSpaceLabel
    }
}

func postKeyEvent(keyCode: UInt16, flags: CGEventFlags) {
    let source = CGEventSource(stateID: .hidSystemState)
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)!
    keyDown.flags = flags
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)!
    keyUp.flags = flags
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
}

// A window at the standard layer and the name of the app that owns it.
private typealias StandardLayerWindow = (id: UInt32, appName: String)

// Lists the windows at the standard layer on every Space, front to back.
private func standardLayerWindows() -> [StandardLayerWindow] {
    guard let infoList = CGWindowListCopyWindowInfo(
        [.optionAll, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else { return [] }

    return infoList.compactMap { info in
        guard let wid = info[kCGWindowNumber as String] as? UInt32,
              let layer = info[kCGWindowLayer as String] as? Int, layer == standardWindowLayer,
              let name = info[kCGWindowOwnerName as String] as? String
        else { return nil }
        return (id: wid, appName: name)
    }
}

// Returns the IDs of the given windows that are shown on their Space.
private func shownWindowIDs(among windowIDs: [UInt32]) -> Set<UInt32> {
    guard !windowIDs.isEmpty,
          let query = _SLSWindowQueryWindows(
              slsConnectionID, windowIDs as CFArray, Int32(windowIDs.count))?.takeRetainedValue(),
          let iterator = _SLSWindowQueryResultCopyWindows(query)?.takeRetainedValue()
    else { return [] }

    var shown: Set<UInt32> = []
    while _SLSWindowIteratorAdvance(iterator) {
        if _SLSWindowIteratorGetAttributes(iterator) & shownWindowAttribute != 0 {
            shown.insert(_SLSWindowIteratorGetWindowID(iterator))
        }
    }
    return shown
}

// Lists the standard-layer windows that are shown on their Space, front to back.
private func shownStandardLayerWindows() -> [StandardLayerWindow] {
    let windows = standardLayerWindows()
    let shown = shownWindowIDs(among: windows.map { $0.id })
    return windows.filter { shown.contains($0.id) }
}

func appNameForSpace(_ spaceID: CGSSpaceID) -> String? {
    return shownStandardLayerWindows().first { spaceForWindow($0.id) == spaceID }?.appName
}

// An app and the number of its shown windows on one Space.
struct AppWindowCount {
    let appName: String
    var windowCount: Int
}

// Returns the apps with shown windows on each Space and their window counts,
// ordered by each app's frontmost window. Helper windows report no Space, so
// they are skipped.
func appWindowCountsBySpace() -> [CGSSpaceID: [AppWindowCount]] {
    var counts: [CGSSpaceID: [AppWindowCount]] = [:]
    for window in shownStandardLayerWindows() {
        guard let space = spaceForWindow(window.id) else { continue }
        countWindow(of: window.appName, in: &counts[space, default: []])
    }
    return counts
}

// Adds one window to the app's count, and lists the app if it is new.
private func countWindow(of appName: String, in apps: inout [AppWindowCount]) {
    if let i = apps.firstIndex(where: { $0.appName == appName }) {
        apps[i].windowCount += 1
    } else {
        apps.append(AppWindowCount(appName: appName, windowCount: 1))
    }
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
