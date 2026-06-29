import AppKit

/// A floating "window" panel on the canvas: draggable title bar, edge/corner resize,
/// close button, and a content area for hosting a terminal or editor.
///
/// Note on coordinates: the superview (`CanvasView`) is flipped (origin top-left, y grows
/// downward), so drag/resize math is done in the superview's coordinate space. The panel
/// itself is a standard (non-flipped) view for its own internal layout.
final class WindowView: NSView {
    static let headerHeight: CGFloat = 30
    /// Edge band that triggers a resize on hover/drag.
    static let resizeMargin: CGFloat = 12
    /// Larger box near each corner that resizes both axes at once.
    static let cornerSize: CGFloat = 26
    /// Inner margin between the panel edge and its hosted content.
    static let contentPadding: CGFloat = 12
    static let minSize = NSSize(width: 220, height: 140)

    /// Edges currently under the cursor — drives the white resize indicator drawn on hover.
    private var hoverEdges: Edge = [] {
        didSet { guard hoverEdges != oldValue else { return }; needsDisplay = true }
    }

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
            .foregroundColor: isSelected ? Palette.panelHeaderTextSelected : Palette.panelHeaderText,
        ]
        let textSize = title.size(withAttributes: attrs)
        let textOrigin = NSPoint(
            x: max(closeButton.frame.maxX + 8, (bounds.width - textSize.width) / 2),
            y: bounds.height - Self.headerHeight + (Self.headerHeight - textSize.height) / 2)
        title.draw(at: textOrigin, withAttributes: attrs)

        drawResizeIndicator()
    }

    /// On hover, a thick white rounded line marks the edge you'd resize — a full line along an
    /// edge, or a short diagonal stroke over a corner (which resizes both axes).
    private func drawResizeIndicator() {
        guard !hoverEdges.isEmpty else { return }
        let b = bounds
        let inset: CGFloat = 5      // how far the line sits inside the edge
        let endInset: CGFloat = 20  // edge lines stop short of the corners
        let path = NSBezierPath()
        path.lineWidth = 3
        path.lineCapStyle = .round

        let horizontal = hoverEdges.contains(.left) || hoverEdges.contains(.right)
        let vertical = hoverEdges.contains(.top) || hoverEdges.contains(.bottom)
        if horizontal && vertical {
            // Trace the panel's rounded corner (a quarter arc), not a diagonal.
            let radius: CGFloat = 16   // matches the body corner radius in draw()
            let left = hoverEdges.contains(.left), bottom = hoverEdges.contains(.bottom)
            let center = NSPoint(x: left ? radius + 0.5 : b.width - radius - 0.5,
                                 y: bottom ? radius + 0.5 : b.height - radius - 0.5)
            let start: CGFloat, end: CGFloat
            if left && bottom { start = 180; end = 270 }
            else if left { start = 90; end = 180 }        // left + top
            else if bottom { start = 270; end = 360 }      // right + bottom
            else { start = 0; end = 90 }                   // right + top
            path.appendArc(withCenter: center, radius: radius - 1.5, startAngle: start, endAngle: end)
        } else {
            if hoverEdges.contains(.left) {
                path.move(to: NSPoint(x: inset, y: endInset)); path.line(to: NSPoint(x: inset, y: b.height - endInset))
            }
            if hoverEdges.contains(.right) {
                path.move(to: NSPoint(x: b.width - inset, y: endInset)); path.line(to: NSPoint(x: b.width - inset, y: b.height - endInset))
            }
            if hoverEdges.contains(.top) {
                path.move(to: NSPoint(x: endInset, y: b.height - inset)); path.line(to: NSPoint(x: b.width - endInset, y: b.height - inset))
            }
            if hoverEdges.contains(.bottom) {
                path.move(to: NSPoint(x: endInset, y: inset)); path.line(to: NSPoint(x: b.width - endInset, y: inset))
            }
        }
        NSColor.white.setStroke()
        path.stroke()
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

        let grid = (superview as? CanvasView)?.snapGrid ?? 0
        switch dragMode {
        case .move:
            frame.origin = NSPoint(x: CanvasView.snap(dragStartFrame.origin.x + dx, to: grid),
                                   y: CanvasView.snap(dragStartFrame.origin.y + dy, to: grid))
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
            frame = snappedResize(f, edges: edges, grid: grid)
        case .none:
            break
        }
    }

    /// Snap the edges being dragged to the grid (no-op when snapping is off), keeping the opposite
    /// edge fixed and respecting the minimum size.
    private func snappedResize(_ rect: NSRect, edges: Edge, grid: CGFloat) -> NSRect {
        guard grid > 0 else { return rect }
        var r = rect
        if edges.contains(.left) {
            let right = r.maxX
            r.origin.x = CanvasView.snap(r.minX, to: grid)
            r.size.width = max(Self.minSize.width, right - r.origin.x)
        }
        if edges.contains(.right) {
            r.size.width = max(Self.minSize.width, CanvasView.snap(r.maxX, to: grid) - r.minX)
        }
        if edges.contains(.top) {
            let bottom = r.maxY
            r.origin.y = CanvasView.snap(r.minY, to: grid)
            r.size.height = max(Self.minSize.height, bottom - r.origin.y)
        }
        if edges.contains(.bottom) {
            r.size.height = max(Self.minSize.height, CanvasView.snap(r.maxY, to: grid) - r.minY)
        }
        return r
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = .none
    }

    private func isNone(_ mode: DragMode) -> Bool {
        if case .none = mode { return true }
        return false
    }

    private func edgeMask(at p: NSPoint) -> Edge {
        let m = Self.resizeMargin
        let c = Self.cornerSize
        // A larger corner box (c) takes precedence so corners resize both axes at once.
        let nearLeft = p.x <= c, nearRight = p.x >= bounds.width - c
        let nearBottom = p.y <= c, nearTop = p.y >= bounds.height - c   // non-flipped: low y = bottom
        if nearLeft && nearBottom { return [.left, .bottom] }
        if nearLeft && nearTop { return [.left, .top] }
        if nearRight && nearBottom { return [.right, .bottom] }
        if nearRight && nearTop { return [.right, .top] }
        var edges: Edge = []
        if p.x <= m { edges.insert(.left) }
        if p.x >= bounds.width - m { edges.insert(.right) }
        if p.y <= m { edges.insert(.bottom) }
        if p.y >= bounds.height - m { edges.insert(.top) }
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
        hoverEdges = edges
        let horizontal = edges.contains(.left) || edges.contains(.right)
        let vertical = edges.contains(.top) || edges.contains(.bottom)
        if horizontal && vertical { NSCursor.crosshair.set() }   // corner (no public diagonal cursor)
        else if horizontal { NSCursor.resizeLeftRight.set() }
        else if vertical { NSCursor.resizeUpDown.set() }
        else { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        closeButton.image = Self.closeImage("circle.fill")
        hoverEdges = []
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
