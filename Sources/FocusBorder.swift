import Cocoa

// An i3-style outline drawn around the focused window. Four borderless,
// click-through panels draw the outline, one for each edge, so no panel covers
// a window completely. Mission Control omits a window that is covered
// completely. The panels join every Space and float above normal windows. The
// tick loop feeds them the focused window's frame each tick, so they track
// tiling, focus-follows-mouse, and Space changes without any extra bookkeeping.
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

private func largestScreenSize() -> CGSize {
    return NSScreen.screens.reduce(.zero) { size, screen in
        CGSize(width: max(size.width, screen.frame.width), height: max(size.height, screen.frame.height))
    }
}

// Returns the panel frame for an edge strip, in the window's own coordinates.
// The panel is as long as the largest screen, so it only moves when the window
// resizes. After a Space switch, macOS can fail to grow a resized panel's
// drawing surface. The panel extends down, because macOS moves a window that
// extends above the screen.
private func panelFrame(_ edge: BorderEdge, for strip: CGRect) -> CGRect {
    let length = largestScreenSize()
    switch edge {
    case .top, .bottom:
        return CGRect(x: strip.minX, y: strip.minY, width: length.width, height: strip.height)
    case .left, .right:
        return CGRect(x: strip.minX, y: strip.maxY - length.height, width: strip.width, height: length.height)
    }
}

// Draws the part of the window's outline that falls inside one edge strip. A
// shape layer draws the outline, because AppKit can skip the redraw of a panel
// just after a Space switch.
private final class BorderView: NSView {
    private let outlineLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        outlineLayer.fillColor = nil
        outlineLayer.masksToBounds = true
        layer?.addSublayer(outlineLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("BorderView does not support coding")
    }

    // Draws the outline of a window of the given size, clipped to a strip of
    // that window. The strip and the panel frame are in the window's own
    // coordinates. The stroke is inset by half its width, so it covers the
    // window's outermost pixels and stays concentric with the rounded corners.
    func drawOutline(ofWindowSize windowSize: CGSize, clippedTo strip: CGRect, panelFrame: CGRect) {
        let borderWidth = config.borderWidth
        let outline = CGRect(origin: CGPoint(x: -strip.minX, y: -strip.minY), size: windowSize)
        let rect = outline.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outlineLayer.frame = strip.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)
        outlineLayer.contentsScale = window?.backingScaleFactor ?? 1
        outlineLayer.path = roundedRectPath(rect, radius: config.cornerRadius - borderWidth / 2)
        outlineLayer.lineWidth = borderWidth
        outlineLayer.strokeColor = config.borderColor.cgColor
        CATransaction.commit()
    }
}

// Returns a rounded rectangle path. The radius is clamped to the range that
// CGPath accepts, which is at most half of the shorter side.
private func roundedRectPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let clamped = min(max(0, radius), rect.width / 2, rect.height / 2)
    return CGPath(roundedRect: rect, cornerWidth: clamped, cornerHeight: clamped, transform: nil)
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
// coordinates, and draws its part of the outline.
private func placeBorderPanel(_ panel: NSPanel, edge: BorderEdge, around frame: CGRect) {
    let strip = edgeStrip(edge, of: frame.size)
    let stripPanelFrame = panelFrame(edge, for: strip)
    panel.setFrame(stripPanelFrame.offsetBy(dx: frame.minX, dy: frame.minY), display: false)
    (panel.contentView as? BorderView)?.drawOutline(
        ofWindowSize: frame.size, clippedTo: strip, panelFrame: stripPanelFrame)
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
