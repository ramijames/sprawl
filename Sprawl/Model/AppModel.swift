import AppKit

/// A single item living inside a project: a terminal or a document. Each is backed by a
/// `WindowView` panel on the shared canvas.
final class WorkItem {
    enum Kind {
        case terminal
        case document
        case browser
        case gitObserver
        case gitGraph
        case projectVelocity
        var symbolName: String {
            switch self {
            case .terminal: return "terminal"
            case .document: return "doc.text"
            case .browser: return "globe"
            case .gitObserver: return "chart.bar.xaxis"
            case .gitGraph: return "point.3.connected.trianglepath.dotted"
            case .projectVelocity: return "gauge.with.dots.needle.67percent"
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

    /// Structure changed (project/item added or removed) — sidebar should reload.
    var onModelChange: (() -> Void)?
    /// The current project changed — used only for the toolbar label now (no canvas swap).
    var onCurrentProjectChange: (() -> Void)?
    /// Something worth persisting changed (layout, contents, viewport, …) — request a save.
    var onPersistableChange: (() -> Void)?
    /// Selection changed — drives white-outline visuals (item windows + the selected folder).
    var onSelectionChange: (() -> Void)?

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

    /// Delete a single item — same teardown as closing its window (removes the panel, clears
    /// selection if it was selected, reloads the sidebar, and autosaves).
    func removeItem(_ item: WorkItem) {
        if let window = item.window {
            window.onClose?(window)
        } else if let project = project(owning: item) {
            project.items.removeAll { $0 === item }
            onModelChange?()
            onPersistableChange?()
        }
    }

    /// Delete a whole project and all of its windows.
    func removeProject(_ project: Project) {
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

    /// The currently selected item (white-outlined window), if any.
    var selectedItem: WorkItem? {
        guard case .item(let id) = selection else { return nil }
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
            case .browser: base = "Browser"
            case .gitObserver: base = "Git Observer"
            case .gitGraph: base = "Git Graph"
            case .projectVelocity: base = "Project Velocity"
            }
            let count = project.items.filter { $0.kind == kind }.count + 1
            name = "\(base) \(count)"
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
        return item
    }

    /// Host a popup browser panel (created by WebKit's `createWebViewWith`) as a new item in a
    /// project, so `target="_blank"` / `window.open` open a new browser window.
    func hostBrowser(_ panel: BrowserPanel, in project: Project) {
        if project.isCollapsed { project.isCollapsed = false }
        let count = project.items.filter { $0.kind == .browser }.count + 1
        let item = installItem(in: project, kind: .browser, name: "Browser \(count)",
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
    private func wireContainer(_ container: TabbedContainer, window: WindowView) {
        container.onActiveTitleChange = { [weak window] title in
            guard let window, !title.isEmpty else { return }
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
                             tabActive: Int = 0) -> WorkItem {
        let window = canvas.addWindow(title: name, frame: frame)
        let item = WorkItem(name: name, kind: kind, window: window)
        window.onClose = { [weak self, weak project, weak item] closedWindow in
            guard let self, let project else { return }
            closedWindow.removeFromSuperview()
            project.items.removeAll { $0.window === closedWindow }
            if let item, self.selection == .item(item.id) { self.clearSelection() }
            self.canvas.needsDisplay = true
            self.onModelChange?()
            self.onPersistableChange?()
        }

        switch kind {
        case .terminal:
            let container = TabbedContainer()
            wireContainer(container, window: window)
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
            wireContainer(container, window: window)
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
            panel.onTitleChange = { [weak window] title in
                guard let window, !title.isEmpty else { return }
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
            panel.onTitleChange = { [weak window] title in
                guard let window, !title.isEmpty else { return }
                window.title = title
            }
            panel.onRepoChange = { [weak self] in self?.onPersistableChange?() }
            item.gitObserver = panel
        case .gitGraph:
            let panel = GitGraphPanel(repoPath: contentURL?.path)
            panel.attach(to: window)
            panel.onTitleChange = { [weak window] title in
                guard let window, !title.isEmpty else { return }
                window.title = title
            }
            panel.onRepoChange = { [weak self] in self?.onPersistableChange?() }
            item.gitGraph = panel
        case .projectVelocity:
            let panel = ProjectVelocityPanel(repoPath: contentURL?.path)
            panel.attach(to: window)
            panel.onTitleChange = { [weak window] title in
                guard let window, !title.isEmpty else { return }
                window.title = title
            }
            panel.onRepoChange = { [weak self] in self?.onPersistableChange?() }
            item.projectVelocity = panel
        }

        project.items.append(item)
        return item
    }

    // MARK: - Selection (canvas / project / item — mutually exclusive)

    func select(_ newSelection: Selection) {
        guard selection != newSelection else { return }
        selection = newSelection
        applySelectionVisuals()
        onSelectionChange?()
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
                let isSel: Bool = { if case .item(let id) = selection { return id == item.id }; return false }()
                item.window?.isSelected = isSel
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
            let items = project.items.sorted { zIndex($0) < zIndex($1) }.map { item -> ItemState in
                let kindState: ItemState.Kind
                switch item.kind {
                case .terminal: kindState = .terminal
                case .document: kindState = .document
                case .browser: kindState = .browser
                case .gitObserver: kindState = .gitObserver
                case .gitGraph: kindState = .gitGraph
                case .projectVelocity: kindState = .projectVelocity
                }
                return ItemState(
                    name: item.name,
                    kind: kindState,
                    frame: item.window?.frame ?? .zero,
                    tabs: tabStates(for: item),
                    activeTab: item.container?.activeIndex,
                    workingDirectory: item.gitObserver?.repoPath ?? item.gitGraph?.repoPath ?? item.projectVelocity?.repoPath,
                    browserURL: item.browser?.currentURL,
                    browserTabs: item.browser?.tabURLs,
                    browserActiveTab: item.browser?.activeTabIndex)
            }
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
                let kind: WorkItem.Kind
                let contentURL: URL?
                var browserTabs: [String]?
                switch item.kind {
                case .terminal: kind = .terminal; contentURL = nil
                case .document: kind = .document; contentURL = item.filePath.map { URL(fileURLWithPath: $0) }
                case .files: continue   // the Files app was removed; drop any saved files windows
                case .gitObserver:
                    kind = .gitObserver
                    contentURL = item.workingDirectory.map { URL(fileURLWithPath: $0) }
                case .gitGraph:
                    kind = .gitGraph
                    contentURL = item.workingDirectory.map { URL(fileURLWithPath: $0) }
                case .projectVelocity:
                    kind = .projectVelocity
                    contentURL = item.workingDirectory.map { URL(fileURLWithPath: $0) }
                case .browser:
                    kind = .browser; contentURL = nil
                    // Prefer the full tab list; fall back to the legacy single URL.
                    browserTabs = item.browserTabs ?? item.browserURL.map { [$0] }
                }
                installItem(in: project,
                            kind: kind,
                            name: item.name,
                            frame: item.frame,
                            contentURL: contentURL,
                            documentText: item.documentText,
                            terminalDirectory: item.workingDirectory,
                            focus: false,
                            browserTabs: browserTabs,
                            browserActiveTab: item.browserActiveTab ?? 0,
                            tabStates: item.tabs,   // nil for legacy saves → one tab from the flat fields
                            tabActive: item.activeTab ?? 0)
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
