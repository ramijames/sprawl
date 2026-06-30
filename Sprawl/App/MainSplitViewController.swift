import AppKit

/// Composes the translucent sidebar and the canvas, and wires the model's change callbacks.
/// Also serves as the responder-chain target for the app's menu/toolbar actions.
final class MainSplitViewController: NSSplitViewController {
    let model: AppModel
    private let sidebarVC: SidebarViewController
    private let canvasVC: CanvasViewController
    private let dock = FloatingDock(frame: .zero)
    private let optionsBar = OptionsBar(frame: .zero)
    private weak var optionsBarWindow: WindowView?

    // Sub-dock (group flyout) + click-to-place state.
    private var subDock: SubDock?
    private weak var subDockAnchor: NSView?
    private var subDockMonitor: Any?
    private var placeKind: WorkItem.Kind?
    private var placeMonitor: Any?

    // Connector drawing state (click-drag to place a two-point line).
    private var lineDrawing = false
    private weak var drawingItem: WorkItem?
    private weak var drawingPanel: LinePanel?
    private var drawMonitor: Any?
    private var lineGhost: NSView?
    private var drawTwoClick = false      // first node placed by a click; waiting for the 2nd click
    private var drawDidDrag = false       // the initial press moved (→ drag gesture, not a click)
    private var drawDownPoint = CGPoint.zero

    /// Notifies the toolbar when the current project changes (to update its name label).
    var onProjectChanged: ((Project?) -> Void)?

    init(model: AppModel) {
        self.model = model
        self.sidebarVC = SidebarViewController(model: model)
        self.canvasVC = CanvasViewController(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        addSplitViewItem(sidebarItem)

        let canvasItem = NSSplitViewItem(viewController: canvasVC)
        addSplitViewItem(canvasItem)

        splitView.autosaveName = "MainSplit"

        wireModel()
        installDock()

        // A restored workspace already has projects; only seed on a truly fresh launch. First-ever
        // launch shows the onboarding wizard; afterwards just seed an empty project.
        let isFreshLaunch = model.projects.isEmpty
        if isFreshLaunch {
            if UserDefaults.standard.bool(forKey: AppModel.hasOnboardedKey) {
                model.addProject(name: "Project 1")
            } else {
                model.beginOnboarding()
            }
        }
        canvasVC.restoreGlobalViewport()
        sidebarVC.reload()
        onProjectChanged?(model.currentProject)

        // Xcode-like default sidebar width on first launch only; a restored width is left to
        // the split view's autosave so it survives relaunch.
        if isFreshLaunch {
            DispatchQueue.main.async { [weak self] in
                self?.splitView.setPosition(260, ofDividerAt: 0)
            }
        }
    }

    /// The floating bottom-center dock: a Project button plus tool groups whose tools arm for
    /// click-to-place on the canvas.
    private func installDock() {
        dock.onNewProject = { [weak self] in self?.newProject(nil) }
        // Each dock tool ARMS placement; the item is created where you next click on the canvas.
        dock.onNewTerminal = { [weak self] in self?.beginPlacement(.terminal) }
        dock.onNewDocument = { [weak self] in self?.beginPlacement(.document) }
        dock.onNewBrowser = { [weak self] in self?.beginPlacement(.browser) }
        dock.onNewCodeEditor = { [weak self] in self?.beginPlacement(.codeEditor) }
        dock.onNewFigma = { [weak self] in self?.beginPlacement(.figma) }
        dock.onNewGitObserver = { [weak self] in self?.beginPlacement(.gitObserver) }
        dock.onNewGitGraph = { [weak self] in self?.beginPlacement(.gitGraph) }
        dock.onNewProjectVelocity = { [weak self] in self?.beginPlacement(.projectVelocity) }
        dock.onNewDiff = { [weak self] in self?.beginPlacement(.diff) }
        dock.onNewClaude = { [weak self] in self?.beginPlacement(.assistant) }
        dock.onNewSticky = { [weak self] in self?.beginPlacement(.sticky) }
        dock.onNewFreeText = { [weak self] in self?.beginPlacement(.freeText) }
        dock.onNewLine = { [weak self] in self?.beginLineDrawing() }
        dock.onToggleSubDock = { [weak self] tools, anchor in self?.toggleSubDock(tools, anchor: anchor) }

        canvasVC.addBottomOverlay(dock)

        optionsBar.isHidden = true
        canvasVC.view.addSubview(optionsBar)   // floats above the selected annotation
    }

    /// Show/configure the floating options bar for the selected annotation or git/analytics tool,
    /// or hide it.
    private func updateOptionsBar() {
        optionsBarWindow?.onGeometryChange2 = nil
        if model.isMultiSelect {   // multi-selection only supports Delete / Escape — no options bar
            optionsBar.isHidden = true
            optionsBarWindow = nil
            return
        }
        let repoKinds: Set<WorkItem.Kind> = [.gitObserver, .gitGraph, .projectVelocity, .codeEditor, .diff]
        let annotationKinds: Set<WorkItem.Kind> = [.sticky, .freeText]
        let lineKinds: Set<WorkItem.Kind> = [.line]
        guard let item = model.selectedItem,
              annotationKinds.contains(item.kind) || repoKinds.contains(item.kind)
                || lineKinds.contains(item.kind) || item.kind == .document,
              let window = item.window else {
            optionsBar.isHidden = true
            optionsBarWindow = nil
            return
        }
        if item.kind == .document {
            optionsBar.configureDocument(wrapOn: item.activeDocumentLeaf?.panel.wrapLines ?? true)
            optionsBar.onOpen = { [weak self] in self?.openDocument(nil) }
            optionsBar.onSave = { [weak self] in self?.saveDocument(nil) }
            optionsBar.onWrap = { [weak self] in
                guard let panel = item.activeDocumentLeaf?.panel else { return }
                panel.toggleWrap()
                self?.optionsBar.setDocWrap(panel.wrapLines)
            }
        } else if repoKinds.contains(item.kind) {
            optionsBar.configureRepo()
            optionsBar.onRepo = {
                switch item.kind {
                case .gitObserver: item.gitObserver?.chooseRepo()
                case .gitGraph: item.gitGraph?.chooseRepo()
                case .projectVelocity: item.projectVelocity?.chooseRepo()
                case .codeEditor: item.codeEditor?.chooseRepo()
                case .diff: item.diff?.chooseRepo()
                default: break
                }
            }
        } else if lineKinds.contains(item.kind) {
            let line = item.line
            optionsBar.configureLine(colorIndex: line?.colorIndex ?? 0,
                                     thickness: line?.thickness ?? 2,
                                     arrowStart: line?.hasArrowStart ?? false,
                                     arrowEnd: line?.hasArrowEnd ?? false)
            optionsBar.onColor = { index in item.line?.setColor(index) }
            optionsBar.onThickness = { t in item.line?.setThickness(t) }
            optionsBar.onArrowStart = { on in item.line?.setArrowStart(on) }
            optionsBar.onArrowEnd = { on in item.line?.setArrowEnd(on) }
        } else {
            let colorIndex = item.sticky?.colorIndex ?? item.freeText?.colorIndex ?? 0
            optionsBar.configure(showsFont: item.kind == .freeText, colorIndex: colorIndex,
                                 fontName: item.freeText?.fontName, fontSize: item.freeText?.fontSize)
            optionsBar.onColor = { index in item.sticky?.setColor(index); item.freeText?.setColor(index) }
            optionsBar.onFont = { name in item.freeText?.setFontName(name) }
            optionsBar.onSize = { size in item.freeText?.setFontSize(size) }
        }
        optionsBar.onDelete = { [weak self] in self?.model.removeItem(item) }
        optionsBar.isHidden = false
        optionsBarWindow = window
        window.onGeometryChange2 = { [weak self] in self?.positionOptionsBar() }
        positionOptionsBar()
    }

    private func positionOptionsBar() {
        guard !optionsBar.isHidden, let window = optionsBarWindow else { return }
        optionsBar.layoutSubtreeIfNeeded()
        let size = optionsBar.fittingSize
        let rect = canvasVC.view.convert(window.bounds, from: window)
        let y = canvasVC.view.isFlipped ? rect.minY - size.height - 8 : rect.maxY + 8
        optionsBar.setFrameSize(size)
        optionsBar.setFrameOrigin(NSPoint(x: rect.midX - size.width / 2, y: y))
    }

    /// Create an item in the focused project and pan the canvas to it (dock affordance).
    private func newItemFromDock(_ kind: WorkItem.Kind) {
        guard let item = model.addItem(kind: kind) else { return }
        canvasVC.centerOnItem(item)
    }

    // MARK: - Sub-dock (group flyout)

    /// Show the sub-dock of `tools` above `anchor`, or toggle it off if it's already showing there.
    private func toggleSubDock(_ tools: [DockTool], anchor: NSView) {
        if subDockAnchor === anchor { dismissSubDock(); return }
        dismissSubDock()
        guard !tools.isEmpty else { return }   // not-yet-populated groups (Ideate / Manage) just close
        let sub = SubDock(tools: tools) { [weak self] in self?.dismissSubDock() }
        canvasVC.view.addSubview(sub)
        sub.layoutSubtreeIfNeeded()
        let size = sub.fittingSize
        let anchorFrame = canvasVC.view.convert(anchor.bounds, from: anchor)
        let dockFrame = canvasVC.view.convert(dock.bounds, from: dock)
        sub.frame = NSRect(x: anchorFrame.midX - size.width / 2, y: dockFrame.maxY + 8,
                           width: size.width, height: size.height)
        subDock = sub
        subDockAnchor = anchor
        // Dismiss when clicking anywhere outside the sub-dock and the dock.
        subDockMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            guard let self, let sub = self.subDock else { return e }
            let hit = e.window?.contentView?.hitTest(e.locationInWindow)
            if let hit, hit.isDescendant(of: sub) || hit.isDescendant(of: self.dock) { return e }
            self.dismissSubDock()
            return e
        }
    }

    private func dismissSubDock() {
        subDock?.removeFromSuperview(); subDock = nil; subDockAnchor = nil
        if let m = subDockMonitor { NSEvent.removeMonitor(m); subDockMonitor = nil }
    }

    // MARK: - Click-to-place

    /// Arm a dock tool: the next canvas click creates `kind` at that point. (Lines have their own
    /// multi-click flow.) ESC cancels.
    func beginPlacement(_ kind: WorkItem.Kind) {
        dismissSubDock()
        if kind == .line { beginLineDrawing(); return }
        cancelPlacement()
        placeKind = kind
        model.isPlacing = true
        model.canvas.toolCursor = .crosshair
        NSCursor.crosshair.set()
        placeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] e in
            self?.handlePlacementEvent(e) ?? e
        }
    }

    private func handlePlacementEvent(_ e: NSEvent) -> NSEvent? {
        guard placeKind != nil else { return e }
        if e.type == .keyDown {
            if e.keyCode == 53 { cancelPlacement() }   // ESC
            return e
        }
        guard isCanvasDrawClick(e) else { return e }   // let dock / options bar work
        let p = model.canvas.convert(e.locationInWindow, from: nil)
        if let kind = placeKind, let project = model.currentProject ?? model.projects.first {
            _ = model.addItem(kind: kind, in: project, at: p)   // centered on the click; already in view
        }
        cancelPlacement()
        return nil
    }

    private func cancelPlacement() {
        guard placeKind != nil else { return }
        placeKind = nil
        model.isPlacing = false
        if let m = placeMonitor { NSEvent.removeMonitor(m); placeMonitor = nil }
        model.canvas.toolCursor = nil
        NSCursor.arrow.set()
    }

    // MARK: - Connector tool

    /// Arm the connector tool: the next press-drag-release on the canvas places a two-point line
    /// (press = start, release = end). A plain click drops a default-length connector. ESC cancels.
    func beginLineDrawing() {
        if lineDrawing { cancelLineDrawing() }
        lineDrawing = true
        model.isDrawingLine = true
        drawingItem = nil; drawingPanel = nil
        drawTwoClick = false; drawDidDrag = false
        dismissSubDock()
        model.canvas.toolCursor = .crosshair
        NSCursor.crosshair.set()
        view.window?.acceptsMouseMovedEvents = true
        drawMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved, .keyDown]) { [weak self] e in
            self?.handleDrawingEvent(e) ?? e
        }
    }

    private func handleDrawingEvent(_ e: NSEvent) -> NSEvent? {
        guard lineDrawing else { return e }
        if e.type == .keyDown {
            if e.keyCode == 53 { cancelLineDrawing() }   // ESC cancels
            return e
        }
        guard isCanvasDrawClick(e) else { hideLineGhost(); return e }   // dock / sidebar / options bar work normally
        NSCursor.crosshair.set()
        let p = model.canvas.convert(e.locationInWindow, from: nil)
        switch e.type {
        case .mouseMoved:
            // Before the first click: preview the first node. After it (two-click mode): preview
            // where the next node will land — but don't render the line until the second click.
            if drawingPanel == nil || drawTwoClick { showLineGhost(atCanvas: snapCanvasPoint(p)) }
            return e
        case .leftMouseDown:
            if drawTwoClick {                         // second click → set the end and render the line
                hideLineGhost()
                drawingPanel?.setEnd(towardCanvas: p)
                finishLineDrawing()
                return nil
            }
            hideLineGhost()
            guard let created = model.createLine(firstNodeCanvas: p) else { cancelLineDrawing(); return nil }
            drawingItem = created.item; drawingPanel = created.panel
            drawDidDrag = false
            drawDownPoint = p
            positionOptionsBar()
            return nil
        case .leftMouseDragged:
            if drawingPanel == nil { return nil }
            if hypot(p.x - drawDownPoint.x, p.y - drawDownPoint.y) > 4 { drawDidDrag = true }
            drawingPanel?.setEnd(towardCanvas: p)
            positionOptionsBar()
            return nil
        case .leftMouseUp:
            // A press-drag-release places both ends at once; a plain click places only the first
            // node and waits for a second click (the line then follows the cursor).
            if drawDidDrag { finishLineDrawing() }
            else if drawingPanel != nil { drawTwoClick = true }
            return nil
        default:
            return e
        }
    }

    /// Snap a canvas point to the grid when snapping is on (matches the connector's own snapping).
    private func snapCanvasPoint(_ p: CGPoint) -> CGPoint {
        let g = model.canvas.snapGrid
        return g > 0 ? CGPoint(x: CanvasView.snap(p.x, to: g), y: CanvasView.snap(p.y, to: g)) : p
    }

    /// A small circle that previews where the first node will land (snapped) before the first click.
    private func showLineGhost(atCanvas p: CGPoint) {
        let ghost: NSView
        if let g = lineGhost { ghost = g } else {
            let g = NSView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
            g.wantsLayer = true
            g.layer?.cornerRadius = 6
            g.layer?.backgroundColor = NSColor.white.cgColor
            g.layer?.borderWidth = 2
            g.layer?.borderColor = NSColor.controlAccentColor.cgColor
            model.canvas.addSubview(g)
            lineGhost = g
            ghost = g
        }
        ghost.isHidden = false
        ghost.frame = NSRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)
    }

    private func hideLineGhost() {
        lineGhost?.removeFromSuperview()
        lineGhost = nil
    }

    /// Only treat clicks on the canvas surface as drawing; let docks / options bar work.
    private func isCanvasDrawClick(_ e: NSEvent) -> Bool {
        guard let hit = e.window?.contentView?.hitTest(e.locationInWindow) else { return false }
        if hit.isDescendant(of: dock) || hit.isDescendant(of: optionsBar) || (subDock.map { hit.isDescendant(of: $0) } ?? false) {
            return false
        }
        guard let scroll = model.canvas.enclosingScrollView else { return false }
        return hit.isDescendant(of: scroll)
    }

    /// Release: keep the connector (giving a click-only a default length), then disarm.
    private func finishLineDrawing() {
        disarmLineDrawing()
        guard let item = drawingItem, let panel = drawingPanel else { return }
        if !panel.isPlaced { panel.extendToDefault() }   // a plain click → default-length connector
        model.finalizeLineCreation(item)
        updateOptionsBar()
        drawingItem = nil; drawingPanel = nil
    }

    /// ESC: drop the in-progress connector entirely.
    private func cancelLineDrawing() {
        disarmLineDrawing()
        if let item = drawingItem { model.discardItem(item) }
        drawingItem = nil; drawingPanel = nil
        updateOptionsBar()
    }

    private func disarmLineDrawing() {
        guard lineDrawing else { return }
        lineDrawing = false
        model.isDrawingLine = false
        if let m = drawMonitor { NSEvent.removeMonitor(m); drawMonitor = nil }
        drawTwoClick = false; drawDidDrag = false
        hideLineGhost()
        model.canvas.toolCursor = nil
        view.window?.acceptsMouseMovedEvents = false
        NSCursor.arrow.set()
    }

    /// Zoom the selected window to fit the viewport height ("~").
    func fitSelectedItem() {
        guard let item = model.selectedItem else { return }
        canvasVC.fitItemVertically(item)
    }

    /// Flush the live canvas viewport into the model so the next snapshot is current.
    func captureViewport() {
        canvasVC.captureCurrentViewport()
    }

    private func wireModel() {
        model.onModelChange = { [weak self] in self?.sidebarVC.reload() }
        model.onFocusProject = { [weak self] project in self?.canvasVC.focusProject(project) }
        model.onSelectionChange = { [weak self] in
            guard let self else { return }
            self.sidebarVC.syncSelection(self.model.selection)
            self.updateOptionsBar()
        }
        model.onOnboardingFinished = { [weak self] in self?.dock.highlightApps() }
        model.onRequestLineDrawing = { [weak self] in self?.beginLineDrawing() }
        // Current project changed — toolbar label only now (no canvas swap on the shared surface).
        model.onCurrentProjectChange = { [weak self] in
            guard let self else { return }
            self.onProjectChanged?(self.model.currentProject)
        }

        sidebarVC.onSelectProject = { [weak self] project in
            guard let self else { return }
            self.model.selectProject(project)
            self.canvasVC.focusProject(project)
        }
        sidebarVC.onSelectItem = { [weak self] item in
            guard let self else { return }
            self.model.selectItem(item)
            self.canvasVC.fitItemVertically(item)   // center + zoom to fill, like ⌘`
        }
        sidebarVC.onDeleteItem = { [weak self] item in self?.model.removeItem(item) }
        sidebarVC.onDeleteProject = { [weak self] project in self?.model.removeProject(project) }
        sidebarVC.onRenameItem = { [weak self] item, name in self?.model.renameItem(item, to: name) }
        sidebarVC.onRenameProject = { [weak self] project, name in self?.model.renameProject(project, to: name) }
        sidebarVC.onAddItem = { [weak self] kind in self?.model.addItem(kind: kind) }
        sidebarVC.onAddProject = { [weak self] in self?.newProject(nil) }
        sidebarVC.onOpenDocument = { [weak self] in self?.openDocument(nil) }

        canvasVC.onViewportChange = { [weak self] in
            self?.model.onPersistableChange?()
            self?.positionOptionsBar()
        }
    }

    // MARK: - Menu / toolbar actions (reached through the responder chain or directly)

    @objc func newTerminal(_ sender: Any?) { model.addItem(kind: .terminal) }
    @objc func newDocument(_ sender: Any?) { model.addItem(kind: .document) }
    @objc func newBrowser(_ sender: Any?) { model.addItem(kind: .browser) }
    @objc func newGitObserver(_ sender: Any?) { model.addItem(kind: .gitObserver) }
    @objc func newGitGraph(_ sender: Any?) { model.addItem(kind: .gitGraph) }
    @objc func newProjectVelocity(_ sender: Any?) { model.addItem(kind: .projectVelocity) }
    @objc func newClaude(_ sender: Any?) { model.addItem(kind: .assistant) }
    @objc func newSticky(_ sender: Any?) { model.addItem(kind: .sticky) }
    @objc func newFreeText(_ sender: Any?) { model.addItem(kind: .freeText) }
    @objc func newLine(_ sender: Any?) { beginLineDrawing() }
    @objc func replayOnboarding(_ sender: Any?) { model.beginOnboarding() }

    @objc func undo(_ sender: Any?) {
        // While editing text, ⌘Z undoes typing (the focused view's own undo); otherwise app history.
        if let responder = view.window?.firstResponder, AppDelegate.isEditingContent(responder),
           let manager = responder.undoManager, manager.canUndo {
            manager.undo(); return
        }
        model.history.undo()
    }

    @objc func redo(_ sender: Any?) {
        if let responder = view.window?.firstResponder, AppDelegate.isEditingContent(responder),
           let manager = responder.undoManager, manager.canRedo {
            manager.redo(); return
        }
        model.history.redo()
    }

    @objc func newProject(_ sender: Any?) {
        let anchor = canvasVC.freeAnchorNearViewport()
        let project = model.addProject(name: "Project \(model.projects.count + 1)", anchor: anchor)
        model.selectProject(project)
        canvasVC.focusProject(project)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            // Load into the focused document (its active tab); only make a new window if no
            // document is open to receive it.
            if let item = self.model.activeDocumentItem, let leaf = item.activeDocumentLeaf {
                leaf.panel.model.open(url: url)
                leaf.setName(url.lastPathComponent)   // retitle the tab + window
                item.name = url.lastPathComponent     // and the sidebar row
                self.model.onModelChange?()
                self.model.onPersistableChange?()
            } else {
                self.model.addItem(kind: .document, url: url)
            }
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let item = model.activeDocumentItem, let leaf = item.activeDocumentLeaf else { return }
        let doc = leaf.panel
        if doc.model.fileURL == nil {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = leaf.title
            panel.begin { [weak self, weak item] response in
                guard response == .OK, let url = panel.url else { return }
                doc.model.saveAs(url: url)
                leaf.setName(url.lastPathComponent)   // retitles the tab chip + window
                item?.name = url.lastPathComponent    // keep the sidebar row + persisted name in sync
                self?.model.onModelChange?()
                self?.model.onPersistableChange?()
            }
        } else {
            doc.save()
        }
    }

    @objc func fitWindowToScreen(_ sender: Any?) { fitSelectedItem() }

    @objc func zoomIn(_ sender: Any?) { canvasVC.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { canvasVC.zoomOut() }
    @objc func zoomReset(_ sender: Any?) { canvasVC.zoomReset() }
}
