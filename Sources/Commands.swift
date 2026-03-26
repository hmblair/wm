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
        debug("cmd: partition swap for [\(managed.id)]")
        plan.updatedTrees[key] = tree.swappingChildrenForCrossing(
            windowID: managed.id, direction: direction) ?? tree
    } else {
        let otherWindows = result.otherSideIDs.compactMap { plan.reconciledWindows[$0] }
        guard let target = nearestWindow(from: managed.frame, direction: direction,
                                          among: otherWindows) else { return }
        debug("cmd: window swap [\(managed.id)] <-> [\(target.id)]")
        plan.updatedTrees[key] = tree.swappingWindows(managed.id, target.id)
    }

    plan.warpToWindow = managed.id
}

func computeFocus(
    managed: ManagedWindow, direction: Direction, plan: inout TickPlan
) {
    let candidates = plan.reconciledWindows.values.filter { $0.id != managed.id }
    guard let target = nearestWindow(from: managed.frame, direction: direction,
                                      among: Array(candidates)) else { return }
    debug("cmd: focus [\(target.id)] (\(target.name))")
    plan.focusAction = .window(target)
    plan.warpTo = target.frame
    plan.newLastFocusedWindow = target.id
}

func computeMouseFocus(snap: WorldSnapshot, plan: inout TickPlan) {
    let pos = snap.mousePosition

    // Find the topmost window under the cursor (CG list is z-ordered)
    guard let hit = snap.cgWindows.first(where: { $0.frame.contains(pos) }) else {
        // Mouse over desktop
        if lastFocusedWindow != 0 {
            let managedIDs = plan.reconciledWindows.keys.sorted()
            let cgSummary = snap.cgWindows.prefix(8).map {
                "[\($0.id)](\($0.name) L\($0.layer) \(formatFrame($0.frame)))"
            }.joined(separator: ", ")
            debug("mouse: desktop unfocus (pos=\(Int(pos.x)),\(Int(pos.y)) lastFocused=\(lastFocusedWindow) managed=\(managedIDs) cg=\(cgSummary))")
            if let finder = NSWorkspace.shared.runningApplications.first(
                where: { $0.bundleIdentifier == "com.apple.finder" }) {
                plan.focusAction = .activate(finder)
            }
            plan.newLastFocusedWindow = 0
        }
        return
    }

    if config.ignoredApps.contains(hit.name) { return }

    let winSpace = spaceForWindow(hit.id).map(String.init) ?? "?"

    if let managed = plan.reconciledWindows[hit.id] {
        if managed.id != lastFocusedWindow {
            debug("mouse: focus [\(managed.id)] (\(managed.name)) at \(Int(pos.x)),\(Int(pos.y)) space=\(winSpace) frame=\(formatFrame(hit.frame))")
            plan.focusAction = .window(managed)
            plan.newLastFocusedWindow = managed.id
        }
    } else if let app = NSRunningApplication(processIdentifier: hit.pid) {
        if !app.isActive && hit.layer == 0 {
            debug("mouse: activate [\(hit.id)] (\(hit.name) pid \(hit.pid)) at \(Int(pos.x)),\(Int(pos.y)) space=\(winSpace) frame=\(formatFrame(hit.frame))")
            plan.focusAction = .activate(app)
        }
        plan.newLastFocusedWindow = 0
    }
}
