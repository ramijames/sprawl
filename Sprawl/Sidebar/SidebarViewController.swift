import AppKit

/// The translucent source-list sidebar. Shows each project as a top-level row with its
/// terminals and documents nested underneath. A "+" button at the bottom adds items/projects.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    private let model: AppModel
    private let outlineView = SidebarOutlineView()
    private let cellIdentifier = NSUserInterfaceItemIdentifier("SidebarCell")
    /// True while we're mirroring the canvas selection into the outline — suppresses the outline's
    /// own selection callbacks so syncing doesn't re-trigger a canvas focus (feedback loop).
    private var isSyncingSelection = false

    var onSelectProject: ((Project) -> Void)?
    var onSelectItem: ((WorkItem) -> Void)?
    var onAddItem: ((WorkItem.Kind) -> Void)?
    var onAddProject: (() -> Void)?
    var onOpenDocument: (() -> Void)?
    var onDeleteItem: ((WorkItem) -> Void)?
    var onDeleteProject: ((Project) -> Void)?
    var onRenameItem: ((WorkItem, String) -> Void)?
    var onRenameProject: ((Project, String) -> Void)?

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
        outlineView.onRenameRow = { [weak self] row in self?.beginRenaming(row: row) }

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
        let cell = outlineView.makeView(withIdentifier: cellIdentifier, owner: self) as? SidebarCellView ?? makeCell()

        cell.textField?.textColor = Palette.sidebarText
        cell.imageView?.contentTintColor = Palette.sidebarText
        if let project = item as? Project {
            cell.textField?.stringValue = project.name
            cell.textField?.font = .systemFont(ofSize: 13, weight: .semibold)
            cell.imageView?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            cell.caret.isHidden = false
            cell.setExpanded(outlineView.isItemExpanded(project))
            cell.onToggle = { [weak self, weak cell] in
                guard let self else { return }
                if self.outlineView.isItemExpanded(project) { self.outlineView.collapseItem(project) }
                else { self.outlineView.expandItem(project) }
                cell?.setExpanded(self.outlineView.isItemExpanded(project))
            }
        } else if let work = item as? WorkItem {
            cell.textField?.stringValue = work.name
            cell.textField?.font = .systemFont(ofSize: 12, weight: .regular)
            cell.imageView?.image = NSImage(systemSymbolName: work.kind.symbolName, accessibilityDescription: nil)
            cell.caret.isHidden = true
            cell.onToggle = nil
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SidebarRowView()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }   // ignore selection we set to mirror the canvas
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) else { return }
        if let project = item as? Project {
            onSelectProject?(project)
        } else if let work = item as? WorkItem {
            onSelectItem?(work)
        }
    }

    /// Mirror the canvas selection into the outline (a project highlights its row; an item expands
    /// its project and highlights the item — more specific as you go down the hierarchy).
    func syncSelection(_ selection: AppModel.Selection) {
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        switch selection {
        case .none:
            outlineView.deselectAll(nil)
        case .project(let id):
            guard let project = model.projects.first(where: { $0.id == id }) else { outlineView.deselectAll(nil); return }
            let row = outlineView.row(forItem: project)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
            }
        case .item(let id):
            for project in model.projects where project.items.contains(where: { $0.id == id }) {
                outlineView.expandItem(project)
                if let work = project.items.first(where: { $0.id == id }) {
                    let row = outlineView.row(forItem: work)
                    if row >= 0 {
                        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                        outlineView.scrollRowToVisible(row)
                    }
                }
                return
            }
            outlineView.deselectAll(nil)
        }
    }

    /// Double-click any row (item or project) to rename it inline.
    private func beginRenaming(row: Int) {
        guard row >= 0,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
              let field = cell.textField else { return }
        field.isEditable = true
        outlineView.editColumn(0, row: row, with: nil, select: true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        field.isEditable = false
        let row = outlineView.row(for: field)
        guard row >= 0, let item = outlineView.item(atRow: row) else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let work = item as? WorkItem {
            if newName.isEmpty { field.stringValue = work.name } else { onRenameItem?(work, newName) }
        } else if let project = item as? Project {
            if newName.isEmpty { field.stringValue = project.name } else { onRenameProject?(project, newName) }
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

    private func makeCell() -> SidebarCellView {
        let cell = SidebarCellView()
        cell.identifier = cellIdentifier
        cell.textField?.delegate = self   // commits inline rename (double-click a row)
        return cell
    }
}

/// A sidebar row: a transparent expand/collapse caret (projects only) + icon + editable name.
final class SidebarCellView: NSTableCellView {
    let caret = NSButton()
    var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.isSelectable = true
        text.focusRingType = .none
        text.lineBreakMode = .byTruncatingTail

        caret.isBordered = false
        caret.imagePosition = .imageOnly
        caret.bezelStyle = .inline
        caret.contentTintColor = .secondaryLabelColor
        caret.target = self
        caret.action = #selector(toggle)

        for sub in [caret, icon, text] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        imageView = icon
        textField = text

        NSLayoutConstraint.activate([
            caret.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            caret.centerYAnchor.constraint(equalTo: centerYAnchor),
            caret.widthAnchor.constraint(equalToConstant: 14),
            caret.heightAnchor.constraint(equalToConstant: 14),
            icon.leadingAnchor.constraint(equalTo: caret.trailingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func toggle() { onToggle?() }

    func setExpanded(_ expanded: Bool) {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        caret.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                              accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
}

/// Source-list outline view that reports ⌫ / forward-delete so the selected row can be removed, and
/// routes a double-click to inline rename (consuming it so the row doesn't expand/collapse — that's
/// the caret button's job). The built-in disclosure triangle is hidden in favor of the caret.
final class SidebarOutlineView: NSOutlineView {
    var onDeleteKey: (() -> Void)?
    var onRenameRow: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {   // delete / forward delete
            onDeleteKey?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let row = row(at: convert(event.locationInWindow, from: nil))
            if row >= 0 {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                onRenameRow?(row)
                return   // consume — don't let the default double-click expand/collapse the row
            }
        }
        super.mouseDown(with: event)
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }   // hide built-in triangle
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
