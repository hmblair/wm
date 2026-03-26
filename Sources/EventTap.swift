import Cocoa
import CoreGraphics

struct PendingKeyCommand {
    let direction: Direction
    let swap: Bool
}

var pendingKeyCommands: [PendingKeyCommand] = []
var pendingMoveToSpace: [Int] = []
var pendingRotate = false

var globalTap: CFMachPort?

func handleEvent(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        warn("event tap re-enabled after system disable")
        if let tap = globalTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    if type == .mouseMoved {
        lastMousePosition = event.location
    } else if type == .keyDown && config.keybindings.enabled {
        let flags = event.flags
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if let direction = directionFromKeyCode(keyCode) {
            if config.keybindings.swapModifier.matches(flags) {
                pendingKeyCommands.append(PendingKeyCommand(direction: direction, swap: true))
                return nil
            } else if config.keybindings.focusModifier.matches(flags) {
                pendingKeyCommands.append(PendingKeyCommand(direction: direction, swap: false))
                return nil
            }
        }
        if keyCode == kVK_ANSI_R && config.keybindings.swapModifier.matches(flags) {
            pendingRotate = true
            return nil
        }
        if let spaceIndex = spaceIndexFromKeyCode(keyCode),
           config.keybindings.moveToSpaceModifier.matches(flags) {
            pendingMoveToSpace.append(spaceIndex)
            return nil
        }
    }

    return Unmanaged.passUnretained(event)
}

func createEventTap(eventMask: CGEventMask, maxRetries: Int = 10, baseDelay: UInt32 = 500_000) -> CFMachPort {
    for attempt in 0..<maxRetries {
        if let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: handleEvent, userInfo: nil
        ) {
            if attempt > 0 {
                log("event tap created after \(attempt + 1) attempts")
            }
            return tap
        }
        let delay = baseDelay * UInt32(1 << min(attempt, 4))
        warn("event tap failed (attempt \(attempt + 1)/\(maxRetries)), retrying...")
        usleep(delay)
    }
    warn("failed to create event tap after \(maxRetries) attempts — grant accessibility permissions")
    exit(1)
}
