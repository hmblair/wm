import Cocoa
import ApplicationServices

func executePlan(_ plan: TickPlan, snap: WorldSnapshot) {
    // 1. Update internal state
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

    // 3. Enforce tile frames (skip if mouse down)
    if !snap.mouseDown {
        for (id, tileFrame) in plan.tileFrames {
            guard let win = managedWindows[id] else { continue }
            if !framesMatch(win.frame, tileFrame) {
                log("enforce: [\(id)] (\(win.name)) \(formatFrame(win.frame)) → \(formatFrame(tileFrame))")
                setWindowFrame(win, frame: tileFrame)
            }
        }
    }

    // 4. Focus
    if let target = plan.focusTarget {
        log("exec: focusWindow [\(target.id)] (\(target.name))")
        focusWindow(target)
    } else if let app = plan.activateApp {
        log("exec: activateApp \(app.localizedName ?? "?") (pid \(app.processIdentifier))")
        app.activate()
    } else if plan.unfocusToFinder {
        log("exec: unfocusToFinder")
        if let finder = NSWorkspace.shared.runningApplications.first(
            where: { $0.bundleIdentifier == "com.apple.finder" }) {
            finder.activate()
        }
    }

    // 5. Warp mouse (single warp, after everything else)
    if let frame = plan.warpTo {
        warpMouse(to: frame)
        lastMousePosition = CGPoint(x: frame.midX, y: frame.midY)
    }
}
