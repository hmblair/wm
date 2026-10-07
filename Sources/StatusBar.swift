import Cocoa

private var statusItem: NSStatusItem?
private var lastRenderedSpaces: [CGSSpaceID] = []
private var lastRenderedActive: CGSSpaceID = 0

private let statusBarFontSize: CGFloat = 13

func setupStatusBar() {
    guard statusItem == nil else { return }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.menu = makeSpaceMenu()
    statusItem = item

    updateStatusBar(activeSpace: activeSpaceID())
}

func teardownStatusBar() {
    if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
    statusItem = nil
    // Reset render caches so a later setup repaints from scratch.
    lastRenderedSpaces = []
    lastRenderedActive = 0
}

func updateStatusBar(activeSpace: CGSSpaceID) {
    guard let item = statusItem else { return }

    let spaces = orderedSpaces()
    let spaceIDs = spaces.map { $0.id }

    // Skip update if nothing changed
    guard spaceIDs != lastRenderedSpaces
       || activeSpace != lastRenderedActive else { return }

    lastRenderedSpaces = spaceIDs
    lastRenderedActive = activeSpace

    renderButtonTitle(item: item, spaces: spaces, activeSpace: activeSpace)
}

// Creates the dropdown. Its delegate rebuilds the items each time it opens.
private func makeSpaceMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.delegate = SpaceMenuTarget.shared
    return menu
}

// Shows the active Space's label on the menu bar button.
private func renderButtonTitle(item: NSStatusItem, spaces: [SpaceInfo], activeSpace: CGSSpaceID) {
    let labels = spaceLabels(for: spaces)
    let activeIndex = spaces.firstIndex { $0.id == activeSpace }
    let title = activeIndex.map { labels[$0] } ?? unknownSpaceLabel
    item.button?.attributedTitle = NSAttributedString(
        string: title,
        attributes: [.font: NSFont.systemFont(ofSize: statusBarFontSize, weight: .medium)]
    )
}

// Rebuilds the dropdown with one item per Space, in Mission Control order.
private func renderMenu(_ menu: NSMenu) {
    let spaces = orderedSpaces()
    let activeSpace = activeSpaceID()
    let appCounts = appWindowCountsBySpace()
    menu.removeAllItems()
    for (space, desktopNumber) in zip(spaces, desktopNumbers(for: spaces)) {
        let menuItem = spaceMenuItem(
            desktopNumber: desktopNumber, apps: appCounts[space.id] ?? [])
        menuItem.state = space.id == activeSpace ? .on : .off
        menu.addItem(menuItem)
    }
}

private func spaceMenuItem(desktopNumber: Int?, apps: [AppWindowCount]) -> NSMenuItem {
    guard let desktopNumber else { return fullScreenMenuItem(appName: apps.first?.appName) }
    return desktopMenuItem(number: desktopNumber, apps: apps)
}

// Builds a disabled item that names a full-screen Space's app. The
// Switch-to-Desktop hotkeys do not reach full-screen Spaces.
private func fullScreenMenuItem(appName: String?) -> NSMenuItem {
    let menuItem = NSMenuItem(title: appName ?? "Full Screen", action: nil, keyEquivalent: "")
    menuItem.isEnabled = false
    return menuItem
}

// Builds an item that names the desktop as Mission Control does, lists its apps
// in the subtitle, displays its Switch-to-Desktop hotkey, and switches to the
// desktop when clicked. The item is disabled when the desktop is beyond the
// hotkey range.
private func desktopMenuItem(number: Int, apps: [AppWindowCount]) -> NSMenuItem {
    let index = number - 1
    let hasHotkey = index < spaceKeyCodes.count
    let menuItem = NSMenuItem(
        title: "Desktop \(number)",
        action: #selector(SpaceMenuTarget.desktopItemClicked(_:)),
        keyEquivalent: hasHotkey ? "\(number)" : "")
    menuItem.subtitle = desktopMenuSubtitle(apps: apps)
    menuItem.keyEquivalentModifierMask = config.keybindings.spaceSwitchModifier.menuModifierFlags
    menuItem.target = SpaceMenuTarget.shared
    menuItem.tag = index
    menuItem.isEnabled = hasHotkey
    return menuItem
}

// Lists the desktop's apps, as in "Firefox, Alacritty ×2", or returns nil when
// the desktop has no windows.
private func desktopMenuSubtitle(apps: [AppWindowCount]) -> String? {
    guard !apps.isEmpty else { return nil }
    return apps.map(appLabel).joined(separator: ", ")
}

// Names the app, followed by its window count when it has more than one, as in
// "Alacritty ×2".
private func appLabel(_ app: AppWindowCount) -> String {
    guard app.windowCount > 1 else { return app.appName }
    return "\(app.appName) ×\(app.windowCount)"
}

// Switches to the desktop at this zero-based Mission Control index.
func switchToDesktop(_ index: Int) {
    guard index < spaceKeyCodes.count else { return }
    postKeyEvent(keyCode: spaceKeyCodes[index],
                 flags: config.keybindings.spaceSwitchModifier.eventFlags)
}

private class SpaceMenuTarget: NSObject, NSMenuDelegate {
    static let shared = SpaceMenuTarget()

    func menuNeedsUpdate(_ menu: NSMenu) { renderMenu(menu) }

    @objc func desktopItemClicked(_ sender: NSMenuItem) {
        debug("statusbar: clicked desktop \(sender.tag + 1)")
        switchToDesktop(sender.tag)
    }
}
