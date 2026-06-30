import AppKit
import QuartzCore

/// The single large document view that hosts every project's window panels. Flipped so the
/// origin is top-left. Draws a dotted grid and ONE rounded "folder" per project (a body wrapping
/// that project's windows) with a zoom-invariant white name label above its top-left corner. Only
/// the visible `dirtyRect` is rendered.
final class CanvasView: NSView {
    static let canvasSize = SharedCanvasLayout.canvasSize

    private let framePadding = SharedCanvasLayout.framePadding
    private static let bodyRadius: CGFloat = 30
    /// Project name label — a constant on-screen size regardless of zoom (the font size and the gap
    /// above the corner are divided by the scroll view's magnification).
    private static let nameBaseSize: CGFloat = 14
    private static let nameGap: CGFloat = 8

    /// Projects to draw are read live from the model.
    weak var model: AppModel?

    /// Current snapping grid in points (0 = off) — read by item panels during move/resize.
    var snapGrid: CGFloat { model?.snapGrid ?? 0 }

    /// Snap a coordinate to the snapping grid (no-op when snapping is off).
    static func snap(_ value: CGFloat, to grid: CGFloat) -> CGFloat {
        grid > 0 ? (value / grid).rounded() * grid : value
    }

    /// The project drawn with a white selection outline (nil => none / an item is selected).
    var selectedProjectID: UUID? {
        didSet { guard selectedProjectID != oldValue else { return }; needsDisplay = true }
    }

    /// While dragging a window in a tiled project, the slot it would drop into (an accent placeholder).
    var tileDropHighlight: NSRect? {
        didSet { guard tileDropHighlight != oldValue else { return }; needsDisplay = true }
    }

    /// Fired when panels are added/closed/moved/resized/raised — drives autosave.
    var onLayoutChange: (() -> Void)?
    /// A folder/tab was clicked: select that project.
    var onSelectProjectFolder: ((UUID) -> Void)?
    /// Empty canvas was clicked: clear selection.
    var onClearSelection: (() -> Void)?
    /// Right-clicked empty canvas: create a new project near this canvas point.
    var onCreateProject: ((NSPoint) -> Void)?
    /// Right-clicked a project's empty folder space: create an item of this kind at this point.
    var onCreateItem: ((UUID, WorkItem.Kind, NSPoint) -> Void)?

    // Project-drag: grab a project (its folder body or name) to move the whole thing around.
    private weak var draggingProject: Project?
    private var dragStartMouse: NSPoint = .zero
    private var dragStartAnchor: NSPoint = .zero
    private var dragWindowOrigins: [(window: WindowView, origin: NSPoint)] = []

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    // Accept first responder so focus can rest on the canvas (e.g. after a delete) while keeping the
    // split-view controller in the responder chain — so Edit-menu Undo/Redo still reach it.
    override var acceptsFirstResponder: Bool { true }

    /// A cursor forced over the whole canvas while a tool is armed (e.g. crosshair for line drawing).
    var toolCursor: NSCursor? {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if let toolCursor { addCursorRect(visibleRect, cursor: toolCursor) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: .zero, size: CanvasView.canvasSize))
        wantsLayer = true
        layer?.drawsAsynchronously = true   // folder-card vectors rasterize off the main thread
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.drawsAsynchronously = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        Palette.canvas.setFill()
        dirtyRect.fill()

        guard let model else { return }
        var selected: Project?
        for project in model.projects {
            if project.id == selectedProjectID { selected = project; continue }
            if folderBounds(for: project).intersects(dirtyRect) {
                drawFolder(for: project, selected: false)
            }
        }
        if let selected {   // draw the selected folder last so its outline sits on top
            drawFolder(for: selected, selected: true)
        }
        if let slot = tileDropHighlight {   // placeholder gap for a live tiling drag
            let path = NSBezierPath(roundedRect: slot, xRadius: 12, yRadius: 12)
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
            path.lineWidth = 2
            path.stroke()
        }
        onDidDraw?()   // canvas content changed → the titles overlay repositions its labels
    }

    /// Fired at the end of every repaint (folder added/removed/moved/renamed) so the screen-space
    /// project-title overlay can re-sync.
    var onDidDraw: (() -> Void)?

    private func drawFolder(for project: Project, selected: Bool) {
        let body = folderBody(for: project)
        let fill = Palette.tinted(Palette.projectFill, with: project.color)
        let stroke = Palette.tinted(selected ? Palette.projectStrokeSelected : Palette.projectStroke,
                                    with: project.color)
        let shape = NSBezierPath(roundedRect: body, xRadius: Self.bodyRadius, yRadius: Self.bodyRadius)
        fill.setFill()
        shape.fill()
        stroke.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        // The project name is drawn by the screen-space ProjectTitlesView overlay (so it never scales
        // with zoom), not here. `nameLayout` still defines its hit rect for click-to-select.
    }

    /// Canvas-space top-left of the folder body — where the (screen-space) name label is pinned.
    func folderTopLeft(for project: Project) -> NSPoint {
        let body = folderBody(for: project)
        return NSPoint(x: body.minX, y: body.minY)
    }

    /// The name label's hit rect (canvas coords) + attributes — zoom-corrected so it matches the
    /// constant-size overlay label's on-screen footprint.
    private func nameLayout(for project: Project, body: NSRect? = nil)
        -> (point: NSPoint, rect: NSRect, attrs: [NSAttributedString.Key: Any]) {
        let mag = enclosingScrollView?.magnification ?? 1
        let body = body ?? folderBody(for: project)
        let font = NSFont.systemFont(ofSize: Self.nameBaseSize / mag, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = project.name.size(withAttributes: attrs)
        let gap = Self.nameGap / mag
        let point = NSPoint(x: body.minX, y: body.minY - gap - size.height)   // just above the corner
        // Pad the hit rect generously (the rendered NSTextField is a touch taller/wider than the bare
        // string) so clicking anywhere on the visible title — down to the corner — selects the project.
        let pad = 8 / mag
        let rect = NSRect(x: point.x - pad, y: point.y - pad,
                          width: max(size.width, 24 / mag) + pad * 2,
                          height: size.height + gap + pad)
        return (point, rect, attrs)
    }

    // MARK: - Per-project geometry

    /// The project's content region: the union of its window frames, or a default box at its
    /// anchor while it has no windows.
    private func contentRect(for project: Project) -> NSRect {
        let frames = project.items.compactMap { $0.window?.frame }
        if let first = frames.first {
            return frames.dropFirst().reduce(first) { $0.union($1) }
        }
        return NSRect(origin: project.anchor, size: SharedCanvasLayout.defaultEmptyContent)
    }

    /// The rounded folder body: the content region padded out on all sides.
    private func folderBody(for project: Project) -> NSRect {
        contentRect(for: project).insetBy(dx: -framePadding, dy: -framePadding)
    }

    private func folderPath(for project: Project) -> NSBezierPath {
        NSBezierPath(roundedRect: folderBody(for: project), xRadius: Self.bodyRadius, yRadius: Self.bodyRadius)
    }

    /// Bounding box of the folder (body + the name label above it) — for dirtyRect culling,
    /// hit-test tie-breaks, and pan-to-project.
    func folderBounds(for project: Project) -> NSRect {
        let body = folderBody(for: project)
        return body.union(nameLayout(for: project, body: body).rect)
    }

    // MARK: - Click handling (selection + rename)

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let model else { super.mouseDown(with: event); return }

        // Front-to-back; if folders overlap, prefer the smallest (innermost) one. The name label
        // sits just outside the body, so it counts as a hit too.
        let hit = model.projects
            .filter { folderPath(for: $0).contains(point) || nameLayout(for: $0).rect.contains(point) }
            .min { area(folderBounds(for: $0)) < area(folderBounds(for: $1)) }

        if let project = hit {
            onSelectProjectFolder?(project.id)   // shows the project options bar
            beginProjectDrag(project, at: point) // drag empty folder space / the name to move it
        } else {
            onClearSelection?()
        }
        super.mouseDown(with: event)
    }

    // MARK: - Project drag (move a whole project)

    private func beginProjectDrag(_ project: Project, at point: NSPoint) {
        draggingProject = project
        dragStartMouse = point
        dragStartAnchor = project.anchor
        dragWindowOrigins = project.items.compactMap { item in
            item.window.map { (window: $0, origin: $0.frame.origin) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let project = draggingProject else { super.mouseDragged(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        // Snap the move offset so the whole project shifts in grid steps (preserving its internal layout).
        let grid = snapGrid
        let dx = Self.snap(point.x - dragStartMouse.x, to: grid)
        let dy = Self.snap(point.y - dragStartMouse.y, to: grid)
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // panels follow the cursor without easing behind it
        if dragWindowOrigins.isEmpty {
            project.anchor = NSPoint(x: dragStartAnchor.x + dx, y: dragStartAnchor.y + dy)
        } else {
            for entry in dragWindowOrigins {
                entry.window.setFrameOrigin(NSPoint(x: entry.origin.x + dx, y: entry.origin.y + dy))
            }
        }
        CATransaction.commit()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if draggingProject != nil {
            draggingProject = nil
            dragWindowOrigins = []
            onLayoutChange?()   // persist the moved positions
        }
        super.mouseUp(with: event)
    }

    private func area(_ r: NSRect) -> CGFloat { r.width * r.height }

    // MARK: - Context menu (right-click on empty canvas / empty folder space)
    //
    // A right-click over an item's window panel bubbles up the responder chain to this view (a
    // panel has no menu of its own), so we explicitly bail out when the point lands on a panel — a
    // window is not "blank space". Otherwise we split on whether the point is inside a project's
    // folder: empty folder space offers the item kinds (added to that project, spawned at the
    // click); empty canvas offers "New Project".

    private var contextMenuPoint: NSPoint = .zero
    private var contextMenuProjectID: UUID?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model else { return nil }
        let point = convert(event.locationInWindow, from: nil)

        // A click bubbled up from a window panel isn't blank space — suppress the canvas menu.
        if subviews.contains(where: { ($0 as? WindowView).map { !$0.isHidden && $0.frame.contains(point) } ?? false }) {
            return nil
        }
        contextMenuPoint = point

        // Same hit rule as a click: front-to-back, preferring the innermost folder on overlap.
        let hit = model.projects
            .filter { folderPath(for: $0).contains(point) }
            .min { area(folderBounds(for: $0)) < area(folderBounds(for: $1)) }

        let menu = NSMenu()
        if let project = hit {
            contextMenuProjectID = project.id
            onSelectProjectFolder?(project.id)   // outline the target folder while the menu is open
            menu.addItem(withTitle: "New Terminal", action: #selector(contextNewTerminal), keyEquivalent: "")
            menu.addItem(withTitle: "New Document", action: #selector(contextNewDocument), keyEquivalent: "")
            menu.addItem(withTitle: "New Code Editor", action: #selector(contextNewCodeEditor), keyEquivalent: "")
            menu.addItem(withTitle: "New Browser", action: #selector(contextNewBrowser), keyEquivalent: "")
            menu.addItem(withTitle: "New Git Observer", action: #selector(contextNewGitObserver), keyEquivalent: "")
            menu.addItem(withTitle: "New Git Graph", action: #selector(contextNewGitGraph), keyEquivalent: "")
            menu.addItem(withTitle: "New Project Velocity", action: #selector(contextNewProjectVelocity), keyEquivalent: "")
            menu.addItem(withTitle: "New Diff", action: #selector(contextNewDiff), keyEquivalent: "")
            menu.addItem(withTitle: "New Claude", action: #selector(contextNewClaude), keyEquivalent: "")
            menu.addItem(withTitle: "New Sticky Pad", action: #selector(contextNewSticky), keyEquivalent: "")
            menu.addItem(withTitle: "New Free Text", action: #selector(contextNewFreeText), keyEquivalent: "")
            menu.addItem(withTitle: "New Line", action: #selector(contextNewLine), keyEquivalent: "")
            menu.addItem(.separator())
            let tileItem = NSMenuItem(title: "Tile Windows", action: nil, keyEquivalent: "")
            let tileMenu = NSMenu()
            func addTile(_ title: String, _ layout: TileLayout) {
                let it = tileMenu.addItem(withTitle: title, action: #selector(contextTileLayout(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = LayoutBox(layout)
            }
            addTile("Uniform Grid", .gridAuto)
            addTile("Grid 2×2", .grid(cols: 2))
            addTile("Grid 3×3", .grid(cols: 3))
            addTile("Columns", .columns)
            tileMenu.addItem(.separator())
            addTile("Pack (keep sizes)", .pack)
            tileItem.submenu = tileMenu
            menu.addItem(tileItem)
        } else {
            contextMenuProjectID = nil
            menu.addItem(withTitle: "New Project", action: #selector(contextNewProject), keyEquivalent: "")
        }
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func contextTileLayout(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? LayoutBox,
              let id = contextMenuProjectID,
              let project = model?.projects.first(where: { $0.id == id }) else { return }
        model?.tileProject(project, layout: box.layout)
    }

    @objc private func contextNewProject() { onCreateProject?(contextMenuPoint) }
    @objc private func contextNewTerminal() { createContextItem(.terminal) }
    @objc private func contextNewDocument() { createContextItem(.document) }
    @objc private func contextNewCodeEditor() { createContextItem(.codeEditor) }
    @objc private func contextNewBrowser() { createContextItem(.browser) }
    @objc private func contextNewGitObserver() { createContextItem(.gitObserver) }
    @objc private func contextNewGitGraph() { createContextItem(.gitGraph) }
    @objc private func contextNewProjectVelocity() { createContextItem(.projectVelocity) }
    @objc private func contextNewDiff() { createContextItem(.diff) }
    @objc private func contextNewClaude() { createContextItem(.assistant) }
    @objc private func contextNewSticky() { createContextItem(.sticky) }
    @objc private func contextNewFreeText() { createContextItem(.freeText) }
    @objc private func contextNewLine() { model?.onRequestLineDrawing?() }

    private func createContextItem(_ kind: WorkItem.Kind) {
        guard let id = contextMenuProjectID else { return }
        onCreateItem?(id, kind, contextMenuPoint)
    }

    // MARK: - Window management

    /// Add a panel at an explicit frame (the model computes it: project-local spawn for new items,
    /// the saved frame for restored ones). Falls back to the visible center if no frame is given.
    @discardableResult
    func addWindow(title: String, frame: NSRect? = nil, size: NSSize = SharedCanvasLayout.defaultPanelSize) -> WindowView {
        let region = visibleRect.isEmpty ? NSRect(origin: .zero, size: Self.canvasSize) : visibleRect
        let fallback = NSRect(x: region.midX - size.width / 2, y: region.midY - size.height / 2,
                              width: size.width, height: size.height)
        let window = WindowView(frame: frame ?? fallback)
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

    /// An anchor in empty canvas space near the current viewport, for placing a new project's
    /// folder so it doesn't overlap existing ones.
    func freeAnchorNearViewport() -> NSPoint {
        let region = visibleRect.isEmpty ? NSRect(origin: .zero, size: Self.canvasSize) : visibleRect
        let size = SharedCanvasLayout.defaultEmptyContent
        let start = NSPoint(x: region.midX - size.width / 2, y: region.midY - size.height / 2)
        let existing = (model?.projects ?? []).map { folderBounds(for: $0) }
        func free(_ anchor: NSPoint) -> Bool {
            let r = NSRect(origin: anchor, size: size).insetBy(dx: -framePadding, dy: -framePadding)
            return !existing.contains { $0.intersects(r) }
        }
        if free(start) { return start }
        let step = size.width + 160
        for ring in 1...12 {
            for dx in -ring...ring {
                for dy in -ring...ring {
                    guard abs(dx) == ring || abs(dy) == ring else { continue }
                    let anchor = NSPoint(x: start.x + CGFloat(dx) * step, y: start.y + CGFloat(dy) * step)
                    if free(anchor) { return anchor }
                }
            }
        }
        return start
    }
}
