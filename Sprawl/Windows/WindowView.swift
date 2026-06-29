import AppKit

/// A floating "window" panel on the canvas: draggable title bar, edge/corner resize,
/// close button, and a content area for hosting a terminal or editor.
///
/// Note on coordinates: the superview (`CanvasView`) is flipped (origin top-left, y grows
/// downward), so drag/resize math is done in the superview's coordinate space. The panel
/// itself is a standard (non-flipped) view for its own internal layout.
final class WindowView: NSView {
    static let headerHeight: CGFloat = 30
    static let resizeMargin: CGFloat = 7
    /// Inner margin between the panel edge and its hosted content.
    static let contentPadding: CGFloat = 12
    static let minSize = NSSize(width: 220, height: 140)

    /// macOS-style close-button red.
    private static let closeColor = NSColor(srgbRed: 1.0, green: 0.37, blue: 0.34, alpha: 1)
    private static func closeImage(_ name: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: "Close")?.withSymbolConfiguration(cfg)
    }

    /// Host terminal/editor views here.
    let contentContainer = ContentContainerView()

    var title: String = "Untitled" {
        didSet { needsDisplay = true }
    }
    /// Whether this item is selected — draws a white outline around the panel.
    var isSelected: Bool = false {
        didSet { guard isSelected != oldValue else { return }; needsDisplay = true }
    }
    var onClose: ((WindowView) -> Void)?
    var onFocus: ((WindowView) -> Void)?
    /// Called when the panel is moved or resized (so the canvas can redraw the project frame).
    var onGeometryChange: (() -> Void)?

    private let closeButton = NSButton()

    private struct Edge: OptionSet {
        let rawValue: Int
        static let left = Edge(rawValue: 1 << 0)
        static let right = Edge(rawValue: 1 << 1)
        static let top = Edge(rawValue: 1 << 2)
        static let bottom = Edge(rawValue: 1 << 3)
    }

    private enum DragMode { case none, move, resize(Edge) }
    private var dragMode: DragMode = .none
    private var dragStartMouse: NSPoint = .zero   // in superview (canvas) coords
    private var dragStartFrame: NSRect = .zero
    private var trackingArea: NSTrackingArea?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        layer?.masksToBounds = false

        closeButton.image = Self.closeImage("circle.fill")   // a red dot; shows ✕ on hover
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.contentTintColor = Self.closeColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        addSubview(closeButton)

        contentContainer.wantsLayer = true
        contentContainer.layer?.cornerRadius = 10
        contentContainer.layer?.masksToBounds = true   // round the hosted terminal/browser/editor
        addSubview(contentContainer)
        needsLayout = true
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
        needsDisplay = true
        onGeometryChange?()
    }

    override func layout() {
        super.layout()
        let b = bounds
        let pad = Self.contentPadding
        let header = Self.headerHeight
        let dot: CGFloat = 13
        closeButton.frame = NSRect(x: 11, y: b.height - header + (header - dot) / 2, width: dot, height: dot)
        // Content sits inside the panel with padding on the sides/bottom and below the header.
        contentContainer.frame = NSRect(
            x: pad,
            y: pad,
            width: max(0, b.width - 2 * pad),
            height: max(0, b.height - header - pad))
    }

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Host a terminal/editor view, filling the content area below the title bar.
    func setContent(_ view: NSView) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        layoutSubtreeIfNeeded()
        view.frame = contentContainer.bounds
        view.autoresizingMask = [.width, .height]
        contentContainer.addSubview(view)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 16
        let body = bounds.insetBy(dx: 0.5, dy: 0.5)
        let bodyPath = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

        // Thin chrome: a filled body and a single hairline border — no separate title-bar band.
        // Selection just recolors that 1px border.
        Palette.panelBody.setFill()
        bodyPath.fill()
        (isSelected ? Palette.panelBorderSelected : Palette.panelBorder).setStroke()
        bodyPath.lineWidth = 1
        bodyPath.stroke()

        // Centered title in the header strip, kept clear of the close dot.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: Palette.panelTitleText,
        ]
        let textSize = title.size(withAttributes: attrs)
        let textOrigin = NSPoint(
            x: max(closeButton.frame.maxX + 8, (bounds.width - textSize.width) / 2),
            y: bounds.height - Self.headerHeight + (Self.headerHeight - textSize.height) / 2)
        title.draw(at: textOrigin, withAttributes: attrs)
    }

    // MARK: - Mouse: move & resize

    override func mouseDown(with event: NSEvent) {
        onFocus?(self)
        let local = convert(event.locationInWindow, from: nil)
        let edges = edgeMask(at: local)
        if !edges.isEmpty {
            dragMode = .resize(edges)
        } else if local.y >= bounds.height - Self.headerHeight {
            dragMode = .move
        } else {
            dragMode = .none
        }
        dragStartMouse = superview?.convert(event.locationInWindow, from: nil) ?? .zero
        dragStartFrame = frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview = superview, case let mode = dragMode, !isNone(mode) else { return }
        let current = superview.convert(event.locationInWindow, from: nil)
        let dx = current.x - dragStartMouse.x
        let dy = current.y - dragStartMouse.y

        switch dragMode {
        case .move:
            frame.origin = NSPoint(x: dragStartFrame.origin.x + dx, y: dragStartFrame.origin.y + dy)
            onGeometryChange?()
        case .resize(let edges):
            var f = dragStartFrame
            if edges.contains(.right) {
                f.size.width = max(Self.minSize.width, dragStartFrame.width + dx)
            }
            if edges.contains(.left) {
                let w = max(Self.minSize.width, dragStartFrame.width - dx)
                f.origin.x = dragStartFrame.maxX - w
                f.size.width = w
            }
            // Superview is flipped: maxY is the visual bottom, origin.y the visual top.
            if edges.contains(.bottom) {
                f.size.height = max(Self.minSize.height, dragStartFrame.height + dy)
            }
            if edges.contains(.top) {
                let h = max(Self.minSize.height, dragStartFrame.height - dy)
                f.origin.y = dragStartFrame.maxY - h
                f.size.height = h
            }
            frame = f
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = .none
    }

    private func isNone(_ mode: DragMode) -> Bool {
        if case .none = mode { return true }
        return false
    }

    private func edgeMask(at p: NSPoint) -> Edge {
        var edges: Edge = []
        let m = Self.resizeMargin
        if p.x <= m { edges.insert(.left) }
        if p.x >= bounds.width - m { edges.insert(.right) }
        if p.y <= m { edges.insert(.bottom) }              // local non-flipped: low y = visual bottom
        if p.y >= bounds.height - m { edges.insert(.top) }  // high y = visual top
        return edges
    }

    // MARK: - Cursor feedback

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        // Reveal the ✕ when hovering the close dot, like the macOS traffic light.
        let overClose = closeButton.frame.insetBy(dx: -3, dy: -3).contains(local)
        closeButton.image = Self.closeImage(overClose ? "xmark.circle.fill" : "circle.fill")

        let edges = edgeMask(at: local)
        let horizontal = edges.contains(.left) || edges.contains(.right)
        let vertical = edges.contains(.top) || edges.contains(.bottom)
        if horizontal { NSCursor.resizeLeftRight.set() }
        else if vertical { NSCursor.resizeUpDown.set() }
        else { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        closeButton.image = Self.closeImage("circle.fill")
    }

    @objc private func closeClicked() {
        onClose?(self)
    }
}

/// Content area that lets clicks fall through to the panel when empty (so the panel still
/// raises/drags), but delivers events normally once real content is hosted inside it.
final class ContentContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result === self ? nil : result
    }
}
