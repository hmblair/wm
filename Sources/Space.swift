import Foundation
import CoreGraphics

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

func spaceForWindow(_ windowID: UInt32) -> CGSSpaceID? {
    let maskAll: UInt32 = 0x7
    guard let spaces = _SLSCopySpacesForWindows(slsConnectionID, maskAll, [windowID] as CFArray) as? [CGSSpaceID],
          let first = spaces.first else { return nil }
    return first
}
