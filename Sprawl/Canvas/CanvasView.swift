import AppKit

/// The large document view that hosts window panels. Flipped so the origin is top-left,
/// which is more natural for positioning windows. Draws a dotted grid and a per-project
/// boundary frame; only the visible `dirtyRect` is rendered, so the huge canvas stays cheap.
final class CanvasView: NSView {
    static let canvasSize = NSSize(width: 20_000, height: 20_000)

    private let gridSpacing: CGFloat = 40
    private let framePadding: CGFloat = 80
    private var spawnOffset: CGFloat = 0

    /// Fired when the set or arrangement of panels changes (add, close, move, resize, raise),
    /// so the workspace can be autosaved.
    var onLayoutChange: (() -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: .zero, size: CanvasView.canvasSize))
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.canvas.setFill()
        dirtyRect.fill()

        drawGrid(in: dirtyRect)
        drawProjectFrame()
    }

    private func drawGrid(in dirtyRect: NSRect) {
        Palette.gridDot.setFill()
        let startX = floor(dirtyRect.minX / gridSpacing) * gridSpacing
        let startY = floor(dirtyRect.minY / gridSpacing) * gridSpacing

        var y = startY
        while y <= dirtyRect.maxY {
            var x = startX
            while x <= dirtyRect.maxX {
                NSRect(x: x - 1, y: y - 1, width: 2, height: 2).fill()
                x += gridSpacing
            }
            y += gridSpacing
        }
    }

    /// A 2px boundary surrounding the project's windows with `framePadding` on every side.
    private func drawProjectFrame() {
        let windows = subviews.compactMap { $0 as? WindowView }
        let content: NSRect
        if let first = windows.first {
            content = windows.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        } else {
            let size = NSSize(width: 900, height: 600)
            content = NSRect(
                x: Self.canvasSize.width / 2 - size.width / 2,
                y: Self.canvasSize.height / 2 - size.height / 2,
                width: size.width,
                height: size.height)
        }

        let box = content.insetBy(dx: -framePadding, dy: -framePadding)
        let path = NSBezierPath(rect: box)
        path.lineWidth = 2
        Palette.projectFrame.setStroke()
        path.stroke()
    }

    // MARK: - Window management

    /// Add a panel. Pass an explicit `frame` to restore a saved position/size; otherwise the
    /// panel is cascaded near the visible center at the default size.
    @discardableResult
    func addWindow(title: String, frame: NSRect? = nil, size: NSSize = NSSize(width: 460, height: 320)) -> WindowView {
        let windowFrame = frame ?? NSRect(origin: spawnOrigin(for: size), size: size)
        let window = WindowView(frame: windowFrame)
        window.title = title
        window.onFocus = { [weak self] win in self?.bringToFront(win) }
        window.onGeometryChange = { [weak self] in
            self?.needsDisplay = true
            self?.onLayoutChange?()
        }
        addSubview(window)
        bringToFront(window)
        needsDisplay = true
        onLayoutChange?()
        return window
    }

    func bringToFront(_ window: WindowView) {
        addSubview(window, positioned: .above, relativeTo: nil)
        onLayoutChange?()
    }

    /// Cascade new windows around the center of the currently visible region.
    private func spawnOrigin(for size: NSSize) -> NSPoint {
        let region = visibleRect.isEmpty ? NSRect(origin: .zero, size: Self.canvasSize) : visibleRect
        let base = NSPoint(x: region.midX - size.width / 2, y: region.midY - size.height / 2)
        let origin = NSPoint(x: base.x + spawnOffset, y: base.y + spawnOffset)
        spawnOffset += 30
        if spawnOffset > 150 { spawnOffset = 0 }
        return origin
    }
}
