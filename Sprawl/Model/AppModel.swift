import AppKit

/// A single item living inside a project: a terminal or a document. Each is backed by a
/// `WindowView` panel on the project's canvas.
final class WorkItem {
    enum Kind {
        case terminal
        case document
        var symbolName: String {
            switch self {
            case .terminal: return "terminal"
            case .document: return "doc.text"
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

    init(name: String, kind: Kind, window: WindowView? = nil) {
        self.name = name
        self.kind = kind
        self.window = window
    }
}

/// A work canvas. Each project owns its own canvas view (so switching projects swaps the
/// whole surface) and the list of items placed on it.
final class Project {
    let id: UUID
    var name: String
    let canvas: CanvasView
    var items: [WorkItem] = []

    /// Saved viewport (canvas zoom + scroll position), so switching to or relaunching this
    /// project re-frames the canvas exactly as it was left.
    var magnification: CGFloat = 1.0
    var scrollOrigin: CGPoint = .zero
    var hasViewport: Bool = false

    init(name: String, id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.canvas = CanvasView(frame: .zero)
    }
}

/// Top-level app state: the projects and which one is current. Emits change callbacks so the
/// sidebar and canvas stay in sync without tight coupling.
final class AppModel {
    private(set) var projects: [Project] = []
    private(set) var currentProject: Project?
    /// The document most recently created/focused — the target for Save.
    weak var activeDocumentItem: WorkItem?

    /// Structure changed (project/item added or removed) — sidebar should reload.
    var onModelChange: (() -> Void)?
    /// The current project changed — canvas should swap.
    var onCurrentProjectChange: (() -> Void)?
    /// Something worth persisting changed (layout, contents, viewport, …) — request a save.
    var onPersistableChange: (() -> Void)?

    @discardableResult
    func addProject(name: String) -> Project {
        let project = Project(name: name)
        wireCanvas(of: project)
        projects.append(project)
        if currentProject == nil { currentProject = project }
        onModelChange?()
        onPersistableChange?()
        return project
    }

    /// Route a project canvas's layout edits (move/resize/raise/add/close) into autosave.
    private func wireCanvas(of project: Project) {
        project.canvas.onLayoutChange = { [weak self] in self?.onPersistableChange?() }
    }

    func selectProject(_ project: Project) {
        guard currentProject !== project else { return }
        currentProject = project
        onCurrentProjectChange?()
        onPersistableChange?()
    }

    func project(owning item: WorkItem) -> Project? {
        projects.first { $0.items.contains { $0 === item } }
    }

    @discardableResult
    func addItem(kind: WorkItem.Kind, url: URL? = nil) -> WorkItem? {
        guard let project = currentProject else { return nil }

        let name: String
        if kind == .document, let url {
            name = url.lastPathComponent
        } else {
            let base = kind == .terminal ? "Terminal" : "Document"
            let count = project.items.filter { $0.kind == kind }.count + 1
            name = "\(base) \(count)"
        }

        let item = installItem(in: project, kind: kind, name: name, frame: nil,
                               documentURL: url, documentText: nil,
                               terminalDirectory: nil, focus: true)
        onModelChange?()
        onPersistableChange?()
        return item
    }

    /// Builds a panel (terminal or document) on a project's canvas and wires it up. Shared by
    /// `addItem` (new items, cascaded position, focused) and `restore` (saved frame, no focus).
    @discardableResult
    private func installItem(in project: Project,
                             kind: WorkItem.Kind,
                             name: String,
                             frame: NSRect?,
                             documentURL: URL?,
                             documentText: String?,
                             terminalDirectory: String?,
                             focus: Bool) -> WorkItem {
        let window = project.canvas.addWindow(title: name, frame: frame)
        let item = WorkItem(name: name, kind: kind, window: window)
        window.onClose = { [weak self, weak project] closedWindow in
            guard let self, let project else { return }
            closedWindow.removeFromSuperview()
            project.items.removeAll { $0.window === closedWindow }
            project.canvas.needsDisplay = true   // refresh the project boundary frame
            self.onModelChange?()
            self.onPersistableChange?()
        }

        // Track the active document (for Save) whenever its window is focused.
        let previousFocus = window.onFocus
        window.onFocus = { [weak self, weak item] focused in
            previousFocus?(focused)
            if let self, let item, item.kind == .document {
                self.activeDocumentItem = item
            }
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
            let panel = DocumentPanel(fileURL: documentURL, initialText: documentText)
            panel.attach(to: window)
            panel.onTextChange = { [weak self] in self?.onPersistableChange?() }
            item.document = panel
            activeDocumentItem = item
        }

        project.items.append(item)
        return item
    }

    // MARK: - Persistence

    /// Capture the full workspace as a serializable snapshot.
    func snapshot() -> WorkspaceState {
        var state = WorkspaceState()
        state.currentProjectID = currentProject?.id
        state.projects = projects.map { project in
            // Order items back-to-front by their window's z-order in the canvas subviews.
            let order = project.canvas.subviews
            func zIndex(_ item: WorkItem) -> Int {
                guard let w = item.window else { return Int.max }
                return order.firstIndex(of: w) ?? Int.max
            }
            let items = project.items.sorted { zIndex($0) < zIndex($1) }.map { item -> ItemState in
                ItemState(
                    name: item.name,
                    kind: item.kind == .terminal ? .terminal : .document,
                    frame: item.window?.frame ?? .zero,
                    filePath: item.document?.model.fileURL?.path,
                    documentText: item.document?.model.text,
                    workingDirectory: item.terminal?.currentDirectory)
            }
            return ProjectState(
                id: project.id,
                name: project.name,
                items: items,
                magnification: project.magnification,
                scrollOrigin: project.scrollOrigin,
                hasViewport: project.hasViewport)
        }
        return state
    }

    /// Rebuild the workspace from a snapshot. Called once at launch, before the UI is wired,
    /// so the change callbacks are still nil (no premature saves/reloads).
    func restore(_ state: WorkspaceState) {
        for ps in state.projects {
            let project = Project(name: ps.name, id: ps.id)
            project.magnification = ps.magnification
            project.scrollOrigin = ps.scrollOrigin
            project.hasViewport = ps.hasViewport
            wireCanvas(of: project)
            projects.append(project)

            for item in ps.items {
                let url = item.filePath.map { URL(fileURLWithPath: $0) }
                installItem(in: project,
                            kind: item.kind == .terminal ? .terminal : .document,
                            name: item.name,
                            frame: item.frame,
                            documentURL: url,
                            documentText: item.documentText,
                            terminalDirectory: item.workingDirectory,
                            focus: false)
            }
        }

        if let id = state.currentProjectID {
            currentProject = projects.first { $0.id == id } ?? projects.first
        } else {
            currentProject = projects.first
        }
    }
}
