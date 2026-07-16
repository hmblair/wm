import Cocoa
import ApplicationServices

@discardableResult
private func enforceTileFrames(_ tileFrames: [UInt32: CGRect], label: String = "enforce") -> Bool {
    var newConstraint = false
    for (id, tileFrame) in tileFrames {
        guard let win = managedWindows[id] else { continue }
        if !framesMatch(win.frame, tileFrame) {
            debug("tile: \(label) [\(id)] (\(win.name)) \(formatFrame(win.frame)) → \(formatFrame(tileFrame))")
            if setWindowFrame(win, frame: tileFrame) {
                newConstraint = true
            }
        }
    }
    return newConstraint
}

func executePlan(_ plan: TickPlan, snap: WorldSnapshot) {
    // 1. Update internal state
    let membershipChanged = managedWindows.count != plan.reconciledWindows.count
        || !managedWindows.keys.allSatisfy { plan.reconciledWindows[$0] != nil }
    if membershipChanged { statusBarOccupancyDirty = true }
    managedWindows = plan.reconciledWindows
    bspTrees = plan.updatedTrees
    if let space = plan.newLastActiveSpace {
        lastActiveSpace = space
    }
    if let newFocus = plan.newLastFocusedWindow {
        lastFocusedWindow = newFocus
    }
    if plan.setPendingWarp != 0 {
        pendingWarpToWindow = plan.setPendingWarp
    }
    if plan.clearPendingWarp {
        pendingWarpToWindow = 0
    }

    // 2. Move-to-space (async synthetic events)
    if let move = plan.moveToSpace {
        moveWindowToSpace(axWindow: move.axWindow, spaceIndex: move.spaceIndex)
    }

    // 3. Enforce tile frames (skip if mouse down or Mission Control active)
    if !snap.mouseDown && !snap.missionControlActive {
        let newConstraint = enforceTileFrames(plan.tileFrames)
        if newConstraint && tilingEnabled {
            let corrected = computeTileFrames(
                trees: bspTrees, managedWindows: managedWindows, spaceID: snap.spaceID)
            enforceTileFrames(corrected, label: "correct")
        }
    }

    // 4. Focus
    if let action = plan.focusAction {
        executeFocus(action)
    }

    // 5. Warp mouse (single warp, after everything else)
    if let frame = plan.warpTo {
        warpMouse(to: frame)
        lastMousePosition = CGPoint(x: frame.midX, y: frame.midY)
    }

    // 6. Focus border. While the user drags or resizes (mouse down), follow the
    // window's live CG frame so the border tracks it. Otherwise prefer the tile
    // frame — the settled position we just enforced — over the possibly-stale CG
    // frame, so the border tracks wm's own moves without a one-tick lag.
    if config.focusBorder {
        let frame = snap.focusedWindow.flatMap { focused -> CGRect? in
            if !snap.mouseDown, let tiled = plan.tileFrames[focused.id] { return tiled }
            return focused.frame.isEmpty ? nil : focused.frame
        }
        updateFocusBorder(focusedFrame: frame)
    }
}
