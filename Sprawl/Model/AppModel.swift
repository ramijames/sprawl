import AppKit

/// A single item living inside a project: a terminal or a document. Each is backed by a
/// `WindowView` panel on the shared canvas.
final class WorkItem {
    enum Kind {
        case terminal
        case document
        case browser
        var symbolName: String {
            switch self {
            case .terminal: return "terminal"
            case .document: return "doc.text"
            case .browser: return "globe"
            }
        }
    }

    let id = UUID()
    var name: String
    let kind: Kind
    weak var window: WindowView?
    /// Strong reference so the live terminal stays alive while the item exists.
    var terminal: TerminalPanel?
    /// Strong reference so the editor stays alive while the item exists.
    var document: DocumentPanel?
    /// Strong reference so the web view stays alive while the item exists.
    var browser: BrowserPanel?

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

    func item(for window: WindowView) -> WorkItem? {
        for project in projects {
            if let item = project.items.first(where: { $0.window === window }) { return item }
        }
        return nil
    }

    @discardableResult
    func addItem(kind: WorkItem.Kind, url: URL? = nil) -> WorkItem? {
        guard let project = currentProject else { return nil }

        let name: String
        if kind == .document, let url {
            name = url.lastPathComponent
        } else {
            let base: String
            switch kind {
            case .terminal: base = "Terminal"
            case .document: base = "Document"
            case .browser: base = "Browser"
            }
            let count = project.items.filter { $0.kind == kind }.count + 1
            name = "\(base) \(count)"
        }

        if project.isCollapsed { project.isCollapsed = false }   // adding content expands the folder
        let item = installItem(in: project, kind: kind, name: name,
                               frame: spawnFrame(in: project),
                               contentURL: url, documentText: nil,
                               terminalDirectory: nil, focus: true)
        select(.item(item.id))
        onModelChange?()
        onPersistableChange?()
        return item
    }

    /// Where a new window for a project spawns: cascaded near its existing windows, or at its
    /// anchor when empty, so it joins the project's folder instead of the viewport center.
    private func spawnFrame(in project: Project, size: NSSize = NSSize(width: 460, height: 320)) -> NSRect {
        let frames = project.items.compactMap { $0.window?.frame }
        guard let first = frames.first else {
            return NSRect(origin: project.anchor, size: size)
        }
        let union = frames.dropFirst().reduce(first) { $0.union($1) }
        let step = CGFloat((project.items.count % 6) * 28)
        return NSRect(x: union.minX + step, y: union.minY + step, width: size.width, height: size.height)
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
                             focus: Bool) -> WorkItem {
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
            let panel = TerminalPanel(startDirectory: terminalDirectory)
            panel.attach(to: window)
            panel.onTitleChange = { [weak window] title in
                guard let window, !title.isEmpty else { return }
                window.title = title
            }
            panel.onProcessTerminated = { [weak window] in
                guard let window else { return }
                window.onClose?(window)
            }
            panel.onDirectoryChange = { [weak self] in self?.onPersistableChange?() }
            item.terminal = panel
            if focus { panel.focus() }
        case .document:
            let panel = DocumentPanel(fileURL: contentURL, initialText: documentText)
            panel.attach(to: window)
            panel.onTextChange = { [weak self] in self?.onPersistableChange?() }
            item.document = panel
            activeDocumentItem = item
        case .browser:
            let panel = BrowserPanel(url: contentURL)
            panel.attach(to: window)
            panel.onTitleChange = { [weak window] title in
                guard let window, !title.isEmpty else { return }
                window.title = title
            }
            panel.onURLChange = { [weak self] in self?.onPersistableChange?() }
            item.browser = panel
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

    /// Capture the full workspace as a serializable snapshot.
    func snapshot() -> WorkspaceState {
        var state = WorkspaceState()
        state.version = 2
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
                }
                return ItemState(
                    name: item.name,
                    kind: kindState,
                    frame: item.window?.frame ?? .zero,
                    filePath: item.document?.model.fileURL?.path,
                    documentText: item.document?.model.text,
                    workingDirectory: item.terminal?.currentDirectory,
                    browserURL: item.browser?.currentURL)
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
                switch item.kind {
                case .terminal: kind = .terminal; contentURL = nil
                case .document: kind = .document; contentURL = item.filePath.map { URL(fileURLWithPath: $0) }
                case .browser: kind = .browser; contentURL = item.browserURL.flatMap { URL(string: $0) }
                }
                installItem(in: project,
                            kind: kind,
                            name: item.name,
                            frame: item.frame,
                            contentURL: contentURL,
                            documentText: item.documentText,
                            terminalDirectory: item.workingDirectory,
                            focus: false)
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
