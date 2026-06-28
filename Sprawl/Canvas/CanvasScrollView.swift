import AppKit

/// The pannable + zoomable surface. `NSScrollView` provides Core Animation-composited
/// pan and magnification for free; child views (terminals, editors) stay live while scaled.
final class CanvasScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        allowsMagnification = true
        minMagnification = 0.1
        maxMagnification = 4.0
        magnification = 1.0
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        usesPredominantAxisScrolling = false
        scrollerStyle = .overlay
        drawsBackground = true
        backgroundColor = Palette.canvas
    }

    // ⌘ + scroll wheel zooms, centered on the cursor.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let document = documentView else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        let factor = 1 + (delta * 0.01)
        let pointInDocument = document.convert(event.locationInWindow, from: nil)
        setMagnification(clamped(magnification * factor), centeredAt: pointInDocument)
    }

    func zoomIn() { setMagnification(clamped(magnification * 1.25), centeredAt: viewportCenterInDocument()) }
    func zoomOut() { setMagnification(clamped(magnification * 0.80), centeredAt: viewportCenterInDocument()) }
    func zoomReset() { setMagnification(1.0, centeredAt: viewportCenterInDocument()) }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(maxMagnification, max(minMagnification, value))
    }

    private func viewportCenterInDocument() -> NSPoint {
        let clipCenter = NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        return documentView?.convert(clipCenter, from: contentView) ?? clipCenter
    }
}
