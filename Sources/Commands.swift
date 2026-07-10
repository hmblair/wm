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

    // Find the topmost window under the cursor (the CG list is z-ordered) that is
    // either one we manage (at any layer) or an ordinary app-level window — below
    // the dock window level. System chrome blankets the screen with full-screen
    // windows at the dock level or above (the Dock's layer-20 window, Notification
    // Center at 21, the menu bar) and must be seen through, or it would shadow the
    // hit-test and block focus. An app's open/save panel sits at a panel level
    // (layer 8) and must not be seen through — see the occluder handling below.
    let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
    guard let hit = snap.cgWindows.first(where: {
        $0.frame.contains(pos) && (plan.reconciledWindows[$0.id] != nil || $0.layer < dockLevel)
    }) else {
        // Only system chrome (or nothing) under the cursor. If any window covers
        // this spot we're not over the desktop, so leave focus alone; only unfocus
        // when nothing at all is under the cursor.
        let overOverlay = snap.cgWindows.contains { $0.frame.contains(pos) }
        if !overOverlay && lastFocusedWindow != 0 {
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

    // An unmanaged window above the standard layer is an occluding panel or dialog
    // (an open/save panel at layer 8, a floating window, …) that visually covers
    // whatever is behind it. Focusing the window behind would raise it over the
    // panel, so treat the panel as part of its owning app and stop here instead of
    // falling through. Raise the owner if focus has drifted off it.
    if hit.layer != 0 && plan.reconciledWindows[hit.id] == nil {
        if let owner = NSRunningApplication(processIdentifier: hit.pid),
           owner.activationPolicy == .regular, !owner.isActive,
           spaceForWindow(hit.id) == snap.spaceID {
            debug("mouse: occluding panel [\(hit.id)] (\(hit.name)) — activate owner")
            plan.focusAction = .activate(owner)
        }
        plan.newLastFocusedWindow = 0
        return
    }

    let winSpace = spaceForWindow(hit.id).map(String.init) ?? "?"

    if let managed = plan.reconciledWindows[hit.id] {
        if managed.id != lastFocusedWindow {
            debug("mouse: focus [\(managed.id)] (\(managed.name)) at \(Int(pos.x)),\(Int(pos.y)) space=\(winSpace) frame=\(formatFrame(hit.frame))")
            plan.focusAction = .window(managed)
            plan.newLastFocusedWindow = managed.id
        }
    } else if let app = NSRunningApplication(processIdentifier: hit.pid) {
        let onCurrentSpace = spaceForWindow(hit.id) == snap.spaceID
        if !app.isActive && hit.layer == 0 && onCurrentSpace {
            debug("mouse: activate [\(hit.id)] (\(hit.name) pid \(hit.pid)) at \(Int(pos.x)),\(Int(pos.y)) space=\(winSpace) frame=\(formatFrame(hit.frame))")
            plan.focusAction = .activate(app)
        }
        plan.newLastFocusedWindow = 0
    }
}
