import Cocoa

// An i3-style outline drawn around the focused window. The outline is split
// across four borderless, click-through overlay panels, one for each edge of
// the window. Mission Control omits a window that another window covers
// completely, and an edge panel covers only a thin strip. The panels join every
// Space and float above normal windows. The tick loop feeds them the focused
// window's frame each tick, so they track tiling, focus-follows-mouse, and
// Space changes without any extra bookkeeping.
//
// The corner radius is a fixed, configurable value rather than something
// measured per window: macOS exposes no public per-window radius, and on Tahoe
// the window radius is a global appearance value (NSConvolutionOverride1). wm
// pins that global value to `corner_radius` (see pinWindowCornerRadius), so a
// single config value drives both the rendered corners and the outline.

private enum BorderEdge: CaseIterable {
    case top, bottom, left, right
}

// Returns the strip of a window that the edge's panel covers, in the window's
// own coordinates with a bottom-left origin. The top and bottom strips are tall
// enough to hold the rounded corners. The left and right strips fill the space
// between them.
private func edgeStrip(_ edge: BorderEdge, of size: CGSize) -> CGRect {
    let cornerHeight = min(max(config.cornerRadius, config.borderWidth), size.height / 2)
    let sideWidth = min(config.borderWidth, size.width / 2)
    let sideHeight = size.height - 2 * cornerHeight
    switch edge {
    case .top:
        return CGRect(x: 0, y: size.height - cornerHeight, width: size.width, height: cornerHeight)
    case .bottom:
        return CGRect(x: 0, y: 0, width: size.width, height: cornerHeight)
    case .left:
        return CGRect(x: 0, y: cornerHeight, width: sideWidth, height: sideHeight)
    case .right:
        return CGRect(x: size.width - sideWidth, y: cornerHeight, width: sideWidth, height: sideHeight)
    }
}

// Draws the part of the window's outline that falls inside one edge strip.
private final class BorderView: NSView {
    // The strip that this view covers, and the size of the window that the
    // strip belongs to.
    var strip: CGRect = .zero
    var windowSize: CGSize = .zero

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // The outline is the window's frame, expressed in this view's
        // coordinates. Stroking a rectangle inset by half the line width draws
        // the border over the window's outermost pixels (its outer edge flush
        // with the window edge), rather than extending past it. The stroke
        // centerline runs borderWidth/2 inside the window edge, so its radius
        // is the window's corner radius minus that offset — keeping the outline
        // concentric with the rounded corners.
        let borderWidth = config.borderWidth
        let outline = CGRect(origin: CGPoint(x: -strip.minX, y: -strip.minY), size: windowSize)
        let rect = outline.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
        let radius = max(0, config.cornerRadius - borderWidth / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = borderWidth
        config.borderColor.setStroke()
        path.stroke()
    }
}

private var borderPanels: [BorderEdge: NSPanel] = [:]
private var lastBorderFrame: CGRect?

private func makeBorderPanel() -> NSPanel {
    let panel = NSPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .floating
    panel.ignoresMouseEvents = true
    // Join all Spaces so the panel follows focus across Spaces without being
    // moved; stationary keeps it out of Mission Control's window shuffle.
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    panel.contentView = BorderView(frame: .zero)
    return panel
}

func setupFocusBorder() {
    guard borderPanels.isEmpty else { return }
    for edge in BorderEdge.allCases {
        borderPanels[edge] = makeBorderPanel()
    }
}

func teardownFocusBorder() {
    for panel in borderPanels.values { panel.orderOut(nil) }
    borderPanels = [:]
    lastBorderFrame = nil
}

// Re-apply appearance after a config reload without recreating the panels.
func refreshFocusBorderStyle() {
    guard let frame = lastBorderFrame else { return }
    placeBorderPanels(around: frame)
}

// Hides the panels by making them transparent, not by ordering them out. An
// orderOut/orderFront cycle around a native-fullscreen exit re-inserts a panel
// while the dying fullscreen Space is still frontmost; the window server then
// reassigns it to a single regular Space, silently dropping the
// canJoinAllSpaces stickiness — after which the border only ever appears on
// that one Space. Keeping the panels ordered in preserves their Space tags.
private func hideBorderPanels() {
    for panel in borderPanels.values where panel.alphaValue != 0 {
        panel.alphaValue = 0
    }
    lastBorderFrame = nil
}

// Moves the edge's panel to its strip of the window frame, which is in Cocoa
// coordinates, and redraws it.
private func placeBorderPanel(_ panel: NSPanel, edge: BorderEdge, around frame: CGRect) {
    let strip = edgeStrip(edge, of: frame.size)
    if let view = panel.contentView as? BorderView {
        view.strip = strip
        view.windowSize = frame.size
        view.needsDisplay = true
    }
    panel.setFrame(strip.offsetBy(dx: frame.minX, dy: frame.minY), display: true)
}

private func placeBorderPanels(around frame: CGRect) {
    for (edge, panel) in borderPanels {
        placeBorderPanel(panel, edge: edge, around: frame)
    }
}

private func showBorderPanel(_ panel: NSPanel) {
    if panel.alphaValue != 1 { panel.alphaValue = 1 }
    if !panel.isVisible { panel.orderFrontRegardless() }
}

// `focusedFrame` is the focused window's on-screen frame in CG coordinates
// (top-left origin), or nil when nothing manageable is focused.
func updateFocusBorder(focusedFrame: CGRect?) {
    guard !borderPanels.isEmpty else { return }
    guard let cg = focusedFrame, cg.width > 0, cg.height > 0 else {
        hideBorderPanels()
        return
    }

    let cocoa = flipVertical(cg)
    if lastBorderFrame != cocoa {
        placeBorderPanels(around: cocoa)
        lastBorderFrame = cocoa
    }
    borderPanels.values.forEach(showBorderPanel)
}
