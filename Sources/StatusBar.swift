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

        let weight: NSFont.Weight = isActive ? .bold : .regular
        let label = stack.arrangedSubviews[i] as! SpaceButton
        label.attributedTitle = NSAttributedString(
            string: "\(i + 1)",
            attributes: [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: 16, weight: weight),
            ]
        )
        label.spaceIndex = i
    }

    statusItem?.length = stack.fittingSize.width + 8
}

func switchToSpace(_ index: Int) {
    let codes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    guard index < codes.count else { return }
    let source = CGEventSource(stateID: .hidSystemState)
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: codes[index], keyDown: true)!
    keyDown.flags = .maskControl
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: codes[index], keyDown: false)!
    keyUp.flags = .maskControl
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
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
