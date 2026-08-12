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

    // 6. Focus border, drawn on the window's observed frame rather than the tile
    // frame it was asked to take, so a window that clamps to a minimum size
    // still gets an outline that matches it. Enforcement above refreshed that
    // frame from the window itself, so this tracks wm's own moves without a
    // one-tick lag; an unmanaged window (a dialog, an excluded app) has no
    // enforced frame and falls back to the snapshot.
    if config.focusBorder {
        let frame = snap.focusedWindow.flatMap { focused -> CGRect? in
            // No outline on native-fullscreen windows.
            if focused.isFullScreen { return nil }
            let observed = managedWindows[focused.id]?.frame ?? focused.frame
            return observed.isEmpty ? nil : observed
        }
        updateFocusBorder(focusedFrame: frame)
    }
}
