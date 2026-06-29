import AppKit

/// The translucent source-list sidebar. Shows each project as a top-level row with its
/// terminals and documents nested underneath. A "+" button at the bottom adds items/projects.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let model: AppModel
    private let outlineView = SidebarOutlineView()
    private let cellIdentifier = NSUserInterfaceItemIdentifier("SidebarCell")

    var onSelectProject: ((Project) -> Void)?
    var onSelectItem: ((WorkItem) -> Void)?
    var onAddItem: ((WorkItem.Kind) -> Void)?
    var onAddProject: (() -> Void)?
    var onOpenDocument: (() -> Void)?
    var onDeleteItem: ((WorkItem) -> Void)?
    var onDeleteProject: ((Project) -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        view = NSView()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.indentationPerLevel = 14
        outlineView.rowSizeStyle = .default
        outlineView.style = .sourceList
        outlineView.backgroundColor = .clear
        outlineView.floatsGroupRows = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.autoresizesOutlineColumn = true
        outlineView.onDeleteKey = { [weak self] in self?.deleteSelection() }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = outlineView

        let bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton()
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")
        addButton.imagePosition = .imageOnly
        addButton.isBordered = false
        addButton.bezelStyle = .smallSquare
        addButton.target = self
        addButton.action = #selector(addButtonClicked)
        bottomBar.addSubview(addButton)

        view.addSubview(scrollView)
        view.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 30),

            addButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 8),
            addButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 24),
            addButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    func reload() {
        outlineView.reloadData()
        for project in model.projects {
            outlineView.expandItem(project)
        }
    }

    // MARK: - Add menu

    @objc private func addButtonClicked(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Terminal", action: #selector(menuNewTerminal), keyEquivalent: "")
        menu.addItem(withTitle: "New Document", action: #selector(menuNewDocument), keyEquivalent: "")
        menu.addItem(withTitle: "New Browser", action: #selector(menuNewBrowser), keyEquivalent: "")
        menu.addItem(withTitle: "Open File…", action: #selector(menuOpenFile), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "New Project", action: #selector(menuNewProject), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func menuNewTerminal() { onAddItem?(.terminal) }
    @objc private func menuNewDocument() { onAddItem?(.document) }
    @objc private func menuNewBrowser() { onAddItem?(.browser) }
    @objc private func menuOpenFile() { onOpenDocument?() }
    @objc private func menuNewProject() { onAddProject?() }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return model.projects.count }
        if let project = item as? Project { return project.items.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return model.projects[index] }
        if let project = item as? Project { return project.items[index] }
        fatalError("Unexpected outline item")
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Project
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = outlineView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView
            ?? makeCell()

        cell.textField?.textColor = Palette.sidebarText
        cell.imageView?.contentTintColor = Palette.sidebarText
        if let project = item as? Project {
            cell.textField?.stringValue = project.name
            cell.textField?.font = .systemFont(ofSize: 13, weight: .semibold)
            cell.imageView?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        } else if let work = item as? WorkItem {
            cell.textField?.stringValue = work.name
            cell.textField?.font = .systemFont(ofSize: 12, weight: .regular)
            cell.imageView?.image = NSImage(systemSymbolName: work.kind.symbolName, accessibilityDescription: nil)
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SidebarRowView()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) else { return }
        if let project = item as? Project {
            onSelectProject?(project)
        } else if let work = item as? WorkItem {
            onSelectItem?(work)
        }
    }

    /// Delete the selected row (a project and its windows, or a single item) — ⌫ on the sidebar.
    private func deleteSelection() {
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) else { return }
        if let project = item as? Project {
            onDeleteProject?(project)
        } else if let work = item as? WorkItem {
            onDeleteItem?(work)
        }
    }

    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = cellIdentifier

        let imageView = NSImageView()
        let textField = NSTextField(labelWithString: "")
        imageView.translatesAutoresizingMaskIntoConstraints = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.imageView = imageView
        cell.textField = textField

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// Source-list outline view that reports ⌫ / forward-delete so the selected row can be removed.
final class SidebarOutlineView: NSOutlineView {
    var onDeleteKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {   // delete / forward delete
            onDeleteKey?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Draws an identical rounded selection highlight for every row regardless of nesting level,
/// so projects and their items look consistent when selected.
final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let rect = bounds.insetBy(dx: 6, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        if isEmphasized {
            NSColor.controlAccentColor.setFill()
        } else {
            NSColor(white: 1.0, alpha: 0.12).setFill()
        }
        path.fill()
    }
}
