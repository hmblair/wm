import Foundation
import CoreGraphics

// Centralized apply/revert of the global macOS settings wm manages, so the wm
// binary — not the installer — owns them. Applied on daemon start and config
// reload (idempotently), reverted on clean shutdown and by `wm reset`:
//
//   * native window tiling by edge drag        (NSGlobalDomain, disabled)
//   * automatic Space reordering (mru-spaces)   (com.apple.dock, disabled)
//   * Switch-to-Desktop 1-9 shortcuts           (com.apple.symbolichotkeys)
//   * window corner radius                       (NSGlobalDomain, pinned)
//
// Apply reads from config; revert restores the macOS defaults and needs no
// config, so `wm reset` can run it standalone.

// MARK: - Keys

private let cornerRadiusKey = "NSConvolutionOverride1"
private let edgeTilingKeys = [
    "EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag", "EnableTilingOptionAccelerator",
]
// Symbolic-hotkey IDs for "Switch to Desktop 1..9" and the ASCII of digits 1-9.
private let switchDesktopHotkeyIDs = Array(118...126)
private let digitASCII = Array(49...57)

// MARK: - Low-level helpers

@discardableResult
private func runTool(_ path: String, _ args: [String]) -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    } catch {
        return false
    }
}

// Reads/writes a preference in an arbitrary domain (kCFPreferencesAnyApplication
// for NSGlobalDomain). Writes return whether the value actually changed.
private func prefValue(_ key: String, _ domain: CFString) -> CFPropertyList? {
    CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
}

@discardableResult
private func setPref(_ key: String, _ value: CFPropertyList?, _ domain: CFString) -> Bool {
    let existing = prefValue(key, domain)
    // Treat equal existing values as a no-op so we don't thrash Dock restarts.
    if let value, let existing, CFEqual(value, existing) { return false }
    if value == nil && existing == nil { return false }
    CFPreferencesSetValue(key as CFString, value, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    CFPreferencesAppSynchronize(domain)
    return true
}

private let globalDomain = kCFPreferencesAnyApplication
private let dockDomain = "com.apple.dock" as CFString

private func restartDock() {
    runTool("/usr/bin/killall", ["Dock"])
}

private func activateSettings() {
    runTool("/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", ["-u"])
}

// MARK: - Switch-to-Desktop shortcuts

// Registers (or, with enabled=false, disables) the "Switch to Desktop 1-9"
// shortcuts. Each entry is merged into the AppleSymbolicHotKeys sub-dictionary
// via `defaults -dict-add`, which handles the nested-dict merge and writes the
// exact plist types the hotkey subsystem requires (a boolean enabled and
// integer parameters — old-style syntax writes strings it silently ignores).
// enabled=false disables a shortcut while preserving its parameters, so revert
// doesn't need to know the user's prior binding.
private func writeSwitchDesktopHotkeys(enabled: Bool, modifier: ModifierConfig) {
    let mask = modifier.symbolicHotkeyMask
    for i in switchDesktopHotkeyIDs.indices {
        let plist = "<dict><key>enabled</key><\(enabled ? "true" : "false")/>"
            + "<key>value</key><dict><key>type</key><string>standard</string>"
            + "<key>parameters</key><array>"
            + "<integer>\(digitASCII[i])</integer>"
            + "<integer>\(Int(spaceKeyCodes[i]))</integer>"
            + "<integer>\(mask)</integer></array></dict></dict>"
        runTool("/usr/bin/defaults", [
            "write", "com.apple.symbolichotkeys", "AppleSymbolicHotKeys",
            "-dict-add", "\(switchDesktopHotkeyIDs[i])", plist,
        ])
    }
    activateSettings()
}

// MARK: - Apply / revert

// Re-applying the shortcuts spawns subprocesses, so skip it when the modifier is
// unchanged within this daemon's lifetime.
private var lastAppliedSwitchModifier: ModifierConfig?

func applySystemSettings() {
    guard config.manageSystemSettings else { return }

    // Window corner radius (see NSConvolutionOverride1). Pinned to config so the
    // rendered corners and the focus outline share one source of truth.
    if setPref(cornerRadiusKey, Double(config.cornerRadius) as CFNumber, globalDomain) {
        log("system: window corner radius → \(Int(config.cornerRadius))pt (relaunch apps to apply)")
    }

    // Disable macOS native edge-drag tiling so it doesn't fight the BSP layout.
    for key in edgeTilingKeys { setPref(key, false as CFBoolean, globalDomain) }

    // Disable automatic Space reordering so Space indices stay stable.
    if setPref("mru-spaces", false as CFBoolean, dockDomain) {
        log("system: disabled automatic Space reordering")
        restartDock()
    }

    // Register Switch-to-Desktop 1-9 shortcuts (which wm posts to switch Spaces).
    let modifier = config.keybindings.spaceSwitchModifier
    if lastAppliedSwitchModifier != modifier {
        writeSwitchDesktopHotkeys(enabled: true, modifier: modifier)
        lastAppliedSwitchModifier = modifier
        log("system: registered Switch-to-Desktop shortcuts")
    }
}

// Restores macOS defaults. Uses no config so `wm reset` can run it standalone.
func revertSystemSettings() {
    setPref(cornerRadiusKey, nil, globalDomain)
    for key in edgeTilingKeys { setPref(key, nil, globalDomain) }
    if setPref("mru-spaces", nil, dockDomain) { restartDock() }
    writeSwitchDesktopHotkeys(enabled: false, modifier: ModifierConfig())
    lastAppliedSwitchModifier = nil
}

// `wm reset` — reverts unconditionally (independent of config and daemon state),
// so it also cleans up after a hard kill that skipped the shutdown handler.
func runReset() -> Never {
    revertSystemSettings()
    print("wm: reverted managed system settings to macOS defaults")
    exit(0)
}
