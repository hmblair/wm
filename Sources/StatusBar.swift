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
    menu.removeAllItems()
    for (space, desktopNumber) in zip(spaces, desktopNumbers(for: spaces)) {
        let menuItem = spaceMenuItem(space: space, desktopNumber: desktopNumber)
        menuItem.state = space.id == activeSpace ? .on : .off
        menu.addItem(menuItem)
    }
}

private func spaceMenuItem(space: SpaceInfo, desktopNumber: Int?) -> NSMenuItem {
    guard let desktopNumber else { return fullScreenMenuItem(space: space) }
    return desktopMenuItem(number: desktopNumber)
}

// Builds a disabled item that names a full-screen Space's app. The
// Switch-to-Desktop hotkeys do not reach full-screen Spaces.
private func fullScreenMenuItem(space: SpaceInfo) -> NSMenuItem {
    let menuItem = NSMenuItem(
        title: appNameForSpace(space.id) ?? "Full Screen", action: nil, keyEquivalent: "")
    menuItem.isEnabled = false
    return menuItem
}

// Builds an item that names the desktop as Mission Control does, displays its
// Switch-to-Desktop hotkey, and switches to the desktop when clicked. The item
// is disabled when the desktop is beyond the hotkey range.
private func desktopMenuItem(number: Int) -> NSMenuItem {
    let index = number - 1
    let hasHotkey = index < spaceKeyCodes.count
    let menuItem = NSMenuItem(
        title: "Desktop \(number)",
        action: #selector(SpaceMenuTarget.desktopItemClicked(_:)),
        keyEquivalent: hasHotkey ? "\(number)" : "")
    menuItem.keyEquivalentModifierMask = config.keybindings.spaceSwitchModifier.menuModifierFlags
    menuItem.target = SpaceMenuTarget.shared
    menuItem.tag = index
    menuItem.isEnabled = hasHotkey
    return menuItem
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
