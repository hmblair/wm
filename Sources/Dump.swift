import Cocoa
import ApplicationServices

// A read-only snapshot of on-screen window state, for debugging focus, overlap,
// and layering issues. It queries CoreGraphics and Accessibility directly and
// touches no daemon state, so it runs identically whether or not the daemon is
// live (subrole queries need Accessibility for the invoking process).

private func windowSubrole(pid: Int32, windowID: UInt32) -> String? {
    guard let axWindow = findAXWindowByPidAndID(pid: pid, windowID: windowID) else { return nil }
    var ref: CFTypeRef?
    AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &ref)
    return ref as? String
}

func runDump() -> Never {
    let dumpDelay: TimeInterval = 3
    fputs("Dumping in \(Int(dumpDelay)) seconds — switch to the window you want to inspect.\n", stderr)
    Thread.sleep(forTimeInterval: dumpDelay)

    let cgWindows = fetchCGWindowList()

    // AX-derived fields (focused window, subroles) require the invoking process
    // to be Accessibility-trusted. Report it up front so blank fields aren't a
    // mystery — a CLI invocation is a different binary from the granted daemon.
    print("Accessibility: \(AXIsProcessTrusted() ? "granted" : "NOT granted (AX fields will be blank)")")

    if let frontApp = NSWorkspace.shared.frontmostApplication {
        print("Frontmost app: \(frontApp.localizedName ?? "?") (pid \(frontApp.processIdentifier))")
    } else {
        print("Frontmost app: none")
    }
    print("Active space: \(activeSpaceID())")

    if let focused = getFocusedWindow(cgWindows: cgWindows) {
        print("Focused window: [\(focused.id)] \(focused.name) — \(formatFrame(focused.frame))")
    } else {
        print("Could not get focused window info")
    }

    print("\nAll on-screen windows (z-order):")
    for win in cgWindows {
        let space = spaceForWindow(win.id).map(String.init) ?? "nil"
        let subrole = windowSubrole(pid: win.pid, windowID: win.id).map { " subrole=\($0)" } ?? ""
        print("  [\(win.id)] \(win.name) (pid \(win.pid)) — \(formatFrame(win.frame)) layer=\(win.layer) space=\(space)\(subrole)")
    }
    exit(0)
}
