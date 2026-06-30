import AppKit
import QuartzCore

/// A floating "window" panel on the canvas: draggable title bar, edge/corner resize,
/// close button, and a content area for hosting a terminal or editor.
///
/// Note on coordinates: the superview (`CanvasView`) is flipped (origin top-left, y grows
/// downward), so drag/resize math is done in the superview's coordinate space. The panel
/// itself is a standard (non-flipped) view for its own internal layout.
final class WindowView: NSView, NSTextFieldDelegate {
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
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
            onSelectionChange?(isSelected)
            if !isSelected { onDeselected?() }   // annotations stop editing when deselected
        }
    }
    /// Called when the panel goes from selected to not-selected (used to end annotation editing).
    var onDeselected: (() -> Void)?
    /// Called whenever selection changes (both directions) — used by lines to redraw their handles.
    var onSelectionChange: ((Bool) -> Void)?
    /// When set (line annotations), only points the closure marks "live" (the stroke / a handle)
    /// grab clicks — the rest of the transparent bounding box passes through to windows behind.
    /// The point is in this view's own coordinate space.
    var bodyHitTest: ((NSPoint) -> Bool)?
    /// Skip the chrome-less hover backdrop + selection outline (lines draw their own selection).
    var suppressBackdrop = false
    /// When true, the panel skips its opaque body fill, border, and title — used by glass panels
    /// (e.g. sticky notes) that supply their own translucent background.
    var transparentBody = false {
        didSet { guard transparentBody != oldValue else { return }; needsDisplay = true }
    }
    /// Chrome-less (free text): no close button/header, content fills the frame, the whole panel is
    /// a drag handle, double-click activates editing, and edge-resize is disabled (it auto-sizes).
    var chromeless = false {
        didSet { guard chromeless != oldValue else { return }; needsLayout = true; needsDisplay = true }
    }
    /// Whether edge/corner resize is enabled (off for auto-sizing free text).
    var resizable = true
    /// Corner radius for the body/glass/selection (smaller for annotations).
    var bodyCornerRadius: CGFloat = 16 {
        didSet { guard bodyCornerRadius != oldValue else { return }; needsLayout = true; needsDisplay = true }
    }
    /// Double-click on a chrome-less panel (e.g. to enter Free Text edit mode).
    var onActivate: (() -> Void)?
    /// Mouse is over the panel — drives the free-text hover backdrop.
    private var isHovered = false {
        didSet { guard isHovered != oldValue, chromeless else { return }; needsDisplay = true }
    }
    var onClose: ((WindowView) -> Void)?
    var onFocus: ((WindowView) -> Void)?
    /// Called when the panel is moved or resized (so the canvas can redraw the project frame).
    var onGeometryChange: (() -> Void)?
    /// Secondary geometry hook (e.g. to keep a floating options bar pinned above the panel).
    var onGeometryChange2: (() -> Void)?
    /// A move/resize drag finished — reports the before/after frame for one undoable step.
    var onGeometryCommitted: ((NSRect, NSRect) -> Void)?
    /// A *move* drag began / updated — drives live tiling reorder (placeholder gap) in tiled projects.
    var onMoveBegan: (() -> Void)?
    var onMoveChanged: (() -> Void)?
    /// A *resize* drag began / updated — drives live grid resize-to-span (placeholder) in grid projects.
    var onResizeBegan: (() -> Void)?
    var onResizeChanged: (() -> Void)?
    /// Double-click the header title committed a new name.
    var onRename: ((String) -> Void)?

    private let closeButton = NSButton()
    private weak var titleEditor: NSTextField?
    private var isEditingTitle = false

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
        // Rasterize the vector chrome (rounded body, border, title) off the main thread so frequent
        // redraws during resize/pan don't block the run loop.
        layer?.drawsAsynchronously = true

        closeButton.image = Self.closeImage("circle.fill")   // a red dot; shows ✕ on hover
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.contentTintColor = Self.closeColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        addSubview(closeButton)

        contentContainer.wantsLayer = true
        contentContainer.layer?.cornerRadius = 10
        contentContainer.layer?.cornerCurve = .continuous   // macOS squircle, matches the body
        contentContainer.layer?.masksToBounds = true   // round the hosted terminal/browser/editor
        // Opaque backing under the hosted content so a mid-resize repaint never flashes through.
        contentContainer.layer?.backgroundColor = Palette.panelBody.cgColor
        addSubview(contentContainer)
        needsLayout = true
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
        needsDisplay = true
        onGeometryChange?()
        onGeometryChange2?()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        onGeometryChange2?()   // keep a pinned options bar following the panel as it moves
    }

    override func layout() {
        super.layout()
        let b = bounds
        let pad = Self.contentPadding
        let header = Self.headerHeight
        let dot: CGFloat = 13
        closeButton.frame = NSRect(x: 11, y: b.height - header + (header - dot) / 2, width: dot, height: dot)
        if chromeless {
            // No header/close: the content fills the whole frame.
            contentContainer.frame = b
            layer?.shadowPath = CGPath(roundedRect: b, cornerWidth: bodyCornerRadius, cornerHeight: bodyCornerRadius, transform: nil)
            return
        }
        // Content sits inside the panel with padding on the sides/bottom and below the header.
        contentContainer.frame = NSRect(
            x: pad,
            y: pad,
            width: max(0, b.width - 2 * pad),
            height: max(0, b.height - header - pad))
        // Explicit shadow path so Core Animation doesn't recompute the shadow from the layer's
        // content every composite — the main cause of janky zoom/drag with several panels.
        layer?.shadowPath = CGPath(roundedRect: b, cornerWidth: bodyCornerRadius, cornerHeight: bodyCornerRadius, transform: nil)
    }

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Whether selecting this panel should pull keyboard focus to the window itself (true for
    /// non-text panels like annotations / lines / git widgets, so Delete/Escape act on the selection
    /// instead of being swallowed by a previously-focused text editor). Text panels leave focus in
    /// their content so typing keeps working.
    var focusable = false
    override var acceptsFirstResponder: Bool { focusable }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        guard let bodyHitTest else { return result }
        // A real subview (e.g. a line's node handle) claimed the point — let it through.
        if let result, result !== self { return result }
        // Otherwise only grab the click if it's on the live line body; empty padding passes through.
        // AppKit passes `point` in the *superview's* coordinate space (unlike UIKit), so convert it
        // to this view's local space — which equals the line content view's space (chromeless,
        // origin-aligned, non-flipped).
        return bodyHitTest(convert(point, from: superview)) ? self : nil
    }

    /// Host a terminal/editor view, filling the content area below the title bar.
    func setContent(_ view: NSView) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        layoutSubtreeIfNeeded()
        view.frame = contentContainer.bounds
        view.autoresizingMask = [.width, .height]
        contentContainer.addSubview(view)
    }

    /// Install a full-window translucent background (a glass sticky's frosted pastel) behind all
    /// chrome: makes the body transparent, clears the content backing so the glass shows through,
    /// and rounds the corners. The view is inserted at the back so the close dot/editor stay on top.
    func setGlassBackground(_ view: NSView) {
        transparentBody = true
        contentContainer.layer?.backgroundColor = NSColor.clear.cgColor
        view.wantsLayer = true
        view.layer?.cornerRadius = bodyCornerRadius
        view.layer?.masksToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Make the panel chrome-less and fully transparent (no body fill/border/title, clear content
    /// backing) — used by Free Text annotations that float directly on the canvas.
    func makeTransparent() {
        transparentBody = true
        contentContainer.layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// Chrome-less annotation panel: transparent + no close/header, content fills the frame, the
    /// whole panel drags, double-click activates editing. Free text disables resize (it auto-sizes);
    /// sticky keeps it. `cornerRadius` tunes the body/glass/selection rounding.
    func makeChromeless(resizable: Bool = false, cornerRadius: CGFloat = 6) {
        makeTransparent()
        closeButton.isHidden = true
        chromeless = true
        self.resizable = resizable
        bodyCornerRadius = cornerRadius
        needsLayout = true
    }

    /// Mount a small control (e.g. a sticky's color swatches) centered in the header strip, above
    /// the glass so it's clickable. Drag/rename still work on the rest of the header.
    func addHeaderAccessory(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: centerXAnchor),
            view.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            view.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let radius = bodyCornerRadius
        let body = bounds.insetBy(dx: 0.5, dy: 0.5)
        let bodyPath = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

        // Thin chrome: a filled body and a single hairline border — no separate title-bar band.
        // Selection just recolors that 1px border. Glass panels (transparentBody) draw neither,
        // and only get a selection outline. Free text (chromeless) shows a darkened hover backdrop.
        if !transparentBody {
            Palette.panelBody.setFill()
            bodyPath.fill()
            (isSelected ? Palette.panelBorderSelected : Palette.panelBorder).setStroke()
            bodyPath.lineWidth = 1
            bodyPath.stroke()
        } else {
            if chromeless && isHovered && !suppressBackdrop {
                NSColor(white: 0, alpha: 0.22).setFill()
                bodyPath.fill()
            }
            if isSelected && !suppressBackdrop {
                Palette.panelBorderSelected.setStroke()
                bodyPath.lineWidth = 1
                bodyPath.stroke()
            }
        }

        // Centered title in the header strip, kept clear of the close dot (hidden while editing).
        if !isEditingTitle && !transparentBody {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: isSelected ? Palette.panelHeaderTextSelected : Palette.panelHeaderText,
            ]
            let textSize = title.size(withAttributes: attrs)
            let textOrigin = NSPoint(
                x: max(closeButton.frame.maxX + 8, (bounds.width - textSize.width) / 2),
                y: bounds.height - Self.headerHeight + (Self.headerHeight - textSize.height) / 2)
            title.draw(at: textOrigin, withAttributes: attrs)
        }

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
        let edges = edgeMask(at: local)   // [] when !resizable
        if !edges.isEmpty {
            dragMode = .resize(edges)
        } else if chromeless {
            // Annotations: the whole panel drags; double-click activates editing (handled by the panel).
            if event.clickCount == 2 { onActivate?(); dragMode = .none } else { dragMode = .move }
        } else if local.y >= bounds.height - Self.headerHeight {
            if event.clickCount == 2 {   // double-click the header title → rename
                beginTitleEdit()
                dragMode = .none
                return
            }
            dragMode = .move
        } else {
            dragMode = .none
        }
        dragStartMouse = superview?.convert(event.locationInWindow, from: nil) ?? .zero
        dragStartFrame = frame
        if case .move = dragMode { onMoveBegan?() }
        if case .resize = dragMode { onResizeBegan?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview = superview, case let mode = dragMode, !isNone(mode) else { return }
        let current = superview.convert(event.locationInWindow, from: nil)
        let dx = current.x - dragStartMouse.x
        let dy = current.y - dragStartMouse.y

        // Suppress Core Animation's implicit position/bounds animation so the panel tracks the
        // cursor exactly instead of easing a frame behind it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch dragMode {
        case .move:
            let proposed = NSRect(origin: NSPoint(x: dragStartFrame.origin.x + dx, y: dragStartFrame.origin.y + dy),
                                  size: frame.size)
            frame.origin = neighborSnapOrigin(proposed)
            onGeometryChange?()
            onMoveChanged?()
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
            frame = neighborSnapResize(f, edges: edges)
            onResizeChanged?()
        case .none:
            break
        }
    }

    // MARK: - Smart-guide snapping (align to nearby windows)

    /// Snapping is on whenever the canvas grid toggle is on (the grid magnitude drives line/placement
    /// snapping; windows align to each other instead of an absolute grid).
    private var snappingOn: Bool { ((superview as? CanvasView)?.snapGrid ?? 0) > 0 }

    /// Frames of the other windows on the canvas (snap targets).
    private func neighborFrames() -> [NSRect] {
        (superview?.subviews ?? []).compactMap {
            ($0 as? WindowView).flatMap { v in (v !== self && !v.isHidden) ? v.frame : nil }
        }
    }

    /// ~8 on-screen points, expressed in canvas units (so the magnet feels the same at any zoom).
    private var snapThreshold: CGFloat {
        let mag = (superview as? CanvasView)?.enclosingScrollView?.magnification ?? 1
        return 8 / max(mag, 0.01)
    }

    /// The smallest target-minus-value offset within `threshold`, or nil if none is close enough.
    private func nearestOffset(_ values: [CGFloat], to targets: [CGFloat], threshold: CGFloat) -> CGFloat? {
        var best: CGFloat?
        for v in values {
            for t in targets {
                let d = t - v
                if abs(d) <= threshold, abs(d) < (best.map { abs($0) } ?? .greatestFiniteMagnitude) { best = d }
            }
        }
        return best
    }

    /// Align the moving window's left/center/right (and top/middle/bottom) to nearby windows' edges
    /// and centers; otherwise move freely (no absolute grid).
    private func neighborSnapOrigin(_ proposed: NSRect) -> NSPoint {
        guard snappingOn else { return proposed.origin }
        let others = neighborFrames()
        guard !others.isEmpty else { return proposed.origin }
        let t = snapThreshold
        var origin = proposed.origin
        if let off = nearestOffset([proposed.minX, proposed.midX, proposed.maxX],
                                   to: others.flatMap { [$0.minX, $0.midX, $0.maxX] }, threshold: t) {
            origin.x += off
        }
        if let off = nearestOffset([proposed.minY, proposed.midY, proposed.maxY],
                                   to: others.flatMap { [$0.minY, $0.midY, $0.maxY] }, threshold: t) {
            origin.y += off
        }
        return origin
    }

    /// Align a dragged edge to nearby windows' matching edges/centers, keeping the opposite edge fixed.
    private func neighborSnapResize(_ rect: NSRect, edges: Edge) -> NSRect {
        guard snappingOn else { return rect }
        let others = neighborFrames()
        guard !others.isEmpty else { return rect }
        let t = snapThreshold
        let xs = others.flatMap { [$0.minX, $0.midX, $0.maxX] }
        let ys = others.flatMap { [$0.minY, $0.midY, $0.maxY] }
        var r = rect
        if edges.contains(.left), let off = nearestOffset([r.minX], to: xs, threshold: t) {
            let right = r.maxX; r.origin.x = r.minX + off; r.size.width = max(Self.minSize.width, right - r.origin.x)
        }
        if edges.contains(.right), let off = nearestOffset([r.maxX], to: xs, threshold: t) {
            r.size.width = max(Self.minSize.width, (r.maxX + off) - r.minX)
        }
        if edges.contains(.top), let off = nearestOffset([r.minY], to: ys, threshold: t) {
            let bottom = r.maxY; r.origin.y = r.minY + off; r.size.height = max(Self.minSize.height, bottom - r.origin.y)
        }
        if edges.contains(.bottom), let off = nearestOffset([r.maxY], to: ys, threshold: t) {
            r.size.height = max(Self.minSize.height, (r.maxY + off) - r.minY)
        }
        return r
    }

    override func mouseUp(with event: NSEvent) {
        switch dragMode {
        case .move, .resize:
            if frame != dragStartFrame { onGeometryCommitted?(dragStartFrame, frame) }
        case .none:
            break
        }
        dragMode = .none
    }

    private func isNone(_ mode: DragMode) -> Bool {
        if case .none = mode { return true }
        return false
    }

    // MARK: - Rename (double-click the header title)

    private func beginTitleEdit() {
        guard !isEditingTitle else { return }
        let header = Self.headerHeight
        let x = closeButton.frame.maxX + 8
        let editRect = NSRect(x: x, y: bounds.height - header + 4,
                              width: max(40, bounds.width - x - 12), height: header - 8)
        let field = NSTextField(frame: editRect)
        field.stringValue = title
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.textColor = Palette.panelTitleText
        field.drawsBackground = true
        field.backgroundColor = Palette.editorBackground
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.alignment = .center
        field.wantsLayer = true
        field.layer?.cornerRadius = 5
        field.delegate = self
        field.autoresizingMask = [.width, .minYMargin]
        addSubview(field)
        titleEditor = field
        isEditingTitle = true
        needsDisplay = true
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: (title as NSString).length)
    }

    private func endTitleEdit(commit: Bool) {
        guard isEditingTitle, let field = titleEditor else { return }
        isEditingTitle = false
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        titleEditor = nil
        needsDisplay = true
        if commit, !newName.isEmpty, newName != title { onRename?(newName) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { endTitleEdit(commit: true); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { endTitleEdit(commit: false); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if isEditingTitle { endTitleEdit(commit: true) }   // blur (clicking away) commits
    }

    private func edgeMask(at p: NSPoint) -> Edge {
        if !resizable { return [] }   // free text auto-sizes; no edge-resize
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

    override func mouseEntered(with event: NSEvent) { isHovered = true }

    override func mouseMoved(with event: NSEvent) {
        isHovered = true
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
        isHovered = false
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
