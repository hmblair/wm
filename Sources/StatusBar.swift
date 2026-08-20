import Cocoa

private var statusItem: NSStatusItem?
private var stackView: NSStackView?
private var lastRenderedSpaces: [CGSSpaceID] = []
private var lastRenderedActive: CGSSpaceID = 0
private var lastRenderedOccupied: Set<CGSSpaceID> = []

// The occupied-space set requires one SkyLight IPC per managed window
// (spaceForWindow). That set only changes when the managed-window membership
// changes, so we recompute it then and cache it across the (common) ticks where
// only the cursor or active Space moved. executePlan sets the dirty flag.
var statusBarOccupancyDirty = true
private var cachedOccupied: Set<CGSSpaceID> = []

func setupStatusBar() {
    guard statusItem == nil else { return }

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.spacing = 2
    stackView = stack

    statusItem?.button?.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        stack.centerXAnchor.constraint(equalTo: statusItem!.button!.centerXAnchor),
        stack.centerYAnchor.constraint(equalTo: statusItem!.button!.centerYAnchor),
    ])

    updateStatusBar(activeSpace: activeSpaceID())
}

func teardownStatusBar() {
    if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
    statusItem = nil
    stackView = nil
    // Reset render caches so a later setup repaints from scratch.
    lastRenderedSpaces = []
    lastRenderedActive = 0
    lastRenderedOccupied = []
    statusBarOccupancyDirty = true
}

func updateStatusBar(activeSpace: CGSSpaceID) {
    guard let stack = stackView else { return }

    if statusBarOccupancyDirty {
        var occupied: Set<CGSSpaceID> = []
        for (_, win) in managedWindows {
            if let space = spaceForWindow(win.id) {
                occupied.insert(space)
            }
        }
        cachedOccupied = occupied
        statusBarOccupancyDirty = false
    }
    let occupiedSpaces = cachedOccupied

    let spaces = orderedSpaces()
    let spaceIDs = spaces.map { $0.id }

    // Skip update if nothing changed
    guard spaceIDs != lastRenderedSpaces
       || activeSpace != lastRenderedActive
       || occupiedSpaces != lastRenderedOccupied else { return }

    lastRenderedSpaces = spaceIDs
    lastRenderedActive = activeSpace
    lastRenderedOccupied = occupiedSpaces

    // Add/remove labels to match space count
    while stack.arrangedSubviews.count < spaces.count {
        let label = SpaceButton()
        stack.addArrangedSubview(label)
    }
    while stack.arrangedSubviews.count > spaces.count {
        let view = stack.arrangedSubviews.last!
        stack.removeArrangedSubview(view)
        view.removeFromSuperview()
    }

    let labels = spaceLabels(for: spaces)
    for (i, space) in spaces.enumerated() {
        let isActive = space.id == activeSpace
        let isOccupied = occupiedSpaces.contains(space.id)

        // Active or occupied Spaces read as primary; empty Spaces are dimmed.
        let color = (isActive || isOccupied) ? NSColor.labelColor : NSColor.tertiaryLabelColor
        let title = labels[i]
        let weight: NSFont.Weight = isActive ? .medium : .regular
        let label = stack.arrangedSubviews[i] as! SpaceButton
        label.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: 13, weight: weight),
            ]
        )
        label.spaceIndex = i
    }

    statusItem?.length = stack.fittingSize.width + 2
}

func switchToSpace(_ index: Int) {
    guard index < spaceKeyCodes.count else { return }
    postKeyEvent(keyCode: spaceKeyCodes[index],
                 flags: config.keybindings.spaceSwitchModifier.eventFlags)
}

private class SpaceButton: NSButton {
    var spaceIndex: Int = 0

    init() {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryLight)
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() {
        debug("statusbar: clicked space \(spaceIndex + 1)")
        switchToSpace(spaceIndex)
    }
}
