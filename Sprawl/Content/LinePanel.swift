import AppKit

/// A connector annotation: a two-point line (start, end) auto-routed with right-angle elbows and
/// rounded corners — never a bezier. Hosted in a chrome-less, transparent `WindowView` whose frame
/// tracks the route's padded bounding box. Grab the stroke to move the whole connector; when
/// selected, drag the endpoint circles or the segment handles (snap-aware) to reshape it. Color,
/// thickness, and arrowheads come from the floating options bar.
final class LinePanel: NSObject {
    typealias Snapshot = LineContentView.Snapshot

    private let view = LineContentView()
    private weak var hostWindow: WindowView?

    static var pastels: [NSColor] { Palette.pastels }

    var colorIndex: Int { view.colorIndex }
    var thickness: CGFloat { view.thickness }
    var hasArrowStart: Bool { view.arrowStart }
    var hasArrowEnd: Bool { view.arrowEnd }
    var startPoint: CGPoint { view.start }
    var endPoint: CGPoint { view.end }
    var bend: CGFloat { view.bend }
    var currentSnapshot: Snapshot { view.snapshot() }

    var onChange: (() -> Void)? {
        get { view.onChange } set { view.onChange = newValue }
    }
    var onGeometryEdited: ((Snapshot, Snapshot) -> Void)? {
        get { view.onGeometryEdited } set { view.onGeometryEdited = newValue }
    }

    init(colorIndex: Int, thickness: CGFloat, arrowStart: Bool, arrowEnd: Bool,
         start: CGPoint?, end: CGPoint?, bend: CGFloat) {
        super.init()
        let count = LinePanel.pastels.count
        view.colorIndex = ((colorIndex % count) + count) % count
        view.thickness = max(1, thickness)
        view.arrowStart = arrowStart
        view.arrowEnd = arrowEnd
        view.bend = min(max(bend, 0), 1)
        if let start { view.start = start }
        if let end { view.end = end }
        view.pendingPlaced = (start != nil && end != nil)
    }

    func attach(to window: WindowView) {
        hostWindow = window
        view.host = window
        window.makeChromeless(resizable: false, cornerRadius: 4)
        window.suppressBackdrop = true      // the connector draws its own selection (handles)
        window.setContent(view)
        // AppKit passes hitTest points in WindowView-local space (already converted in
        // WindowView.hitTest); LineContentView fills the window at origin (0,0) with the same
        // non-flipped axes, so the value is used directly.
        window.bodyHitTest = { [weak self] p in self?.view.isLive(at: p) ?? false }
        window.onSelectionChange = { [weak self] _ in self?.view.needsDisplay = true }
        if view.pendingPlaced { view.reframe(pinEnd: false) }   // normalize the frame to the route
    }

    func focus() {}

    func setColor(_ index: Int) { view.setColor(index) }
    func setThickness(_ t: CGFloat) { view.setThickness(t) }
    func setArrowStart(_ on: Bool) { view.setArrowStart(on) }
    func setArrowEnd(_ on: Bool) { view.setArrowEnd(on) }

    // Creation (driven by the click-drag controller).
    func startPath(atCanvas p: CGPoint) { view.startPath(atCanvas: p) }
    func setEnd(towardCanvas p: CGPoint) { view.setEnd(towardCanvas: p) }
    /// Give a click-only (zero-length) connector a sensible default length.
    func extendToDefault() { view.extendToDefault() }
    /// True once the connector has a real start≠end (used to decide whether to keep it).
    var isPlaced: Bool { hypot(view.end.x - view.start.x, view.end.y - view.start.y) > 4 }

    func applyGeometry(_ snap: Snapshot) { view.applyGeometry(snap) }
}

/// Drawing + interaction surface for an orthogonal connector. Lives in window-local (non-flipped)
/// coordinates; `start`/`end` are stored relative to the host frame, which is kept equal to the
/// route's bounding box plus a uniform `pad`. The route is `start → end` as either H-V-H or V-H-V
/// (whichever axis dominates) with the middle segment at fractional position `bend`, or a single
/// straight segment when the ends are axis-aligned.
final class LineContentView: NSView {
    struct Snapshot: Equatable { var frame: CGRect; var start: CGPoint; var end: CGPoint; var bend: CGFloat }

    var colorIndex = 0
    var thickness: CGFloat = 2
    var arrowStart = false
    var arrowEnd = false
    var start = CGPoint(x: 16, y: 16)
    var end = CGPoint(x: 196, y: 116)
    var bend: CGFloat = 0.5
    var pendingPlaced = false
    weak var host: WindowView?

    var onChange: (() -> Void)?
    var onGeometryEdited: ((Snapshot, Snapshot) -> Void)?

    private enum Handle: Equatable { case start, end, segment(Int) }
    private enum SegTouch { case start, end, interior }
    private var activeHandle: Handle?
    private var segTouch: SegTouch = .interior   // classification of a grabbed segment (captured on mouseDown)
    private var segHorizontal = false
    private var dragBefore: Snapshot?
    private var isReframing = false
    private let handleRadius: CGFloat = 6
    private let cornerRadius: CGFloat = 12

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var color: NSColor { LinePanel.pastels[colorIndex % LinePanel.pastels.count] }
    private var accent: NSColor { .controlAccentColor }
    private var arrowSize: CGFloat { 6 + thickness * 2.5 }
    private func currentPad() -> CGFloat { ceil(max(handleRadius + 5, 1.12 * arrowSize + thickness / 2 + 6)) }

    func snapshot() -> Snapshot { Snapshot(frame: host?.frame ?? .zero, start: start, end: end, bend: bend) }

    // MARK: - Routing

    /// Corner points of the orthogonal route, in local coordinates (2 points = straight, 3 = L,
    /// 4 = elbow). When the middle segment is dragged within `collapseThreshold` of an endpoint, the
    /// tiny stub is removed (the route simplifies to an L).
    private func routePoints() -> [CGPoint] {
        let dx = end.x - start.x, dy = end.y - start.y
        if abs(dx) < 1 || abs(dy) < 1 { return [start, end] }   // axis-aligned → straight
        let thr = cornerRadius + 2
        if abs(dx) >= abs(dy) {                                  // horizontal-dominant → H-V-H
            var mx = start.x + dx * bend
            if abs(mx - start.x) < thr { mx = start.x }          // collapse the start-side stub → L
            else if abs(mx - end.x) < thr { mx = end.x }         // collapse the end-side stub → L
            return dedupe([start, CGPoint(x: mx, y: start.y), CGPoint(x: mx, y: end.y), end])
        } else {                                                 // vertical-dominant → V-H-V
            var my = start.y + dy * bend
            if abs(my - start.y) < thr { my = start.y }
            else if abs(my - end.y) < thr { my = end.y }
            return dedupe([start, CGPoint(x: start.x, y: my), CGPoint(x: end.x, y: my), end])
        }
    }

    /// Drop points coincident with their predecessor (collapses zero-length segments to an L).
    private func dedupe(_ pts: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for p in pts where out.last.map({ hypot(p.x - $0.x, p.y - $0.y) > 0.5 }) ?? true { out.append(p) }
        return out
    }

    private func makePath() -> NSBezierPath {
        let pts = routePoints()
        let path = NSBezierPath()
        guard pts.count >= 2 else { return path }
        path.move(to: pts[0])
        if pts.count == 2 { path.line(to: pts[1]); return path }
        for i in 1..<pts.count - 1 {
            let p0 = pts[i - 1], c = pts[i], p1 = pts[i + 1]
            let r = min(cornerRadius, dist(p0, c) / 2, dist(c, p1) / 2)
            path.line(to: towards(c, p0, r))                       // straight up to the corner
            path.curve(to: towards(c, p1, r), controlPoint1: c, controlPoint2: c)   // round it
        }
        path.line(to: pts[pts.count - 1])
        return path
    }

    /// A point `d` away from `from` heading toward `to`.
    private func towards(_ from: CGPoint, _ to: CGPoint, _ d: CGFloat) -> CGPoint {
        let dx = to.x - from.x, dy = to.y - from.y
        let len = hypot(dx, dy)
        guard len > 0.001 else { return from }
        return CGPoint(x: from.x + dx / len * d, y: from.y + dy / len * d)
    }
    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private func routeBounds() -> CGRect {
        let pts = routePoints()
        guard let first = pts.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Resize the host frame to hug the route + padding, keeping the pinned endpoint fixed in canvas
    /// space so the other end / a dragged segment moves while the rest stays put.
    func reframe(pinEnd: Bool) {
        guard !isReframing, let host, let canvas = host.superview else { return }
        isReframing = true; defer { isReframing = false }
        let pinned = pinEnd ? end : start
        let anchorCanvas = canvas.convert(pinned, from: self)
        let pad = currentPad()
        let bb = routeBounds()
        let delta = CGPoint(x: pad - bb.minX, y: pad - bb.minY)
        start = CGPoint(x: start.x + delta.x, y: start.y + delta.y)
        end = CGPoint(x: end.x + delta.x, y: end.y + delta.y)
        var f = host.frame
        f.size = CGSize(width: bb.width + 2 * pad, height: bb.height + 2 * pad)
        host.frame = f
        host.layoutSubtreeIfNeeded()
        let cur = canvas.convert(pinEnd ? end : start, from: self)
        let off = CGPoint(x: anchorCanvas.x - cur.x, y: anchorCanvas.y - cur.y)
        if abs(off.x) > 0.001 || abs(off.y) > 0.001 {
            host.setFrameOrigin(CGPoint(x: host.frame.minX + off.x, y: host.frame.minY + off.y))
        }
        needsDisplay = true
    }

    func applyGeometry(_ s: Snapshot) {
        start = s.start; end = s.end; bend = s.bend
        host?.frame = s.frame
        host?.layoutSubtreeIfNeeded()
        needsDisplay = true
        host?.onGeometryChange2?()
    }

    // MARK: - Creation

    func startPath(atCanvas p: CGPoint) {
        guard let host, let canvas = host.superview else { return }
        let sp = snapCanvas(p)
        let pad = currentPad()
        host.setFrameSize(CGSize(width: 2 * pad, height: 2 * pad))
        host.setFrameOrigin(CGPoint(x: sp.x - pad, y: sp.y - pad))
        host.layoutSubtreeIfNeeded()
        let local = convert(sp, from: canvas)
        start = local; end = local
        needsDisplay = true
    }

    func setEnd(towardCanvas p: CGPoint) {
        guard let host, let canvas = host.superview else { return }
        end = convert(snapCanvas(p), from: canvas)
        reframe(pinEnd: false)
        onChange?()
    }

    func extendToDefault() {
        end = CGPoint(x: start.x + 180, y: start.y + 120)
        reframe(pinEnd: false)
        needsDisplay = true; onChange?()
    }

    // MARK: - Options

    func setColor(_ index: Int) {
        let c = LinePanel.pastels.count
        colorIndex = ((index % c) + c) % c
        needsDisplay = true; onChange?()
    }
    func setThickness(_ t: CGFloat) {
        thickness = max(1, t)
        reframe(pinEnd: false)   // padding depends on thickness
        needsDisplay = true; onChange?()
    }
    func setArrowStart(_ on: Bool) { arrowStart = on; needsDisplay = true; onChange?() }
    func setArrowEnd(_ on: Bool) { arrowEnd = on; needsDisplay = true; onChange?() }

    // MARK: - Snapping

    private var snapGrid: CGFloat { (host?.superview as? CanvasView)?.snapGrid ?? 0 }
    private func snapValue(_ v: CGFloat) -> CGFloat { snapGrid > 0 ? CanvasView.snap(v, to: snapGrid) : v }
    private func snapCanvas(_ p: CGPoint) -> CGPoint { CGPoint(x: snapValue(p.x), y: snapValue(p.y)) }

    // MARK: - Hit testing

    func isLive(at p: CGPoint) -> Bool {
        if host?.isSelected == true, handle(at: p) != nil { return true }
        return distanceToRoute(p) <= max(8, thickness / 2 + 6)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard host?.isSelected == true else { return nil }
        return handle(at: convert(point, from: superview)) != nil ? self : nil
    }

    private func handle(at p: CGPoint) -> Handle? {
        if hypot(p.x - start.x, p.y - start.y) <= handleRadius + 5 { return .start }
        if hypot(p.x - end.x, p.y - end.y) <= handleRadius + 5 { return .end }
        let pts = routePoints()
        if pts.count >= 4 {   // segment handles only exist for elbow routes
            for i in 0..<pts.count - 1 {
                let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
                if hypot(p.x - mid.x, p.y - mid.y) <= 12 { return .segment(i) }
            }
        }
        return nil
    }

    private func distanceToRoute(_ p: CGPoint) -> CGFloat {
        let pts = routePoints()
        guard pts.count >= 2 else { return .greatestFiniteMagnitude }
        var best = CGFloat.greatestFiniteMagnitude
        for i in 0..<pts.count - 1 { best = min(best, distanceToSegment(p, pts[i], pts[i + 1])) }
        return best
    }

    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        if l2 < 0.0001 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: - Editing (endpoints + segments)

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        activeHandle = handle(at: p)
        // Classify a grabbed segment once, so a bend drag stays a bend drag even as the route
        // simplifies to an L mid-drag (which would otherwise change the segment's index meaning).
        if case .segment(let i) = activeHandle {
            let pts = routePoints()
            if i + 1 < pts.count {
                segHorizontal = abs(pts[i + 1].y - pts[i].y) < abs(pts[i + 1].x - pts[i].x)
                segTouch = (i == 0) ? .start : (i == pts.count - 2 ? .end : .interior)
            }
        }
        if activeHandle != nil { dragBefore = snapshot() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let h = activeHandle, let host, let canvas = host.superview else { return }
        let local = convert(snapCanvas(canvas.convert(event.locationInWindow, from: nil)), from: canvas)
        switch h {
        case .start: start = local; reframe(pinEnd: true)
        case .end: end = local; reframe(pinEnd: false)
        case .segment: dragSegment(toLocal: local)
        }
        host.onGeometryChange2?()
    }

    private func dragSegment(toLocal local: CGPoint) {
        let dx = end.x - start.x, dy = end.y - start.y
        switch segTouch {
        case .interior:   // the middle segment → set the bend (collapses to an L near the ends)
            if abs(dx) >= abs(dy), abs(dx) > 0.001 { bend = clamp01((local.x - start.x) / dx) }
            else if abs(dy) > 0.001 { bend = clamp01((local.y - start.y) / dy) }
            needsDisplay = true
        case .start:
            if segHorizontal { start.y = local.y } else { start.x = local.x }
            reframe(pinEnd: true)
        case .end:
            if segHorizontal { end.y = local.y } else { end.x = local.x }
            reframe(pinEnd: false)
        }
    }

    private func clamp01(_ b: CGFloat) -> CGFloat { min(max(b, 0), 1) }

    override func mouseUp(with event: NSEvent) {
        defer { activeHandle = nil; dragBefore = nil }
        guard activeHandle != nil, let before = dragBefore else { return }
        let after = snapshot()
        if after != before { onGeometryEdited?(before, after); onChange?() }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let pts = routePoints()
        guard pts.count >= 2 else { return }
        let path = makePath()
        path.lineWidth = thickness
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
        if arrowEnd, let dir = direction(at: pts.count - 1, pts: pts) { drawArrow(tip: end, toward: dir) }
        if arrowStart, let dir = direction(at: 0, pts: pts) { drawArrow(tip: start, toward: dir) }
        if host?.isSelected == true { drawSelection(pts) }
    }

    /// Outward direction of the route at an endpoint (along the adjacent segment).
    private func direction(at index: Int, pts: [CGPoint]) -> CGPoint? {
        guard pts.count >= 2 else { return nil }
        if index == 0 { return CGPoint(x: pts[0].x - pts[1].x, y: pts[0].y - pts[1].y) }
        let n = pts.count
        return CGPoint(x: pts[n - 1].x - pts[n - 2].x, y: pts[n - 1].y - pts[n - 2].y)
    }

    /// An open chevron arrowhead (two strokes meeting at the tip), matching the line's weight.
    private func drawArrow(tip: CGPoint, toward dir: CGPoint) {
        let len = hypot(dir.x, dir.y)
        guard len > 0.001 else { return }
        let u = CGPoint(x: dir.x / len, y: dir.y / len)
        let arm = arrowSize
        let angle: CGFloat = .pi / 6                 // 30° half-angle
        let ca = cos(angle), sa = sin(angle)
        let bx = -u.x, by = -u.y                     // backward along the shaft
        let left = CGPoint(x: tip.x + (bx * ca - by * sa) * arm, y: tip.y + (bx * sa + by * ca) * arm)
        let right = CGPoint(x: tip.x + (bx * ca + by * sa) * arm, y: tip.y + (-bx * sa + by * ca) * arm)
        let head = NSBezierPath()
        head.move(to: left); head.line(to: tip); head.line(to: right)
        head.lineWidth = thickness
        head.lineCapStyle = .round
        head.lineJoinStyle = .round
        color.setStroke(); head.stroke()
    }

    private func drawSelection(_ pts: [CGPoint]) {
        // Blue segment pills at the midpoint of each elbow segment.
        if pts.count >= 4 {
            for i in 0..<pts.count - 1 {
                let a = pts[i], b = pts[i + 1]
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let horizontal = abs(b.y - a.y) < abs(b.x - a.x)
                let w: CGFloat = horizontal ? 18 : 6, h: CGFloat = horizontal ? 6 : 18
                let pill = NSBezierPath(roundedRect: CGRect(x: mid.x - w / 2, y: mid.y - h / 2, width: w, height: h),
                                        xRadius: 3, yRadius: 3)
                accent.setFill(); pill.fill()
            }
        }
        // White-filled endpoint circles with a blue ring.
        for p in [start, end] {
            let r = handleRadius
            let circle = NSBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            NSColor.white.setFill(); circle.fill()
            accent.setStroke(); circle.lineWidth = 2; circle.stroke()
        }
    }
}
