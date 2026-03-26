import Cocoa

private var statusItem: NSStatusItem?

func setupStatusBar() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem?.button?.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    updateStatusBar()
}

func updateStatusBar() {
    guard let button = statusItem?.button else { return }

    let spaces = orderedSpaceIDs()
    let active = activeSpaceID()

    var occupiedSpaces: Set<CGSSpaceID> = []
    for (_, win) in managedWindows {
        if let space = spaceForWindow(win.id) {
            occupiedSpaces.insert(space)
        }
    }

    let attributed = NSMutableAttributedString()
    let activeColor = NSColor.controlAccentColor
    let occupiedColor = NSColor.labelColor
    let emptyColor = NSColor.tertiaryLabelColor

    for (i, space) in spaces.enumerated() {
        let label = "\(i + 1)"
        let isActive = space == active
        let isOccupied = occupiedSpaces.contains(space)

        let color: NSColor
        if isActive { color = activeColor }
        else if isOccupied { color = occupiedColor }
        else { color = emptyColor }

        let weight: NSFont.Weight = isActive ? .bold : .regular
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.monospacedSystemFont(ofSize: 16, weight: weight),
        ]

        if i > 0 {
            attributed.append(NSAttributedString(string: " ", attributes: attrs))
        }
        attributed.append(NSAttributedString(string: label, attributes: attrs))
    }

    button.attributedTitle = attributed
}
