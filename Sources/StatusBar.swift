import Cocoa

private var statusItem: NSStatusItem?
private var stackView: NSStackView?
private var lastRenderedSpaces: [CGSSpaceID] = []
private var lastRenderedActive: CGSSpaceID = 0
private var lastRenderedOccupied: Set<CGSSpaceID> = []

func setupStatusBar() {
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

func updateStatusBar(activeSpace: CGSSpaceID) {
    guard let stack = stackView else { return }

    let spaces = orderedSpaces()
    let spaceIDs = spaces.map { $0.id }

    var occupiedSpaces: Set<CGSSpaceID> = []
    for (_, win) in managedWindows {
        if let space = spaceForWindow(win.id) {
            occupiedSpaces.insert(space)
        }
    }

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

    var desktopNumber = 1
    for (i, space) in spaces.enumerated() {
        let isActive = space.id == activeSpace
        let isOccupied = occupiedSpaces.contains(space.id)

        let color: NSColor
        if isActive { color = NSColor.labelColor }
        else if isOccupied { color = NSColor.labelColor }
        else { color = NSColor.tertiaryLabelColor }

        let title: String
        if space.isFullScreen {
            title = appNameForSpace(space.id).flatMap { $0.first.map(String.init) } ?? "F"
        } else {
            title = "\(desktopNumber)"
            desktopNumber += 1
        }

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
    postKeyEvent(keyCode: spaceKeyCodes[index])
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
