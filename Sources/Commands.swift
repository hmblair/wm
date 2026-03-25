import Cocoa
import ApplicationServices

func computeSwap(
    managed: ManagedWindow, direction: Direction,
    spaceID: CGSSpaceID, plan: inout TickPlan
) {
    guard tilingEnabled else { return }

    let focusCenter = CGPoint(x: managed.frame.midX, y: managed.frame.midY)
    let did = displayID(for: focusCenter)
    let key = DisplaySpaceKey(displayID: did, spaceID: spaceID)
    guard let tree = plan.updatedTrees[key] else { return }
    guard let result = tree.findCrossingSplit(windowID: managed.id, direction: direction) else { return }

    if result.focusedIsAlone {
        log("cmd+shift+arrow partition swap for \(managed.id)")
        plan.updatedTrees[key] = tree.swappingChildrenForCrossing(
            windowID: managed.id, direction: direction) ?? tree
    } else {
        let otherWindows = result.otherSideIDs.compactMap { plan.reconciledWindows[$0] }
        guard let target = nearestWindow(from: managed.frame, direction: direction,
                                          among: otherWindows) else { return }
        log("cmd+shift+arrow window swap: \(managed.id) <-> \(target.id)")
        plan.updatedTrees[key] = tree.swappingWindows(managed.id, target.id)
    }

    let frames = computeTileFrames(
        trees: plan.updatedTrees,
        managedWindows: plan.reconciledWindows,
        spaceID: spaceID)
    if let frame = frames[managed.id] {
        plan.warpTo = frame
    }
}

func computeFocus(
    managed: ManagedWindow, direction: Direction, plan: inout TickPlan
) {
    let candidates = plan.reconciledWindows.values.filter { $0.id != managed.id }
    guard let target = nearestWindow(from: managed.frame, direction: direction,
                                      among: Array(candidates)) else { return }
    log("cmd+arrow focus: \(target.id) (\(target.name))")
    plan.focusTarget = target
    plan.warpTo = target.frame
    plan.newLastFocusedWindow = target.id
}

func computeMouseFocus(snap: WorldSnapshot, plan: inout TickPlan) {
    let pos = snap.mousePosition

    // Hit-test against tile frames (intended positions) for managed windows
    for (id, tileFrame) in plan.tileFrames {
        if tileFrame.contains(pos), let managed = plan.reconciledWindows[id] {
            if managed.id != lastFocusedWindow {
                log("mouse focus: \(managed.id) (\(managed.name)) at \(Int(pos.x)),\(Int(pos.y))")
                plan.focusTarget = managed
                plan.newLastFocusedWindow = managed.id
            }
            return
        }
    }

    // Hit-test unmanaged windows from CG data
    let windows = snap.cgWindows
        .filter { !config.ignoredApps.contains($0.name) }
        .map { Window(id: $0.id, pid: $0.pid, name: $0.name, frame: $0.frame) }
    for win in windows {
        guard win.frame.contains(pos) else { continue }
        if plan.reconciledWindows[win.id] != nil { continue }
        if win.name == "DockHelper" { return }
        if let app = NSRunningApplication(processIdentifier: win.pid) {
            if !app.isActive {
                log("mouse focus: \(win.id) (pid \(win.pid)) at \(Int(pos.x)),\(Int(pos.y))")
                plan.activateApp = app
            }
            plan.newLastFocusedWindow = 0
        }
        return
    }

    // Mouse over desktop
    if lastFocusedWindow != 0 {
        log("mouse over desktop — unfocusing")
        plan.unfocusToFinder = true
        plan.newLastFocusedWindow = 0
    }
}
