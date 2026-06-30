import AppKit

/// A single item living inside a project: a terminal or a document. Each is backed by a
/// `WindowView` panel on the shared canvas.
final class WorkItem {
    enum Kind {
        case terminal
        case document
        case codeEditor
        case browser
        case gitObserver
        case gitGraph
        case projectVelocity
        case diff
        case assistant
        case onboarding
        case sticky
        case freeText
        case line
        var symbolName: String {
            switch self {
            case .terminal: return "terminal"
            case .document: return "doc.text"
            case .codeEditor: return "chevron.left.forwardslash.chevron.right"
            case .browser: return "globe"
            case .gitObserver: return "chart.bar.xaxis"
            case .gitGraph: return "point.3.connected.trianglepath.dotted"
            case .projectVelocity: return "gauge.with.dots.needle.67percent"
            case .diff: return "plus.forwardslash.minus"
            case .assistant: return "sparkles"
            case .onboarding: return "hand.wave"
            case .sticky: return "note.text"
            case .freeText: return "textformat"
            case .line: return "line.diagonal"
            }
        }
    }

    let id = UUID()
    var name: String
    let kind: Kind
    weak var window: WindowView?
    /// Terminal & document items host a tabbed container (one or more terminal/document tabs).
    var container: TabbedContainer?
    /// Strong reference so the web view stays alive while the item exists.
    var browser: BrowserPanel?
    /// Git Observer items host a repo contribution graph + commit timeline.
    var gitObserver: GitObserverPanel?
    /// Git Graph items host a branch/merge history graph.
    var gitGraph: GitGraphPanel?
    /// Project Velocity items host a development-speed gauge.
    var projectVelocity: ProjectVelocityPanel?
    /// Diff items show uncommitted changes (`git diff HEAD`).
    var diff: DiffPanel?
    /// Claude assistant panel (streaming chat, repo-aware).
    var assistant: ClaudePanel?
    /// First-run onboarding wizard panel.
    var onboarding: OnboardingPanel?
    /// Sticky-note glass panel (pastel text editor).
    var sticky: StickyPanel?
    /// Free-text annotation (backgroundless pastel text).
    var freeText: FreeTextPanel?
    /// Line / connector annotation (straight or curved, with optional arrowheads).
    var line: LinePanel?
    /// Native code editor over a repo file tree.
    var codeEditor: CodeEditorPanel?
    /// True once the user has manually renamed this item — suppresses auto-title updates (page
    /// title, repo name, active-tab title) so the chosen name sticks.
    var userRenamed = false

    /// The active document tab's panel (Save targets this), if this is a document item.
    var activeDocumentLeaf: DocumentLeaf? { container?.activeLeaf as? DocumentLeaf }
    /// Whatever supports ⌘T / ⌘W for this item.
    var tabbable: Tabbable? { browser ?? container }

    init(name: String, kind: Kind, window: WindowView? = nil) {
        self.name = name
        self.kind = kind
        self.window = window
    }
}

/// A project: a named group of items, rendered as one "folder" on the shared canvas. Its folder
/// wraps wherever its windows are; `anchor` is the content top-left used while it's empty and as
/// the seed for spawning its first window.
final class Project {
    let id: UUID
    var name: String
    var items: [WorkItem] = []
    /// Content-region top-left in shared-canvas coordinates.
    var anchor: NSPoint = .zero
    /// Collapsed projects hide their windows and draw as just the tab.
    var isCollapsed: Bool = false
    /// Index into `Palette.projectColors`, or nil for no accent color.
    var colorIndex: Int?

    var color: NSColor? {
        guard let i = colorIndex, Palette.projectColors.indices.contains(i) else { return nil }
        return Palette.projectColors[i]
    }

    init(name: String, id: UUID = UUID(), anchor: NSPoint = .zero) {
        self.id = id
        self.name = name
        self.anchor = anchor
    }
}

/// Top-level app state. Owns the single shared `CanvasView` (so it exists at restore time, before
/// the UI is built) and the projects on it. What is selected (nothing / a project / an item) is a
/// single source of truth here.
final class AppModel {
    /// The single canvas hosting every project's windows.
    let canvas = CanvasView(frame: .zero)
    /// Shared tally of opened sites, driving every browser's most-opened start-page grid.
    let topSites = TopSitesStore()
    /// Undo/redo for create, delete, move/resize, and rename.
    let history = UndoHistory()

    /// Canvas snapping grid in points (0 = off, else 10 or 100). Applied when an item is moved or
    /// resized, or a project is dragged. Persisted across launches.
    var snapGrid: CGFloat {
        get { CGFloat(UserDefaults.standard.double(forKey: "SprawlSnapGrid")) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "SprawlSnapGrid") }
    }

    private(set) var projects: [Project] = []
    private(set) var currentProject: Project?
    /// The document most recently created/focused — the target for Save.
    weak var activeDocumentItem: WorkItem?

    /// Global canvas viewport (zoom + scroll), persisted across launches.
    var viewport: ViewportState?

    enum Selection: Equatable {
        case none
        case project(UUID)
        case item(UUID)
    }
    private(set) var selection: Selection = .none
    /// Selected canvas items (the source of truth for item selection; supports SHIFT multi-select).
    /// `selection` mirrors this as `.item(primary)` when ≥1 is selected, or `.project`/`.none`.
    private(set) var selectedItemIDs: Set<UUID> = []
    /// True when more than one item is selected — only Delete / Escape act on a multi-selection.
    var isMultiSelect: Bool { selectedItemIDs.count > 1 }

    /// Structure changed (project/item added or removed) — sidebar should reload.
    var onModelChange: (() -> Void)?
    /// The current project changed — used only for the toolbar label now (no canvas swap).
    var onCurrentProjectChange: (() -> Void)?
    /// Something worth persisting changed (layout, contents, viewport, …) — request a save.
    var onPersistableChange: (() -> Void)?
    /// Selection changed — drives white-outline visuals (item windows + the selected folder).
    var onSelectionChange: (() -> Void)?
    /// Center/zoom the canvas on a project (set by the split-view controller).
    var onFocusProject: ((Project) -> Void)?
    /// Onboarding just completed — used to spotlight the dock's "add app" button.
    var onOnboardingFinished: (() -> Void)?
    /// True while the pen tool is actively building a line — global monitors defer to it.
    var isDrawingLine = false
    /// True while a dock tool is armed for click-to-place — global monitors defer to it.
    var isPlacing = false
    /// The connector tool was requested (dock / menu / context) — the split-view controller arms it.
    var onRequestLineDrawing: (() -> Void)?

    init() {
        canvas.model = self
        canvas.onLayoutChange = { [weak self] in self?.onPersistableChange?() }
        canvas.onRenameProject = { [weak self] id, newName in
            guard let self, let project = self.projects.first(where: { $0.id == id }) else { return }
            project.name = newName
            self.canvas.needsDisplay = true
            self.onModelChange?()             // sidebar reflects the new name
            self.onPersistableChange?()
        }
        canvas.onSelectProjectFolder = { [weak self] id in
            guard let self, let project = self.projects.first(where: { $0.id == id }) else { return }
            self.selectProject(project)
        }
        canvas.onClearSelection = { [weak self] in self?.clearSelection() }
        canvas.onToggleCollapse = { [weak self] id in
            guard let self, let project = self.projects.first(where: { $0.id == id }) else { return }
            self.toggleCollapse(project)
        }
        canvas.onSetProjectColor = { [weak self] id, index in
            guard let self, let project = self.projects.first(where: { $0.id == id }) else { return }
            project.colorIndex = index
            self.canvas.needsDisplay = true
            self.onPersistableChange?()
        }
        canvas.onCreateProject = { [weak self] point in
            guard let self else { return }
            let project = self.addProject(name: "Project \(self.projects.count + 1)",
                                          anchor: self.projectAnchor(centeredAt: point))
            self.selectProject(project)
        }
        canvas.onCreateItem = { [weak self] id, kind, point in
            guard let self, let project = self.projects.first(where: { $0.id == id }) else { return }
            self.addItem(kind: kind, in: project, at: point)
        }
    }

    /// Top-left content anchor that roughly centers a new (empty) project's folder on a canvas point.
    private func projectAnchor(centeredAt point: NSPoint) -> NSPoint {
        let size = SharedCanvasLayout.defaultEmptyContent
        return clampedOrigin(NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size)
    }

    /// Keep a `size`-sized box fully inside the canvas, so a click near an edge can't place a panel
    /// (or folder) at a negative origin where its header would be scrolled out of reach.
    private func clampedOrigin(_ origin: NSPoint, size: CGSize) -> NSPoint {
        let maxX = max(0, SharedCanvasLayout.canvasSize.width - size.width)
        let maxY = max(0, SharedCanvasLayout.canvasSize.height - size.height)
        return NSPoint(x: min(max(0, origin.x), maxX), y: min(max(0, origin.y), maxY))
    }

    func toggleCollapse(_ project: Project) {
        project.isCollapsed.toggle()
        applyCollapse(project)
        canvas.needsDisplay = true
        onPersistableChange?()
    }

    /// Hide/show a project's windows to match its collapsed state.
    private func applyCollapse(_ project: Project) {
        for item in project.items { item.window?.isHidden = project.isCollapsed }
    }

    // MARK: - Projects & items

    @discardableResult
    func addProject(name: String, anchor: NSPoint = .zero) -> Project {
        let project = Project(name: name, anchor: anchor)
        projects.append(project)
        if currentProject == nil { currentProject = project }
        canvas.needsDisplay = true
        onModelChange?()
        onPersistableChange?()
        return project
    }

    func project(owning item: WorkItem) -> Project? {
        projects.first { $0.items.contains { $0 === item } }
    }

    /// Rename an item (from the sidebar or its window header). Sticks against auto-titling. Undoable.
    func renameItem(_ item: WorkItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        let oldName = item.name
        let oldRenamed = item.userRenamed
        applyItemName(item, trimmed, renamed: true)
        history.register("Rename",
            undo: { [weak self, weak item] in if let item { self?.applyItemName(item, oldName, renamed: oldRenamed) } },
            redo: { [weak self, weak item] in if let item { self?.applyItemName(item, trimmed, renamed: true) } })
    }

    private func applyItemName(_ item: WorkItem, _ name: String, renamed: Bool) {
        item.name = name
        item.userRenamed = renamed
        item.window?.title = name
        onModelChange?()
        onPersistableChange?()
    }

    /// Rename a project (from the sidebar; the folder tab has its own inline editor).
    func renameProject(_ project: Project, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != project.name else { return }
        project.name = trimmed
        canvas.needsDisplay = true
        onModelChange?()
        onPersistableChange?()
    }

    // MARK: - Onboarding (first run)

    static let hasOnboardedKey = "SprawlHasOnboarded"

    /// Seed a "Welcome" project containing the onboarding wizard, and focus it. Used on first launch.
    func beginOnboarding() {
        let project = addProject(name: "Welcome")
        let item = addItem(kind: .onboarding, in: project)
        item.window?.setFrameSize(NSSize(width: 560, height: 440))
        selectProject(project)
        DispatchQueue.main.async { [weak self] in self?.onFocusProject?(project) }
    }

    /// Finish the wizard: remove the onboarding project, create the user's first real project,
    /// focus it, and remember that onboarding is done so it doesn't reappear.
    func finishOnboarding(firstProjectName: String?) {
        UserDefaults.standard.set(true, forKey: Self.hasOnboardedKey)
        let onboardingProjects = projects.filter { $0.items.contains { $0.kind == .onboarding } }
        let project = addProject(name: firstProjectName?.isEmpty == false ? firstProjectName! : "Project 1",
                                 anchor: canvas.freeAnchorNearViewport())
        // Seed the project with a friendly welcome document.
        let welcome = """
        Welcome to a new way of working.

        This is your first project. Each project groups the stuff that you do together. It lets you \
        work with more focus because everything you need is right in front of you.

        Below is the dock. It's where you can add things to your project. Why don't you try it out?
        """
        installItem(in: project, kind: .document, name: "Welcome", frame: spawnFrame(in: project),
                    contentURL: nil, documentText: welcome, terminalDirectory: nil, focus: true)
        for stale in onboardingProjects { removeProject(stale) }
        setCurrentProject(project)
        onModelChange?()
        onPersistableChange?()
        DispatchQueue.main.async { [weak self] in
            self?.onFocusProject?(project)
            self?.onOnboardingFinished?()
        }
    }

    /// Delete a single item (undoable). Captures its state so undo can recreate it.
    func removeItem(_ item: WorkItem) {
        guard let project = project(owning: item) else { performRemoveItem(item); return }
        let state = makeItemState(item)
        let box = Box<WorkItem?>(nil)
        performRemoveItem(item)
        history.register("Delete \(item.name)",
            undo: { [weak self] in box.value = self?.installItem(from: state, in: project, focus: false) },
            redo: { [weak self] in if let it = box.value { self?.performRemoveItem(it) } })
    }

    /// The actual teardown: remove the panel, clear selection if it was selected, reload + autosave.
    /// Does not register undo (used by `removeItem` and by undo/redo of create/delete).
    private func performRemoveItem(_ item: WorkItem) {
        if let window = item.window {
            window.removeFromSuperview()
        }
        for project in projects { project.items.removeAll { $0 === item } }
        let wasSelected = selectedItemIDs.contains(item.id)
        selectedItemIDs.remove(item.id)
        if selection == .item(item.id) { selection = selectedItemIDs.first.map { .item($0) } ?? .none }
        if wasSelected { applySelectionVisuals(); onSelectionChange?() }
        canvas.needsDisplay = true
        onModelChange?()
        onPersistableChange?()
    }

    /// Delete a whole project and all of its windows.
    func removeProject(_ project: Project) {
        selectedItemIDs.subtract(project.items.map { $0.id })
        for item in project.items { item.window?.removeFromSuperview() }
        projects.removeAll { $0 === project }
        if currentProject === project {
            currentProject = projects.first
            onCurrentProjectChange?()
        }
        switch selection {
        case .project(let id) where id == project.id:
            clearSelection()
        case .item(let id) where !projects.contains(where: { $0.items.contains { $0.id == id } }):
            clearSelection()
        default:
            break
        }
        canvas.needsDisplay = true
        onModelChange?()
        onPersistableChange?()
    }

    /// The single selected item (nil when nothing — or more than one — is selected, so per-item
    /// affordances like the options bar and ⌘T/⌘W only apply to a lone selection).
    var selectedItem: WorkItem? {
        guard selectedItemIDs.count == 1, let id = selectedItemIDs.first else { return nil }
        for project in projects {
            if let item = project.items.first(where: { $0.id == id }) { return item }
        }
        return nil
    }

    /// The selected window's tab controller (browser or terminal/document container) — drives
    /// ⌘T/⌘W off the selection (the white-outlined window) rather than off keyboard focus.
    var selectedTabbable: Tabbable? { selectedItem?.tabbable }

    func item(for window: WindowView) -> WorkItem? {
        for project in projects {
            if let item = project.items.first(where: { $0.window === window }) { return item }
        }
        return nil
    }

    @discardableResult
    func addItem(kind: WorkItem.Kind, url: URL? = nil) -> WorkItem? {
        guard let project = currentProject else { return nil }
        return addItem(kind: kind, in: project, url: url)
    }

    /// Add an item to a specific project, optionally spawning its window centered on an explicit
    /// canvas point (used by the right-click "new item" menu); otherwise it cascades near the
    /// project's existing windows. Makes that project current and selects the new item.
    @discardableResult
    func addItem(kind: WorkItem.Kind, in project: Project, at point: NSPoint? = nil, url: URL? = nil) -> WorkItem {
        let name: String
        if kind == .document, let url {
            name = url.lastPathComponent
        } else {
            let base: String
            switch kind {
            case .terminal: base = "Terminal"
            case .document: base = "Document"
            case .codeEditor: base = "Code"
            case .browser: base = "Browser"
            case .gitObserver: base = "Git Observer"
            case .gitGraph: base = "Git Graph"
            case .projectVelocity: base = "Project Velocity"
            case .diff: base = "Diff"
            case .assistant: base = "Claude"
            case .onboarding: base = "Welcome to Sprawl"
            case .sticky: base = "Sticky"
            case .freeText: base = "Text"
            case .line: base = "Line"
            }
            name = base   // no numeric suffix — items can share a name (rename to disambiguate)
        }

        let wasCollapsed = project.isCollapsed
        if wasCollapsed {               // adding content expands the folder (and unhides its windows)
            project.isCollapsed = false
            applyCollapse(project)
        }

        // Honor an explicit click point only for an already-expanded project (where the empty-folder
        // spot is meaningful); a just-revealed collapsed project cascades off its existing windows.
        let size = SharedCanvasLayout.defaultPanelSize
        let frame: NSRect
        if let point, !wasCollapsed {
            let origin = clampedOrigin(NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size)
            frame = NSRect(origin: origin, size: size)
        } else {
            frame = spawnFrame(in: project)
        }

        let item = installItem(in: project, kind: kind, name: name,
                               frame: frame,
                               contentURL: url, documentText: nil,
                               terminalDirectory: nil, focus: true)
        setCurrentProject(project)
        select(.item(item.id))
        onModelChange?()
        onPersistableChange?()

        // Undoable create: undo removes it; redo re-creates it (from its state captured now, since
        // the window is gone once undone).
        if kind != .onboarding {
            let createdState = makeItemState(item)
            let box = Box<WorkItem?>(item)
            history.register("Add \(name)",
                undo: { [weak self] in if let it = box.value { self?.performRemoveItem(it) } },
                redo: { [weak self] in box.value = self?.installItem(from: createdState, in: project, focus: false) })
        }
        return item
    }

    /// Record a move/resize as one undoable step (called on drag end).
    func registerGeometryChange(_ item: WorkItem?, from old: NSRect, to new: NSRect) {
        guard let item, old != new else { return }
        history.register("Move",
            undo: { [weak item] in item?.window?.frame = old; item?.window?.onGeometryChange2?() },
            redo: { [weak item] in item?.window?.frame = new; item?.window?.onGeometryChange2?() })
        onPersistableChange?()
    }

    // MARK: - Line pen tool

    /// Create a line item with a single first node at `p` (canvas coords), ready for the pen tool to
    /// extend. Not undoable until `finalizeLineCreation` (it may be discarded if left empty).
    func createLine(firstNodeCanvas p: CGPoint) -> (item: WorkItem, panel: LinePanel)? {
        guard let project = currentProject ?? projects.first else { return nil }
        if project.isCollapsed { project.isCollapsed = false; applyCollapse(project) }
        let item = installItem(in: project, kind: .line, name: "Line",
                               frame: NSRect(x: p.x, y: p.y, width: 40, height: 40),
                               contentURL: nil, documentText: nil, terminalDirectory: nil,
                               focus: false, lineNodes: [])
        guard let panel = item.line else { performRemoveItem(item); return nil }
        panel.startPath(atCanvas: p)
        setCurrentProject(project)
        selectItem(item)
        onModelChange?()
        onPersistableChange?()
        return (item, panel)
    }

    /// Register an undoable create for a pen-tool line once it's finished, and persist.
    func finalizeLineCreation(_ item: WorkItem) {
        guard item.line != nil,
              let project = projects.first(where: { $0.items.contains(where: { $0 === item }) }) else { return }
        let createdState = makeItemState(item)
        let box = Box<WorkItem?>(item)
        history.register("Add Line",
            undo: { [weak self] in if let it = box.value { self?.performRemoveItem(it) } },
            redo: { [weak self] in box.value = self?.installItem(from: createdState, in: project, focus: false) })
        onPersistableChange?()
    }

    /// Discard an item with no undo step (e.g. an abandoned, single-point line).
    func discardItem(_ item: WorkItem) {
        let wasSelected: Bool = { if case .item(let id) = selection { return id == item.id }; return false }()
        performRemoveItem(item)
        if wasSelected { select(.none) }
        onModelChange?()
        onPersistableChange?()
    }

    /// Host a popup browser panel (created by WebKit's `createWebViewWith`) as a new item in a
    /// project, so `target="_blank"` / `window.open` open a new browser window.
    func hostBrowser(_ panel: BrowserPanel, in project: Project) {
        if project.isCollapsed { project.isCollapsed = false }
        let item = installItem(in: project, kind: .browser, name: "Browser",
                               frame: spawnFrame(in: project),
                               contentURL: nil, documentText: nil,
                               terminalDirectory: nil, focus: true,
                               browserPanel: panel)
        select(.item(item.id))
        onModelChange?()
        onPersistableChange?()
    }

    /// Where a new window for a project spawns: cascaded near its existing windows, or at its
    /// anchor when empty, so it joins the project's folder instead of the viewport center.
    private func spawnFrame(in project: Project, size: NSSize = SharedCanvasLayout.defaultPanelSize) -> NSRect {
        let frames = project.items.compactMap { $0.window?.frame }
        guard let first = frames.first else {
            return NSRect(origin: project.anchor, size: size)
        }
        let union = frames.dropFirst().reduce(first) { $0.union($1) }
        let step = CGFloat((project.items.count % 6) * 28)
        return NSRect(x: union.minX + step, y: union.minY + step, width: size.width, height: size.height)
    }

    /// Wire a tabbed terminal/document container's callbacks to the window and model.
    private func wireContainer(_ container: TabbedContainer, window: WindowView, item: WorkItem) {
        container.onActiveTitleChange = { [weak window, weak item] title in
            guard let window, let item, !item.userRenamed, !title.isEmpty else { return }
            window.title = title
        }
        container.onRequestClose = { [weak window] in
            guard let window else { return }
            window.onClose?(window)
        }
        container.onStructureChange = { [weak self] in
            self?.onModelChange?()
            self?.onPersistableChange?()
        }
        container.onContentChange = { [weak self] in self?.onPersistableChange?() }
    }

    /// Builds a panel (terminal or document) on the shared canvas and wires it up. Shared by
    /// `addItem` (new) and `restore` (saved frame, no focus).
    @discardableResult
    private func installItem(in project: Project,
                             kind: WorkItem.Kind,
                             name: String,
                             frame: NSRect?,
                             contentURL: URL?,
                             documentText: String?,
                             terminalDirectory: String?,
                             focus: Bool,
                             browserPanel: BrowserPanel? = nil,
                             browserTabs: [String]? = nil,
                             browserActiveTab: Int = 0,
                             tabStates: [TabState]? = nil,
                             tabActive: Int = 0,
                             stickyColor: Int? = nil,
                             freeTextSize: Double? = nil,
                             lineThickness: Double? = nil,
                             lineArrowStart: Bool? = nil,
                             lineArrowEnd: Bool? = nil,
                             lineNodes: [CGPoint]? = nil,
                             lineBend: Double? = nil) -> WorkItem {
        let window = canvas.addWindow(title: name, frame: frame)
        let item = WorkItem(name: name, kind: kind, window: window)
        window.onClose = { [weak self, weak item] _ in
            guard let self, let item else { return }
            self.removeItem(item)   // undoable
        }
        window.onRename = { [weak self, weak item] newName in
            guard let self, let item else { return }
            self.renameItem(item, to: newName)
        }
        window.onGeometryCommitted = { [weak self, weak item] old, new in
            self?.registerGeometryChange(item, from: old, to: new)
        }

        switch kind {
        case .terminal:
            let container = TabbedContainer()
            wireContainer(container, window: window, item: item)
            container.makeLeaf = { TerminalLeaf(startDirectory: nil, name: "Terminal") }
            let states = tabStates ?? [TabState(name: name, workingDirectory: terminalDirectory)]
            for state in states {
                container.addLeaf(TerminalLeaf(startDirectory: state.workingDirectory,
                                               name: state.name ?? "Terminal"), select: false)
            }
            container.attach(to: window)
            container.selectTab(at: tabActive, focus: focus)
            item.container = container
        case .document:
            let container = TabbedContainer()
            wireContainer(container, window: window, item: item)
            container.makeLeaf = { DocumentLeaf(fileURL: nil, initialText: nil, name: "Document") }
            let states = tabStates ?? [TabState(name: name, filePath: contentURL?.path, documentText: documentText)]
            for state in states {
                let url = state.filePath.map { URL(fileURLWithPath: $0) }
                container.addLeaf(DocumentLeaf(fileURL: url, initialText: state.documentText,
                                               name: state.name ?? "Document"), select: false)
            }
            container.attach(to: window)
            container.selectTab(at: tabActive, focus: focus)
            item.container = container
            activeDocumentItem = item
        case .codeEditor:
            let panel = CodeEditorPanel(repoPath: contentURL?.path)
            panel.attach(to: window)
            panel.onTitleChange = { [weak window, weak item] title in
                guard let window, let item, !item.userRenamed, !title.isEmpty else { return }
                window.title = title
            }
            panel.onRepoChange = { [weak self] in self?.onPersistableChange?() }
            // Show the restored repo in the title (init's selectRepo runs before onTitleChange is set).
            if !item.userRenamed, let rp = contentURL?.path, !rp.isEmpty {
                window.title = (rp as NSString).lastPathComponent
            }
            if focus { panel.focus() }
            item.codeEditor = panel
        case .browser:
            let panel: BrowserPanel
            if let browserPanel {
                panel = browserPanel
            } else if let browserTabs, !browserTabs.isEmpty {
                panel = BrowserPanel(topSites: topSites, tabURLs: browserTabs, activeIndex: browserActiveTab)
            } else {
                panel = BrowserPanel(topSites: topSites, url: contentURL)
            }
            panel.attach(to: window)
            panel.onTitleChange = { [weak window, weak item] title in
                guard let window, let item, !item.userRenamed, !title.isEmpty else { return }
                window.title = title
            }
            panel.onURLChange = { [weak self] in self?.onPersistableChange?() }
            panel.onHostNewBrowser = { [weak self, weak project] popup in
                guard let self, let project else { return }
                self.hostBrowser(popup, in: project)
            }
            panel.onRequestClose = { [weak window] in
                guard let window else { return }
                window.onClose?(window)
            }
            item.browser = panel
        case .gitObserver:
            let panel = GitObserverPanel(repoPath: contentURL?.path)
            panel.attach(to: window)
            panel.onTitleChange = { [weak window, weak item] title in
                guard let window, let item, !item.userRenamed, !title.isEmpty else { return }
                window.title = title
            }
            panel.onRepoChange = { [weak self] in self?.onPersistableChange?() }
            item.gitObserver = panel
        case .gitGraph:
            let panel = GitGraphPanel(repoPath: contentURL?.path)
            panel.attach(to: window)
            panel.onTitleChange = { [weak window, weak item] title in
                guard let window, let item, !item.userRenamed, !title.isEmpty else { return }
                window.title = title
            }
            panel.onRepoChange = { [weak self] in self?.onPersistableChange?() }
            item.gitGraph = panel
        case .projectVelocity:
            let panel = ProjectVelocityPanel(repoPath: contentURL?.path)
            panel.attach(to: window)
            panel.onTitleChange = { [weak window, weak item] title in
                guard let window, let item, !item.userRenamed, !title.isEmpty else { return }
                window.title = title
            }
            panel.onRepoChange = { [weak self] in self?.onPersistableChange?() }
            item.projectVelocity = panel
        case .diff:
            let panel = DiffPanel(repoPath: contentURL?.path)
            panel.attach(to: window)
            panel.onTitleChange = { [weak window, weak item] title in
                guard let window, let item, !item.userRenamed, !title.isEmpty else { return }
                window.title = title
            }
            panel.onRepoChange = { [weak self] in self?.onPersistableChange?() }
            item.diff = panel
        case .assistant:
            // Inherit repo context from a sibling Git widget in the same project, if any.
            let siblingRepo = project.items.lazy.compactMap {
                $0.gitObserver?.repoPath ?? $0.gitGraph?.repoPath ?? $0.projectVelocity?.repoPath
            }.first
            let panel = ClaudePanel(repoPath: contentURL?.path ?? siblingRepo)
            panel.attach(to: window)
            panel.onRepoChange = { [weak self] in self?.onPersistableChange?() }
            item.assistant = panel
        case .onboarding:
            let panel = OnboardingPanel(topSites: topSites)
            panel.onFinish = { [weak self] firstProjectName in self?.finishOnboarding(firstProjectName: firstProjectName) }
            panel.attach(to: window)
            item.onboarding = panel
        case .sticky:
            let color = stickyColor ?? Int.random(in: 0..<StickyPanel.pastels.count)
            let panel = StickyPanel(text: documentText ?? "", colorIndex: color)
            panel.attach(to: window)
            panel.onChange = { [weak self] in self?.onPersistableChange?() }
            if focus { panel.focus() }
            item.sticky = panel
        case .freeText:
            let color = stickyColor ?? Int.random(in: 0..<FreeTextPanel.pastels.count)
            let panel = FreeTextPanel(text: documentText ?? "", colorIndex: color, fontSize: CGFloat(freeTextSize ?? 18))
            panel.attach(to: window)
            panel.onChange = { [weak self] in self?.onPersistableChange?() }
            if focus { panel.focus() }   // new free text opens ready to type
            item.freeText = panel
        case .line:
            let color = stickyColor ?? Int.random(in: 0..<LinePanel.pastels.count)
            // nil → a default placed connector (direct add); [] → empty, the controller sets it via
            // startPath; ≥2 → restored endpoints.
            let startPt: CGPoint?, endPt: CGPoint?
            if let n = lineNodes, n.count >= 2 { startPt = n[0]; endPt = n[1] }
            else if lineNodes == nil { startPt = CGPoint(x: 16, y: 16); endPt = CGPoint(x: 196, y: 116) }
            else { startPt = nil; endPt = nil }
            let panel = LinePanel(colorIndex: color, thickness: CGFloat(lineThickness ?? 2),
                                  arrowStart: lineArrowStart ?? false, arrowEnd: lineArrowEnd ?? false,
                                  start: startPt, end: endPt, bend: CGFloat(lineBend ?? 0.5))
            panel.attach(to: window)
            panel.onChange = { [weak self] in self?.onPersistableChange?() }
            panel.onGeometryEdited = { [weak self, weak item] before, after in
                guard let self else { return }
                self.history.register("Edit Line",
                    undo: { [weak item] in item?.line?.applyGeometry(before) },
                    redo: { [weak item] in item?.line?.applyGeometry(after) })
                self.onPersistableChange?()
            }
            item.line = panel
        }

        // Non-text panels pull keyboard focus to the window when selected (so Delete/Escape act on
        // them); text panels keep focus in their editor.
        let nonTextKinds: Set<WorkItem.Kind> = [.sticky, .freeText, .line, .gitObserver, .gitGraph, .projectVelocity, .diff]
        window.focusable = nonTextKinds.contains(kind)

        project.items.append(item)
        return item
    }

    // MARK: - Selection (canvas / project / item — mutually exclusive)

    func select(_ newSelection: Selection) {
        guard selection != newSelection else { return }
        selection = newSelection
        if case .item(let id) = newSelection { selectedItemIDs = [id] } else { selectedItemIDs = [] }
        applySelectionVisuals()
        onSelectionChange?()
    }

    /// SHIFT-click: add/remove an item from the multi-selection.
    func toggleItemSelection(_ item: WorkItem) {
        if let owner = project(owning: item) { setCurrentProject(owner) }
        if selectedItemIDs.contains(item.id) { selectedItemIDs.remove(item.id) }
        else { selectedItemIDs.insert(item.id) }
        // Keep `selection` pointing at a still-selected item (or none).
        selection = selectedItemIDs.contains(item.id) ? .item(item.id)
            : (selectedItemIDs.first.map { Selection.item($0) } ?? .none)
        applySelectionVisuals()
        onSelectionChange?()
        if let w = item.window, w.focusable { w.window?.makeFirstResponder(w) }
    }

    /// Delete every selected item as a SINGLE undoable step (so one ⌘Z restores them all).
    func deleteSelection() {
        let ids = selectedItemIDs
        // Capture each selected item with its owning project (stable order) before tearing down.
        var captured: [(project: Project, state: ItemState)] = []
        for project in projects {
            for item in project.items where ids.contains(item.id) {
                captured.append((project, makeItemState(item)))
            }
        }
        guard !captured.isEmpty else { return }
        let boxes = captured.map { _ in Box<WorkItem?>(nil) }
        let toRemove = projects.flatMap { $0.items }.filter { ids.contains($0.id) }
        for item in toRemove { performRemoveItem(item) }
        // Drop focus to the canvas (not the window) so ⌘Z routes to app history rather than a stale
        // editor — and crucially keeps the split-view controller in the menu's responder chain.
        canvas.window?.makeFirstResponder(canvas)

        history.register("Delete \(captured.count) item\(captured.count == 1 ? "" : "s")",
            undo: { [weak self] in
                guard let self else { return }
                for (i, c) in captured.enumerated() {
                    boxes[i].value = self.installItem(from: c.state, in: c.project, focus: false)
                }
                self.selectedItemIDs = Set(boxes.compactMap { $0.value?.id })
                self.selection = self.selectedItemIDs.first.map { .item($0) } ?? .none
                self.applySelectionVisuals()
                self.onModelChange?(); self.onSelectionChange?(); self.onPersistableChange?()
            },
            redo: { [weak self] in
                guard let self else { return }
                for box in boxes { if let it = box.value { self.performRemoveItem(it) } }
            })
    }

    func clearSelection() { select(.none) }

    func selectProject(_ project: Project) {
        setCurrentProject(project)
        select(.project(project.id))
    }

    func selectItem(_ item: WorkItem) {
        if let owner = project(owning: item) { setCurrentProject(owner) }
        if item.kind == .document { activeDocumentItem = item }
        select(.item(item.id))
        // Pull keyboard focus off any previously-focused editor so Delete/Escape act on the
        // selection (non-text panels only — text panels keep their editor focused for typing).
        if let w = item.window, w.focusable { w.window?.makeFirstResponder(w) }
    }

    private func setCurrentProject(_ project: Project) {
        guard currentProject !== project else { return }
        currentProject = project
        onCurrentProjectChange?()
        onPersistableChange?()
    }

    private func applySelectionVisuals() {
        switch selection {
        case .none:
            canvas.selectedProjectID = nil
        case .project(let id):
            canvas.selectedProjectID = id
        case .item:
            canvas.selectedProjectID = nil
        }
        for project in projects {
            for item in project.items {
                item.window?.isSelected = selectedItemIDs.contains(item.id)
            }
        }
    }

    // MARK: - Persistence

    /// Serialize a terminal/document item's tabs (nil for browsers, which use `browserTabs`).
    private func tabStates(for item: WorkItem) -> [TabState]? {
        guard let container = item.container else { return nil }
        return container.leaves.map { leaf in
            if let terminal = leaf as? TerminalLeaf {
                return TabState(name: terminal.title, workingDirectory: terminal.panel.currentDirectory)
            } else if let document = leaf as? DocumentLeaf {
                return TabState(name: document.title,
                                filePath: document.panel.model.fileURL?.path,
                                documentText: document.panel.model.text)
            }
            return TabState()
        }
    }

    /// Serialize one item to an `ItemState` (used by snapshot and by undo of a delete).
    func makeItemState(_ item: WorkItem) -> ItemState {
        let kindState: ItemState.Kind
        switch item.kind {
        case .terminal: kindState = .terminal
        case .document: kindState = .document
        case .codeEditor: kindState = .codeEditor
        case .browser: kindState = .browser
        case .gitObserver: kindState = .gitObserver
        case .gitGraph: kindState = .gitGraph
        case .projectVelocity: kindState = .projectVelocity
        case .diff: kindState = .diff
        case .assistant: kindState = .assistant
        case .onboarding: kindState = .onboarding
        case .sticky: kindState = .sticky
        case .freeText: kindState = .freeText
        case .line: kindState = .line
        }
        // Compute the heavy values as typed locals so the ItemState initializer below stays
        // cheap for the Swift type-checker (it otherwise times out on this many `??`/`.map` args).
        let repoPath: String? = [item.gitObserver?.repoPath, item.gitGraph?.repoPath,
                                 item.projectVelocity?.repoPath, item.assistant?.repoPath,
                                 item.codeEditor?.repoPath, item.diff?.repoPath].compactMap { $0 }.first
        let docText: String? = item.sticky?.text ?? item.freeText?.text
        let colorIndex: Int? = item.sticky?.colorIndex ?? item.freeText?.colorIndex ?? item.line?.colorIndex
        let freeTextSize: Double? = item.freeText.map { Double($0.fontSize) }
        let line = item.line
        let lineNodes: [LineNodeState]? = line.map { l in
            [LineNodeState(x: Double(l.startPoint.x), y: Double(l.startPoint.y), hx: 0, hy: 0),
             LineNodeState(x: Double(l.endPoint.x), y: Double(l.endPoint.y), hx: 0, hy: 0)]
        }
        let lineThickness: Double? = line.map { Double($0.thickness) }
        let lineBend: Double? = line.map { Double($0.bend) }
        return ItemState(
            name: item.name,
            kind: kindState,
            frame: item.window?.frame ?? .zero,
            tabs: tabStates(for: item),
            activeTab: item.container?.activeIndex,
            documentText: docText,
            workingDirectory: repoPath,
            renamed: item.userRenamed,
            stickyColor: colorIndex,
            freeTextSize: freeTextSize,
            lineThickness: lineThickness,
            lineArrowStart: line?.hasArrowStart,
            lineArrowEnd: line?.hasArrowEnd,
            lineNodes: lineNodes,
            lineBend: lineBend,
            browserURL: item.browser?.currentURL,
            browserTabs: item.browser?.tabURLs,
            browserActiveTab: item.browser?.activeTabIndex)
    }

    /// Resolve a saved connector's two endpoints, migrating older single-segment saves.
    private func lineEndpoints(from item: ItemState) -> [CGPoint]? {
        if let saved = item.lineNodes, saved.count >= 2 {
            return [CGPoint(x: saved[0].x, y: saved[0].y), CGPoint(x: saved[1].x, y: saved[1].y)]
        }
        if let sx = item.lineStartX, let sy = item.lineStartY, let ex = item.lineEndX, let ey = item.lineEndY {
            return [CGPoint(x: sx, y: sy), CGPoint(x: ex, y: ey)]
        }
        return nil
    }

    /// Rebuild one item from an `ItemState` into a project (used by restore and undo of a delete).
    @discardableResult
    func installItem(from item: ItemState, in project: Project, focus: Bool) -> WorkItem? {
        let kind: WorkItem.Kind
        let contentURL: URL?
        var browserTabs: [String]?
        switch item.kind {
        case .terminal: kind = .terminal; contentURL = nil
        case .document: kind = .document; contentURL = item.filePath.map { URL(fileURLWithPath: $0) }
        case .codeEditor: kind = .codeEditor; contentURL = item.workingDirectory.map { URL(fileURLWithPath: $0) }
        case .figma: return nil   // the Figma app was removed; drop any saved figma windows
        case .files: return nil   // the Files app was removed; drop any saved files windows
        case .gitObserver: kind = .gitObserver; contentURL = item.workingDirectory.map { URL(fileURLWithPath: $0) }
        case .gitGraph: kind = .gitGraph; contentURL = item.workingDirectory.map { URL(fileURLWithPath: $0) }
        case .projectVelocity: kind = .projectVelocity; contentURL = item.workingDirectory.map { URL(fileURLWithPath: $0) }
        case .diff: kind = .diff; contentURL = item.workingDirectory.map { URL(fileURLWithPath: $0) }
        case .assistant: kind = .assistant; contentURL = item.workingDirectory.map { URL(fileURLWithPath: $0) }
        case .onboarding: kind = .onboarding; contentURL = nil
        case .sticky: kind = .sticky; contentURL = nil
        case .freeText: kind = .freeText; contentURL = nil
        case .line: kind = .line; contentURL = nil
        case .browser:
            kind = .browser; contentURL = nil
            browserTabs = item.browserTabs ?? item.browserURL.map { [$0] }
        }
        let created = installItem(in: project, kind: kind, name: item.name, frame: item.frame,
                                  contentURL: contentURL, documentText: item.documentText,
                                  terminalDirectory: item.workingDirectory, focus: focus,
                                  browserTabs: browserTabs, browserActiveTab: item.browserActiveTab ?? 0,
                                  tabStates: item.tabs, tabActive: item.activeTab ?? 0,
                                  stickyColor: item.stickyColor, freeTextSize: item.freeTextSize,
                                  lineThickness: item.lineThickness,
                                  lineArrowStart: item.lineArrowStart, lineArrowEnd: item.lineArrowEnd,
                                  lineNodes: lineEndpoints(from: item), lineBend: item.lineBend)
        created.userRenamed = item.renamed ?? false
        return created
    }

    /// Capture the full workspace as a serializable snapshot.
    func snapshot() -> WorkspaceState {
        var state = WorkspaceState()
        state.version = 4
        state.currentProjectID = currentProject?.id
        state.viewport = viewport
        state.projects = projects.map { project in
            let order = canvas.subviews
            func zIndex(_ item: WorkItem) -> Int {
                guard let w = item.window else { return Int.max }
                return order.firstIndex(of: w) ?? Int.max
            }
            let items = project.items.sorted { zIndex($0) < zIndex($1) }.map { makeItemState($0) }
            // Anchor stays meaningful: content origin for non-empty, the stored anchor otherwise.
            let anchor: CGPoint
            if let first = items.first?.frame {
                anchor = items.dropFirst().reduce(first) { $0.union($1.frame) }.origin
            } else {
                anchor = project.anchor
            }
            return ProjectState(id: project.id, name: project.name, items: items, anchor: anchor,
                                collapsed: project.isCollapsed, colorIndex: project.colorIndex)
        }
        return state
    }

    /// Rebuild the workspace from a snapshot. Called once at launch, before the UI is wired, so
    /// the change callbacks are still nil (no premature saves/reloads).
    func restore(_ state: WorkspaceState) {
        viewport = state.viewport
        for ps in state.projects {
            let project = Project(name: ps.name, id: ps.id, anchor: ps.anchor ?? .zero)
            project.isCollapsed = ps.collapsed ?? false
            project.colorIndex = ps.colorIndex
            projects.append(project)

            for item in ps.items {
                installItem(from: item, in: project, focus: false)
            }
            applyCollapse(project)   // hide windows if the project was collapsed
        }

        if let id = state.currentProjectID {
            currentProject = projects.first { $0.id == id } ?? projects.first
        } else {
            currentProject = projects.first
        }
        if let current = currentProject {
            selection = .project(current.id)
            canvas.selectedProjectID = current.id
        }
    }
}
