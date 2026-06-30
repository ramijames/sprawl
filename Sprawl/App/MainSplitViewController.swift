import AppKit

/// Composes the translucent sidebar and the canvas, and wires the model's change callbacks.
/// Also serves as the responder-chain target for the app's menu/toolbar actions.
final class MainSplitViewController: NSSplitViewController {
    let model: AppModel
    private let sidebarVC: SidebarViewController
    private let canvasVC: CanvasViewController
    private let dock = FloatingDock(frame: .zero)

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

        // A restored workspace already has projects; only seed a default on a truly fresh launch.
        let isFreshLaunch = model.projects.isEmpty
        if isFreshLaunch {
            model.addProject(name: "Project 1")
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

    /// The floating bottom-center dock: new project, and new windows in the focused project.
    private func installDock() {
        dock.onNewProject = { [weak self] in self?.newProject(nil) }
        dock.onNewTerminal = { [weak self] in self?.newItemFromDock(.terminal) }
        dock.onNewDocument = { [weak self] in self?.newItemFromDock(.document) }
        dock.onNewBrowser = { [weak self] in self?.newItemFromDock(.browser) }
        dock.onNewGitObserver = { [weak self] in self?.newItemFromDock(.gitObserver) }
        dock.onNewGitGraph = { [weak self] in self?.newItemFromDock(.gitGraph) }
        dock.onNewProjectVelocity = { [weak self] in self?.newItemFromDock(.projectVelocity) }
        canvasVC.addBottomOverlay(dock)
    }

    /// Create an item in the focused project and pan the canvas to it (dock affordance).
    private func newItemFromDock(_ kind: WorkItem.Kind) {
        guard let item = model.addItem(kind: kind) else { return }
        canvasVC.centerOnItem(item)
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
        sidebarVC.onAddItem = { [weak self] kind in self?.model.addItem(kind: kind) }
        sidebarVC.onAddProject = { [weak self] in self?.newProject(nil) }
        sidebarVC.onOpenDocument = { [weak self] in self?.openDocument(nil) }

        canvasVC.onViewportChange = { [weak self] in self?.model.onPersistableChange?() }
    }

    // MARK: - Menu / toolbar actions (reached through the responder chain or directly)

    @objc func newTerminal(_ sender: Any?) { model.addItem(kind: .terminal) }
    @objc func newDocument(_ sender: Any?) { model.addItem(kind: .document) }
    @objc func newBrowser(_ sender: Any?) { model.addItem(kind: .browser) }
    @objc func newGitObserver(_ sender: Any?) { model.addItem(kind: .gitObserver) }
    @objc func newGitGraph(_ sender: Any?) { model.addItem(kind: .gitGraph) }
    @objc func newProjectVelocity(_ sender: Any?) { model.addItem(kind: .projectVelocity) }

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
