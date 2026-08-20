import Cocoa

// An i3-style outline drawn around the focused window. The border lives in a
// single borderless, click-through overlay panel that joins every Space and
// floats above normal windows. The tick loop feeds it the focused window's
// frame each tick, so it tracks tiling, focus-follows-mouse, and Space changes
// without any extra bookkeeping.
//
// The corner radius is a fixed, configurable value rather than something
// measured per window: macOS exposes no public per-window radius, and on Tahoe
// the window radius is a global appearance value (NSConvolutionOverride1). wm
// pins that global value to `corner_radius` (see pinWindowCornerRadius), so a
// single config value drives both the rendered corners and the outline.

private final class BorderView: NSView {
    // Placeholders; setupFocusBorder overwrites all three from config before the
    // view is ever shown.
    var borderColor: NSColor = defaultBorderColor
    var borderWidth: CGFloat = 1
    var cornerRadius: CGFloat = 12  // matches the system window corner radius

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // The panel covers the window exactly, so stroking a rectangle inset by
        // half the line width draws the border over the window's outermost
        // pixels (its outer edge flush with the window edge), rather than
        // extending past it. The stroke centerline runs borderWidth/2 inside the
        // window edge, so its radius is the window's corner radius minus that
        // offset — keeping the outline concentric with the rounded corners.
        let rect = bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
        let radius = max(0, cornerRadius - borderWidth / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = borderWidth
        borderColor.setStroke()
        path.stroke()
    }
}

private var borderWindow: NSPanel?
private var borderView: BorderView?
private var lastBorderFrame: CGRect?

func setupFocusBorder() {
    guard borderWindow == nil else { return }

    let panel = NSPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .floating
    panel.ignoresMouseEvents = true
    // Join all Spaces so the single panel follows focus across Spaces without
    // being moved; stationary keeps it out of Mission Control's window shuffle.
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

    let view = BorderView(frame: .zero)
    view.borderColor = config.borderColor
    view.borderWidth = config.borderWidth
    view.cornerRadius = config.cornerRadius
    panel.contentView = view

    borderView = view
    borderWindow = panel
}

func teardownFocusBorder() {
    borderWindow?.orderOut(nil)
    borderWindow = nil
    borderView = nil
    lastBorderFrame = nil
}

// Re-apply appearance after a config reload without recreating the panel.
func refreshFocusBorderStyle() {
    borderView?.borderColor = config.borderColor
    borderView?.borderWidth = config.borderWidth
    borderView?.cornerRadius = config.cornerRadius
    lastBorderFrame = nil  // force a redraw+reposition on the next update
    borderView?.needsDisplay = true
}

// `focusedFrame` is the focused window's on-screen frame in CG coordinates
// (top-left origin), or nil when nothing manageable is focused.
func updateFocusBorder(focusedFrame: CGRect?) {
    guard let panel = borderWindow else { return }

    // Hide by making the panel transparent, not by ordering it out. An
    // orderOut/orderFront cycle around a native-fullscreen exit re-inserts the
    // panel while the dying fullscreen Space is still frontmost; the window
    // server then reassigns it to a single regular Space, silently dropping the
    // canJoinAllSpaces stickiness — after which the border only ever appears on
    // that one Space. Keeping the panel ordered in preserves its Space tags.
    guard let cg = focusedFrame, cg.width > 0, cg.height > 0 else {
        if panel.alphaValue != 0 { panel.alphaValue = 0 }
        lastBorderFrame = nil
        return
    }

    let cocoa = flipVertical(cg)

    if lastBorderFrame != cocoa {
        panel.setFrame(cocoa, display: true)
        borderView?.needsDisplay = true
        lastBorderFrame = cocoa
    }
    if panel.alphaValue != 1 { panel.alphaValue = 1 }
    if !panel.isVisible { panel.orderFrontRegardless() }
}
