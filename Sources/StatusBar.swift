import Cocoa

private var statusItem: NSStatusItem?
private var stackView: NSStackView?

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

    updateStatusBar()
}

func updateStatusBar() {
    guard let stack = stackView else { return }

    let spaces = orderedSpaceIDs()
    let active = activeSpaceID()

    var occupiedSpaces: Set<CGSSpaceID> = []
    for (_, win) in managedWindows {
        if let space = spaceForWindow(win.id) {
            occupiedSpaces.insert(space)
        }
    }

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

    for (i, space) in spaces.enumerated() {
        let isActive = space == active
        let isOccupied = occupiedSpaces.contains(space)

        let color: NSColor
        if isActive { color = NSColor.labelColor }
        else if isOccupied { color = NSColor.labelColor }
        else { color = NSColor.tertiaryLabelColor }

        let weight: NSFont.Weight = isActive ? .medium : .regular
        let label = stack.arrangedSubviews[i] as! SpaceButton
        label.attributedTitle = NSAttributedString(
            string: "\(i + 1)",
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
