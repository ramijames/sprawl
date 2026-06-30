import AppKit

/// A transparent screen-space overlay that draws each project's name as a constant-size white label
/// pinned just above the project's top-left corner. Because it lives *above* the zoomable scroll
/// view (not inside the magnified canvas), the labels never resize with zoom — they only reposition.
/// Mouse events pass straight through to the canvas.
final class ProjectTitlesView: NSView {
    /// Map a canvas-space point into this overlay's coordinates (accounts for pan + zoom).
    var convertFromCanvas: ((NSPoint) -> NSPoint)?
    /// Canvas-space top-left corner of a project's folder body (nil if the project is gone).
    var cornerProvider: ((UUID) -> NSPoint?)?

    private static let font = NSFont.systemFont(ofSize: 14, weight: .medium)
    private static let gap: CGFloat = 8   // constant on-screen gap above the corner

    private var labels: [UUID: NSTextField] = [:]
    private var liveAnchor: CGPoint = .zero
    private var liveBaseCorner: [UUID: CGPoint] = [:]

    override var isFlipped: Bool { true }                       // top-left origin, like the canvas
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // transparent to the mouse

    /// Reconcile the label set with `entries` (add/remove/rename) and reposition everything.
    func sync(_ entries: [(id: UUID, name: String)]) {
        let live = Set(entries.map { $0.id })
        for (id, label) in labels where !live.contains(id) {
            label.removeFromSuperview()
            labels[id] = nil
        }
        for entry in entries {
            let label = labels[entry.id] ?? makeLabel(for: entry.id)
            if label.stringValue != entry.name { label.stringValue = entry.name }
        }
        reposition()
    }

    /// Place each label just above its project's corner at its natural (constant) size.
    func reposition() {
        guard let convert = convertFromCanvas, let corner = cornerProvider else { return }
        for (id, label) in labels {
            guard let c = corner(id) else { label.isHidden = true; continue }
            label.isHidden = false
            place(label, atCorner: convert(c))
        }
    }

    /// Begin a live zoom: capture each corner's current on-screen position + the zoom anchor, so the
    /// labels can track the content (without resizing) as the gesture scales about the anchor.
    func beginLiveZoom(anchorCanvas: NSPoint) {
        guard let convert = convertFromCanvas, let corner = cornerProvider else { return }
        liveAnchor = convert(anchorCanvas)
        liveBaseCorner = [:]
        for (id, _) in labels { if let c = corner(id) { liveBaseCorner[id] = convert(c) } }
    }

    /// During a live zoom: corners scale about the anchor by `scale`; labels follow but keep their size.
    func updateLiveZoom(scale: CGFloat) {
        for (id, label) in labels {
            guard let base = liveBaseCorner[id] else { continue }
            let c = CGPoint(x: liveAnchor.x + scale * (base.x - liveAnchor.x),
                            y: liveAnchor.y + scale * (base.y - liveAnchor.y))
            place(label, atCorner: c)
        }
    }

    private func place(_ label: NSTextField, atCorner c: CGPoint) {
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: c.x, y: c.y - Self.gap - label.frame.height))  // just above the corner
    }

    private func makeLabel(for id: UUID) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = Self.font
        label.textColor = .white
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
        addSubview(label)
        labels[id] = label
        return label
    }
}
