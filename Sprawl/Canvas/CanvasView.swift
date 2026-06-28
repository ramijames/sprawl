import AppKit

/// The single large document view that hosts every project's window panels. Flipped so the
/// origin is top-left. Draws a dotted grid and ONE "folder" per project (a rounded body wrapping
/// that project's windows, plus a name tab). Only the visible `dirtyRect` is rendered.
final class CanvasView: NSView, NSTextFieldDelegate {
    static let canvasSize = SharedCanvasLayout.canvasSize

    private let gridSpacing: CGFloat = 40
    private let framePadding = SharedCanvasLayout.framePadding
    private let tabHeight = SharedCanvasLayout.tabHeight
    private let tabLabelInset: CGFloat = 22
    private static let tabFont = NSFont.systemFont(ofSize: 14, weight: .regular)

    /// Projects to draw are read live from the model.
    weak var model: AppModel?

    /// The project drawn with a white selection outline (nil => none / an item is selected).
    var selectedProjectID: UUID? {
        didSet { guard selectedProjectID != oldValue else { return }; needsDisplay = true }
    }

    /// Fired when panels are added/closed/moved/resized/raised — drives autosave.
    var onLayoutChange: (() -> Void)?
    /// A folder/tab was clicked: select that project.
    var onSelectProjectFolder: ((UUID) -> Void)?
    /// Empty canvas was clicked: clear selection.
    var onClearSelection: (() -> Void)?
    /// The user renamed a project by editing its tab.
    var onRenameProject: ((UUID, String) -> Void)?

    private weak var nameEditor: NSTextField?
    private weak var editingProject: Project?
    private var isEditingName = false

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

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        Palette.canvas.setFill()
        dirtyRect.fill()
        drawGrid(in: dirtyRect)

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

    private func drawFolder(for project: Project, selected: Bool) {
        let layout = folderLayout(for: project)
        let path = folderPath(body: layout.body, tabWidth: layout.tab.width)
        Palette.projectFill.setFill()
        path.fill()
        if selected {
            NSColor.white.setStroke()
            path.lineWidth = 3
            path.stroke()
        }
        // The live text field stands in for the drawn label while this project's tab is edited.
        if isEditingName, editingProject === project { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.tabFont, .foregroundColor: Palette.projectTabText]
        let labelSize = project.name.size(withAttributes: attrs)
        let origin = NSPoint(x: layout.tab.minX + tabLabelInset, y: layout.tab.minY + (tabHeight - labelSize.height) / 2)
        project.name.draw(at: origin, withAttributes: attrs)
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

    private func folderLayout(for project: Project) -> (body: NSRect, tab: NSRect) {
        let body = contentRect(for: project).insetBy(dx: -framePadding, dy: -framePadding)
        let bodyRadius: CGFloat = 20, valley: CGFloat = 16, tabRadius: CGFloat = 12
        let labelWidth = project.name.size(withAttributes: [.font: Self.tabFont]).width
        let desiredRight = body.minX + max(labelWidth + tabLabelInset * 2, 2 * tabRadius)
        let tabRight = min(desiredRight, body.maxX - bodyRadius - valley)
        let tab = NSRect(x: body.minX, y: body.minY - tabHeight,
                         width: max(2 * tabRadius, tabRight - body.minX), height: tabHeight)
        return (body, tab)
    }

    private func folderPath(for project: Project) -> NSBezierPath {
        let layout = folderLayout(for: project)
        return folderPath(body: layout.body, tabWidth: layout.tab.width)
    }

    /// Bounding box of the whole folder (body + tab) — for dirtyRect culling, hit-test tie-breaks,
    /// and pan-to-project framing.
    func folderBounds(for project: Project) -> NSRect {
        let layout = folderLayout(for: project)
        return layout.body.union(layout.tab)
    }

    // MARK: - Click handling (selection + rename)

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let model else { super.mouseDown(with: event); return }

        // Front-to-back; if folders overlap, prefer the smallest (innermost) one.
        let hit = model.projects
            .filter { folderPath(for: $0).contains(point) }
            .min { area(folderBounds(for: $0)) < area(folderBounds(for: $1)) }

        if let project = hit {
            onSelectProjectFolder?(project.id)
            if event.clickCount == 2, !isEditingName, folderLayout(for: project).tab.contains(point) {
                DispatchQueue.main.async { [weak self, weak project] in
                    guard let self, let project, !self.isEditingName else { return }
                    self.beginEditingName(for: project)
                }
            }
        } else {
            onClearSelection?()
        }
        super.mouseDown(with: event)
    }

    private func area(_ r: NSRect) -> CGFloat { r.width * r.height }

    // MARK: - Renaming via a borderless child panel (own field editor — see notes below)
    //
    // An NSTextField edits via the WINDOW's single shared field editor. Hosting it inside the
    // magnifying scroll view made makeFirstResponder trigger the scroll view's reconciliation,
    // which resigned the field editor synchronously. So we edit in a borderless child NSPanel
    // that owns its own field editor, positioned over the tab in screen coordinates.

    private final class NameEditorPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private weak var nameEditorPanel: NameEditorPanel?
    private var nameEditorObservers: [NSObjectProtocol] = []
    private var nameEditingReady = false

    private func beginEditingName(for project: Project) {
        guard !isEditingName, let parentWindow = window else { return }
        editingProject = project

        let mag = enclosingScrollView?.magnification ?? 1
        let box = folderLayout(for: project).tab.insetBy(dx: 8, dy: 8)
        let onScreen = parentWindow.convertToScreen(convert(box, to: nil))

        let panel = NameEditorPanel(contentRect: NSRect(origin: .zero, size: onScreen.size),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = parentWindow.level
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)

        let content = panel.contentView!
        content.wantsLayer = true
        content.layer?.backgroundColor = Palette.projectEditorFill.cgColor
        content.layer?.cornerRadius = min(8, onScreen.height * 0.35)
        content.layer?.masksToBounds = true

        let fontSize = max(9, Self.tabFont.pointSize * mag)
        let fieldHeight = ceil(fontSize * 1.4)
        let padX = max(6, 8 * mag)
        let field = NSTextField(frame: NSRect(
            x: padX, y: (onScreen.height - fieldHeight) / 2,
            width: max(20, onScreen.width - 2 * padX), height: fieldHeight))
        field.stringValue = project.name
        field.font = .systemFont(ofSize: fontSize, weight: .regular)
        field.textColor = Palette.panelTitleText
        field.drawsBackground = false
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.alignment = .center
        field.delegate = self
        content.addSubview(field)

        nameEditor = field
        nameEditorPanel = panel
        isEditingName = true
        nameEditingReady = false
        needsDisplay = true

        panel.initialFirstResponder = field
        parentWindow.addChildWindow(panel, ordered: .above)
        panel.setFrame(onScreen, display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertionPointColor = Palette.panelTitleText
            editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }

        installNameEditorObservers(scrollView: enclosingScrollView, window: parentWindow)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEditingName else { return }
            self.nameEditingReady = true
        }
    }

    private func installNameEditorObservers(scrollView: NSScrollView?, window: NSWindow) {
        let center = NotificationCenter.default
        let dismiss: (Notification) -> Void = { [weak self] _ in
            guard let self, self.nameEditingReady else { return }
            self.endNameEditing(commit: false)   // scroll/zoom/move away cancels the edit
        }
        if let clip = scrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            nameEditorObservers.append(center.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main, using: dismiss))
        }
        if let scrollView {
            nameEditorObservers.append(center.addObserver(
                forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main, using: dismiss))
        }
        nameEditorObservers.append(center.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main, using: dismiss))
        nameEditorObservers.append(center.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main, using: dismiss))
    }

    private func endNameEditing(commit: Bool) {
        guard isEditingName else { return }
        isEditingName = false
        nameEditingReady = false

        for observer in nameEditorObservers { NotificationCenter.default.removeObserver(observer) }
        nameEditorObservers.removeAll()

        let newName = nameEditor?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let project = editingProject

        if let panel = nameEditorPanel {
            window?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        window?.makeKeyAndOrderFront(nil)

        nameEditor = nil
        nameEditorPanel = nil
        editingProject = nil
        needsDisplay = true

        if commit, let project, !newName.isEmpty, newName != project.name {
            onRenameProject?(project.id, newName)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if isEditingName { endNameEditing(commit: false) }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard nameEditingReady else { return }
        endNameEditing(commit: false)   // blur / Tab cancels — only Return commits
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            endNameEditing(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endNameEditing(commit: false)
            return true
        default:
            return false
        }
    }

    // MARK: - Folder outline geometry

    /// A rounded body with a top-left tab that flares into the body top edge via a concave fillet.
    private func folderPath(body: NSRect, tabWidth: CGFloat) -> NSBezierPath {
        let bodyRadius: CGFloat = 20
        let tabRadius: CGFloat = 12
        let valley: CGFloat = 16

        let L = body.minX, R = body.maxX, T = body.minY, B = body.maxY
        let tabTop = T - tabHeight
        let tabRight = min(L + max(tabWidth, 2 * tabRadius), R - bodyRadius - valley)

        let path = NSBezierPath()
        path.move(to: NSPoint(x: L + tabRadius, y: tabTop))
        path.line(to: NSPoint(x: tabRight - tabRadius, y: tabTop))
        arcCorner(path, corner: NSPoint(x: tabRight, y: tabTop), to: NSPoint(x: tabRight, y: tabTop + tabRadius))
        path.line(to: NSPoint(x: tabRight, y: T - valley))
        path.curve(to: NSPoint(x: tabRight + valley, y: T),
                   controlPoint1: NSPoint(x: tabRight, y: T - valley / 3),
                   controlPoint2: NSPoint(x: tabRight + valley / 3, y: T))
        path.line(to: NSPoint(x: R - bodyRadius, y: T))
        arcCorner(path, corner: NSPoint(x: R, y: T), to: NSPoint(x: R, y: T + bodyRadius))
        path.line(to: NSPoint(x: R, y: B - bodyRadius))
        arcCorner(path, corner: NSPoint(x: R, y: B), to: NSPoint(x: R - bodyRadius, y: B))
        path.line(to: NSPoint(x: L + bodyRadius, y: B))
        arcCorner(path, corner: NSPoint(x: L, y: B), to: NSPoint(x: L, y: B - bodyRadius))
        path.line(to: NSPoint(x: L, y: tabTop + tabRadius))
        arcCorner(path, corner: NSPoint(x: L, y: tabTop), to: NSPoint(x: L + tabRadius, y: tabTop))
        path.close()
        return path
    }

    private func arcCorner(_ path: NSBezierPath, corner: NSPoint, to end: NSPoint) {
        let k: CGFloat = 0.5523
        let start = path.currentPoint
        let cp1 = NSPoint(x: start.x + (corner.x - start.x) * k, y: start.y + (corner.y - start.y) * k)
        let cp2 = NSPoint(x: end.x + (corner.x - end.x) * k, y: end.y + (corner.y - end.y) * k)
        path.curve(to: end, controlPoint1: cp1, controlPoint2: cp2)
    }

    // MARK: - Window management

    /// Add a panel at an explicit frame (the model computes it: project-local spawn for new items,
    /// the saved frame for restored ones). Falls back to the visible center if no frame is given.
    @discardableResult
    func addWindow(title: String, frame: NSRect? = nil, size: NSSize = NSSize(width: 460, height: 320)) -> WindowView {
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
            let r = NSRect(origin: anchor, size: size).insetBy(dx: -framePadding, dy: -(framePadding + tabHeight))
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
