import AppKit
import QuartzCore

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

    // Plain scroll over the canvas does nothing — moving the canvas requires ⌥. The app's scroll
    // monitor routes ⌥+scroll to `pan` and ⌘+scroll to `zoom` (deciding from the gesture's initial
    // modifiers), so this view never pans on a bare scroll.
    override func scrollWheel(with event: NSEvent) {}

    /// ⌥ + scroll: pan the canvas.
    func pan(with event: NSEvent) {
        super.scrollWheel(with: event)
    }

    /// Called once a pinch/⌘-scroll zoom settles into a real magnification (so the canvas can
    /// re-rasterize zoom-invariant content like project titles and reposition overlays).
    var onLiveZoomCommitted: (() -> Void)?
    /// A live zoom began at `anchor` (document coords) — capture base positions for screen-space overlays.
    var onLiveZoomBegan: ((NSPoint) -> Void)?
    /// The live zoom's scale relative to its start — drive screen-space overlay tracking each frame.
    var onLiveZoomChanged: ((CGFloat) -> Void)?
    private var zoomSettleTimer: Timer?
    private var liveZoom = false
    private var liveZoomBaseMag: CGFloat = 1
    private var liveZoomTargetMag: CGFloat = 1
    private var liveZoomAnchor: NSPoint = .zero   // document coordinates

    /// ⌘ + scroll: zoom centered on the cursor. During the gesture we don't change the scroll
    /// view's magnification (which would re-render every panel — slow, and what caused the
    /// flicker). Instead we apply a pure layer scale transform to the canvas, which the GPU
    /// composites from the already-rendered content (including the WKWebView) without any
    /// re-rasterization. When zooming settles we commit a single real `setMagnification` at the
    /// same scale/anchor and drop the transform — visually identical, so there's no flicker.
    func zoom(with event: NSEvent) {
        guard let document = documentView else { return }
        if !liveZoom { beginLiveZoom(anchor: document.convert(event.locationInWindow, from: nil)) }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        updateLiveZoom(factor: 1 + (delta * 0.0025))   // gentle zoom — trackpad deltas are large
        zoomSettleTimer?.invalidate()
        zoomSettleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            self?.commitLiveZoom()
        }
    }

    /// Pinch-to-zoom: the same live transform, driven by the gesture phases.
    override func magnify(with event: NSEvent) {
        guard let document = documentView else { super.magnify(with: event); return }
        switch event.phase {
        case .began:
            beginLiveZoom(anchor: document.convert(event.locationInWindow, from: nil))
        case .changed:
            updateLiveZoom(factor: 1 + event.magnification)
        case .ended, .cancelled:
            commitLiveZoom()
        default:
            break
        }
    }

    private func beginLiveZoom(anchor: NSPoint) {
        liveZoom = true
        liveZoomBaseMag = magnification
        liveZoomTargetMag = magnification
        liveZoomAnchor = anchor
        onLiveZoomBegan?(anchor)
    }

    private func updateLiveZoom(factor: CGFloat) {
        guard liveZoom, let layer = documentView?.layer else { return }
        liveZoomTargetMag = clamped(liveZoomTargetMag * factor)
        let scale = liveZoomTargetMag / liveZoomBaseMag
        onLiveZoomChanged?(scale)
        // Scale about the anchor regardless of the layer's anchorPoint: q' = pivot + L(q - pivot),
        // so to keep `anchor` fixed we translate by (anchor - pivot)(1 - scale) before scaling.
        let bounds = layer.bounds.size
        let pivot = CGPoint(x: layer.anchorPoint.x * bounds.width, y: layer.anchorPoint.y * bounds.height)
        let dx = (liveZoomAnchor.x - pivot.x) * (1 - scale)
        let dy = (liveZoomAnchor.y - pivot.y) * (1 - scale)
        var transform = CATransform3DMakeTranslation(dx, dy, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = transform
        CATransaction.commit()
    }

    private func commitLiveZoom() {
        guard liveZoom, let document = documentView else { return }
        liveZoom = false
        zoomSettleTimer?.invalidate()
        zoomSettleTimer = nil
        let finalMag = liveZoomTargetMag
        let anchor = liveZoomAnchor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        document.layer?.transform = CATransform3DIdentity   // drop the visual transform…
        setMagnification(finalMag, centeredAt: anchor)       // …and make the same scale real
        CATransaction.commit()
        document.needsDisplay = true                         // repaint titles at the new scale now
        onLiveZoomCommitted?()
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
