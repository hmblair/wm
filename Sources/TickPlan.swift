import Cocoa
import ApplicationServices

// MARK: - Snapshot (read phase)

struct WorldSnapshot {
    let cgWindows: [CGWindowEntry]
    let spaceID: CGSSpaceID
    let focusedWindow: Window?
    let mousePosition: CGPoint
    let mouseDown: Bool
    let commands: [PendingKeyCommand]
    let moveCommands: [Int]
}

func readWorld() -> WorldSnapshot {
    let commands = pendingKeyCommands
    pendingKeyCommands.removeAll()
    let moves = pendingMoveToSpace
    pendingMoveToSpace.removeAll()
    let cgWindows = fetchCGWindowList()
    return WorldSnapshot(
        cgWindows: cgWindows,
        spaceID: activeSpaceID(),
        focusedWindow: getFocusedWindow(cgWindows: cgWindows),
        mousePosition: lastMousePosition,
        mouseDown: NSEvent.pressedMouseButtons & 0x1 != 0,
        commands: commands,
        moveCommands: moves
    )
}

// MARK: - Desired state (compute phase)

struct TickPlan {
    var reconciledWindows: [UInt32: ManagedWindow] = [:]
    var updatedTrees: [DisplaySpaceKey: BSPTree] = [:]
    var tileFrames: [UInt32: CGRect] = [:]
    var focusTarget: ManagedWindow? = nil
    var activateApp: NSRunningApplication? = nil
    var unfocusToFinder: Bool = false
    var warpTo: CGRect? = nil
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
        current: managedWindows, cgWindows: snap.cgWindows)

    // 2. Rebuild BSP trees
    plan.updatedTrees = computeBSPTrees(
        managedWindows: plan.reconciledWindows,
        currentTrees: bspTrees,
        spaceID: snap.spaceID,
        lastActiveSpace: lastActiveSpace)
    plan.newLastActiveSpace = snap.spaceID

    // 3. Process key commands (pure BSP/focus transforms)
    if !snap.commands.isEmpty, let focused = snap.focusedWindow,
       let managed = resolveManaged(for: focused, in: plan.reconciledWindows) {
        for cmd in snap.commands {
            if cmd.swap {
                computeSwap(managed: managed, direction: cmd.direction,
                            spaceID: snap.spaceID, plan: &plan)
            } else {
                computeFocus(managed: managed, direction: cmd.direction, plan: &plan)
            }
        }
    }

    // 4. Process move-to-space commands
    if !snap.moveCommands.isEmpty, let focused = snap.focusedWindow,
       let managed = resolveManaged(for: focused, in: plan.reconciledWindows) {
        if let spaceIndex = snap.moveCommands.last {
            let spaces = orderedSpaceIDs()
            if spaceIndex < spaces.count && spaces[spaceIndex] != snap.spaceID {
                log("move-to-space: window \(managed.id) (\(managed.name)) → space \(spaceIndex + 1)")
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

    // 6. Resolve pending warp from previous tick's move-to-space
    if pendingWarpToWindow != 0 && plan.warpTo == nil {
        if let tileFrame = plan.tileFrames[pendingWarpToWindow] {
            plan.warpTo = tileFrame
            plan.clearPendingWarp = true
        }
    }

    // 7. After swap, warp to the managed window's tile frame
    // (warpTo may have been set by computeSwap pointing to managed.id —
    //  resolve it to the actual tile frame now that tileFrames are computed)

    // 8. Mouse focus (only if no command already set focus/warp and no pending warp)
    if plan.focusTarget == nil && plan.warpTo == nil
        && pendingWarpToWindow == 0 && plan.setPendingWarp == 0 {
        computeMouseFocus(snap: snap, plan: &plan)
    }

    // 9. External focus tracking
    if plan.focusTarget == nil && plan.warpTo == nil,
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

// MARK: - Command processors (pure)

private func computeSwap(
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

    // Warp will be resolved to tile frame after tileFrames are computed.
    // For now, compute tile frames from the updated trees to get the target.
    let frames = computeTileFrames(
        trees: plan.updatedTrees,
        managedWindows: plan.reconciledWindows,
        spaceID: spaceID)
    if let frame = frames[managed.id] {
        plan.warpTo = frame
    }
}

private func computeFocus(
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

private func computeMouseFocus(snap: WorldSnapshot, plan: inout TickPlan) {
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

// MARK: - Execute phase

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
        focusWindow(target)
    } else if let app = plan.activateApp {
        app.activate()
    } else if plan.unfocusToFinder {
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
