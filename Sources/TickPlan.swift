import Cocoa
import ApplicationServices

// MARK: - Snapshot (read phase)

struct WorldSnapshot {
    let cgWindows: [CGWindowEntry]
    let spaceID: CGSSpaceID
    let focusedWindow: Window?
    let mousePosition: CGPoint
    let mouseDown: Bool
    let missionControlActive: Bool
    let commands: [PendingKeyCommand]
    let moveCommands: [Int]
    let rotate: Bool
}

func readWorld() -> WorldSnapshot {
    let commands = pendingKeyCommands
    pendingKeyCommands.removeAll()
    let moves = pendingMoveToSpace
    pendingMoveToSpace.removeAll()
    let rotate = pendingRotate
    pendingRotate = false
    let cgWindows = fetchCGWindowList()
    let missionControl = cgWindows.contains { $0.name == "Dock" && $0.layer == 18 }
    return WorldSnapshot(
        cgWindows: cgWindows,
        spaceID: activeSpaceID(),
        focusedWindow: missionControl ? nil : getFocusedWindow(cgWindows: cgWindows),
        mousePosition: lastMousePosition,
        mouseDown: NSEvent.pressedMouseButtons & 0x1 != 0,
        missionControlActive: missionControl,
        commands: commands,
        moveCommands: moves,
        rotate: rotate
    )
}

// MARK: - Desired state (compute phase)

struct TickPlan {
    var reconciledWindows: [UInt32: ManagedWindow] = [:]
    var updatedTrees: [DisplaySpaceKey: BSPTree] = [:]
    var tileFrames: [UInt32: CGRect] = [:]
    var focusAction: FocusAction? = nil
    var warpTo: CGRect? = nil
    var warpToWindow: UInt32? = nil
    var moveToSpace: (axWindow: AXUIElement, spaceIndex: Int)? = nil
    var newLastFocusedWindow: UInt32? = nil
    var setPendingWarp: UInt32 = 0
    var clearPendingWarp: Bool = false
    var newLastActiveSpace: CGSSpaceID? = nil
}

func computePlan(_ snap: WorldSnapshot) -> TickPlan {
    var plan = TickPlan()

    // 1. Reconcile windows
    plan.reconciledWindows = computeReconciliation(
        current: managedWindows, cgWindows: snap.cgWindows, spaceID: snap.spaceID)

    // 2. Rebuild BSP trees
    plan.updatedTrees = computeBSPTrees(
        managedWindows: plan.reconciledWindows,
        currentTrees: bspTrees,
        spaceID: snap.spaceID,
        lastActiveSpace: lastActiveSpace)
    plan.newLastActiveSpace = snap.spaceID

    // 3. Process key commands (pure BSP/focus transforms)
    if !snap.commands.isEmpty {
        let resolved = snap.focusedWindow.flatMap {
            resolveManaged(for: $0, in: plan.reconciledWindows)
        }
        let anchor = resolved ?? plan.reconciledWindows.values.min(by: {
            hypot($0.frame.midX - snap.mousePosition.x, $0.frame.midY - snap.mousePosition.y) <
            hypot($1.frame.midX - snap.mousePosition.x, $1.frame.midY - snap.mousePosition.y)
        })
        if let managed = anchor {
            debug("cmd: anchor [\(managed.id)] (\(managed.name))")
            if resolved == nil {
                // Desktop focused — just focus the nearest window
                debug("cmd: desktop focus [\(managed.id)] (\(managed.name))")
                plan.focusAction = .window(managed)
                plan.warpTo = managed.frame
                plan.newLastFocusedWindow = managed.id
            } else {
                for cmd in snap.commands {
                    if cmd.swap {
                        computeSwap(managed: managed, direction: cmd.direction,
                                    spaceID: snap.spaceID, plan: &plan)
                    } else {
                        computeFocus(managed: managed, direction: cmd.direction, plan: &plan)
                    }
                }
            }
        } else {
            debug("cmd: no anchor found, focused=\(snap.focusedWindow?.id ?? 0) mouse=\(Int(snap.mousePosition.x)),\(Int(snap.mousePosition.y)) managed=\(plan.reconciledWindows.count)")
        }
    }

    // 3b. Process rotate command
    if snap.rotate, tilingEnabled, let focused = snap.focusedWindow,
       let managed = resolveManaged(for: focused, in: plan.reconciledWindows) {
        let focusCenter = CGPoint(x: managed.frame.midX, y: managed.frame.midY)
        let did = displayID(for: focusCenter)
        let key = DisplaySpaceKey(displayID: did, spaceID: snap.spaceID)
        if let tree = plan.updatedTrees[key],
           let rotated = tree.rotatingParent(of: managed.id) {
            debug("cmd: rotate parent of [\(managed.id)] (\(managed.name))")
            plan.updatedTrees[key] = rotated
        }
    }

    // 4. Process move-to-space commands
    if !snap.moveCommands.isEmpty, let focused = snap.focusedWindow,
       let managed = resolveManaged(for: focused, in: plan.reconciledWindows) {
        if let spaceIndex = snap.moveCommands.last {
            let spaces = orderedSpaceIDs()
            if spaceIndex < spaces.count && spaces[spaceIndex] != snap.spaceID {
                log("space: move [\(managed.id)] (\(managed.name)) → space \(spaceIndex + 1)")
                plan.moveToSpace = (managed.axWindow, spaceIndex)
                plan.reconciledWindows.removeValue(forKey: managed.id)
                plan.setPendingWarp = managed.id
                plan.updatedTrees = computeBSPTrees(
                    managedWindows: plan.reconciledWindows,
                    currentTrees: plan.updatedTrees,
                    spaceID: snap.spaceID,
                    lastActiveSpace: snap.spaceID)
            }
        }
    }

    // 5. Compute tile frames from final trees
    if tilingEnabled {
        plan.tileFrames = computeTileFrames(
            trees: plan.updatedTrees,
            managedWindows: plan.reconciledWindows,
            spaceID: snap.spaceID)
    }

    // 6. Resolve deferred warp-to-window (set by computeSwap)
    if let wid = plan.warpToWindow, let frame = plan.tileFrames[wid] {
        plan.warpTo = frame
    }

    // 7. Resolve pending warp from previous tick's move-to-space
    if pendingWarpToWindow != 0 && plan.warpTo == nil {
        if let tileFrame = plan.tileFrames[pendingWarpToWindow] {
            plan.warpTo = tileFrame
            plan.clearPendingWarp = true
        }
    }

    // 7. Mouse focus (only if no command already set focus/warp and no pending warp)
    if plan.focusAction == nil && plan.warpTo == nil
        && pendingWarpToWindow == 0 && plan.setPendingWarp == 0 {
        computeMouseFocus(snap: snap, plan: &plan)
    }

    // 8. External focus tracking
    if plan.focusAction == nil && plan.warpTo == nil,
       let focused = snap.focusedWindow,
       focused.id != lastFocusedWindow && lastFocusedWindow != 0 {
        let frame = plan.tileFrames[focused.id]
            ?? plan.reconciledWindows[focused.id]?.frame
            ?? focused.frame
        plan.warpTo = frame
        plan.newLastFocusedWindow = focused.id
    }

    return plan
}
