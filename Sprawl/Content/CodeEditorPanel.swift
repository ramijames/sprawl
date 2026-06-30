import AppKit
import SwiftUI
import Combine
import CodeEditSourceEditor
import CodeEditLanguages

/// A node in the repo file tree (a class so `NSOutlineView` can reference it by identity).
final class FileNode {
    var url: URL                // mutable so a rename can update it in place
    let isDirectory: Bool
    var children: [FileNode]?   // nil until first loaded (lazy)
    init(url: URL, isDirectory: Bool) { self.url = url; self.isDirectory = isDirectory }

    /// Directory contents (dirs first, then files; hidden + heavy build dirs skipped), loaded once.
    func loadChildren() -> [FileNode] {
        if let children { return children }
        let skip: Set<String> = [".git", ".DS_Store", "node_modules", ".build", "DerivedData", ".next", "dist"]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let nodes = entries
            .filter { !skip.contains($0.lastPathComponent) }
            .map { FileNode(url: $0, isDirectory: (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
                return $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
            }
        children = nodes
        return nodes
    }
}

/// Backing store for the currently-open file in the code editor. `fileID` bumps on each open so the
/// editor view is rebuilt with the new content (the source editor doesn't reliably reload from an
/// external binding change alone).
final class CodeFileModel: ObservableObject {
    @Published var text: String = ""
    @Published var language: CodeLanguage = .default
    @Published var fileID: Int = 0
    var fileURL: URL?

    func open(url: URL) {
        fileURL = url
        language = CodeLanguage.detectLanguageFrom(url: url)
        text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        fileID += 1
    }
}

/// SwiftUI wrapper around CodeEditSourceEditor with the gutter + syntax highlighting (unlike the
/// plain-text Document editor). Rebuilt per file via `.id` so each selection loads fresh.
struct CodeFileEditorView: View {
    @ObservedObject var model: CodeFileModel
    var body: some View {
        CodeEditorBody(model: model).id(model.fileID)
    }
}

private struct CodeEditorBody: View {
    @ObservedObject var model: CodeFileModel
    @State private var editorState = SourceEditorState()

    var body: some View {
        SourceEditor(
            $model.text,
            language: model.language,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: .endlessDark,
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    wrapLines: false,
                    tabWidth: 4),
                peripherals: .init(showGutter: true, showMinimap: false)
            ),
            state: $editorState)
    }
}

/// A repo-oriented code editor: pick a repository, browse its file tree, and edit files in a native
/// source editor (syntax highlighting + line numbers). Edits autosave to disk.
final class CodeEditorPanel: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    let containerView = NSView()
    private let outline = NSOutlineView()
    private let treeScroll = NSScrollView()
    private let emptyState = NSStackView()
    private let divider = NSView()
    private let editorModel = CodeFileModel()
    private lazy var hostingView = NSHostingView(rootView: CodeFileEditorView(model: editorModel))

    private var rootNodes: [FileNode] = []
    private(set) var repoPath: String?
    private var loadingFile = false
    private var textObserver: AnyCancellable?
    private var saveWork: DispatchWorkItem?

    /// The selected repository changed — request an autosave of the workspace.
    var onRepoChange: (() -> Void)?
    /// The title (repo name) changed — retitle the window.
    var onTitleChange: ((String) -> Void)?

    private static let maxFileBytes = 2_000_000   // skip very large files

    init(repoPath: String?) {
        super.init()
        buildUI()
        // Autosave edits to the open file (debounced; ignore the programmatic load).
        textObserver = editorModel.$text.dropFirst().sink { [weak self] _ in
            guard let self, !self.loadingFile, self.editorModel.fileURL != nil else { return }
            self.scheduleSave()
        }
        if let repoPath, !repoPath.isEmpty {
            selectRepo(URL(fileURLWithPath: repoPath), persist: false)
        }
    }

    func attach(to window: WindowView) { window.setContent(containerView) }
    func focus() { containerView.window?.makeFirstResponder(hostingView) }

    /// Public repository picker (invoked from the options bar / empty state).
    func chooseRepo() { chooseFolder() }

    // MARK: - UI

    private func buildUI() {
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = Palette.editorBackground.cgColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.rowSizeStyle = .small
        outline.indentationPerLevel = 12
        outline.dataSource = self
        outline.delegate = self
        outline.focusRingType = .none
        outline.target = self
        outline.action = #selector(handleClick)              // single click toggles a folder / opens a file
        outline.doubleAction = #selector(handleDoubleClick)  // double click renames
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        treeScroll.documentView = outline
        treeScroll.drawsBackground = false
        treeScroll.hasVerticalScroller = true
        treeScroll.scrollerStyle = .overlay
        treeScroll.autohidesScrollers = true
        treeScroll.translatesAutoresizingMaskIntoConstraints = false

        divider.wantsLayer = true
        divider.layer?.backgroundColor = Palette.panelBorder.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let emptyIcon = NSImageView()
        emptyIcon.image = LucideIcon.image(LucideIcon.code, size: 56, color: NSColor(white: 1, alpha: 0.16))
        let emptyButton = NSButton(title: "Select Repository", target: self, action: #selector(chooseFolder))
        emptyButton.bezelStyle = .rounded
        emptyButton.controlSize = .large
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 16
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.addArrangedSubview(emptyIcon)
        emptyState.addArrangedSubview(emptyButton)

        containerView.addSubview(treeScroll)
        containerView.addSubview(divider)
        containerView.addSubview(hostingView)
        containerView.addSubview(emptyState)

        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),

            treeScroll.topAnchor.constraint(equalTo: containerView.topAnchor),
            treeScroll.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            treeScroll.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            treeScroll.widthAnchor.constraint(equalToConstant: 220),

            divider.leadingAnchor.constraint(equalTo: treeScroll.trailingAnchor),
            divider.topAnchor.constraint(equalTo: containerView.topAnchor),
            divider.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            hostingView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
        updateEmptyState()
    }

    private func updateEmptyState() {
        let hasRepo = repoPath != nil
        emptyState.isHidden = hasRepo
        for view in [treeScroll, divider, hostingView] { view.isHidden = !hasRepo }
    }

    // MARK: - Repository

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder to edit"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.selectRepo(url, persist: true)
        }
    }

    private func selectRepo(_ url: URL, persist: Bool) {
        flushSave()
        repoPath = url.path
        editorModel.fileURL = nil
        rootNodes = FileNode(url: url, isDirectory: true).loadChildren()
        outline.reloadData()
        onTitleChange?(url.lastPathComponent)
        if persist { onRepoChange?() }
        updateEmptyState()
    }

    // MARK: - File tree (NSOutlineView)

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return rootNodes.count }
        return node.isDirectory ? node.loadChildren().count : 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else { return rootNodes[index] }
        return node.loadChildren()[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("FileCell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let iv = NSImageView(); iv.translatesAutoresizingMaskIntoConstraints = false
            let tf = NSTextField(labelWithString: ""); tf.translatesAutoresizingMaskIntoConstraints = false
            tf.font = .systemFont(ofSize: 12); tf.lineBreakMode = .byTruncatingTail
            c.addSubview(iv); c.addSubview(tf); c.imageView = iv; c.textField = tf
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        let icon = NSWorkspace.shared.icon(forFile: node.url.path)
        icon.size = NSSize(width: 16, height: 16)
        cell.imageView?.image = icon
        cell.textField?.stringValue = node.url.lastPathComponent
        return cell
    }

    /// Single click toggles a folder open/closed (every click, even when already selected) or opens
    /// a file. A double-click's first click also fires here; the rename is handled on the second.
    @objc private func handleClick() {
        guard NSApp.currentEvent?.clickCount == 1 else { return }
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode else { return }
        if node.isDirectory {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else {
            openFile(node.url)
        }
    }

    /// Double-click a row → begin inline rename of that file/folder.
    @objc private func handleDoubleClick() {
        if let node = outline.item(atRow: outline.clickedRow) as? FileNode { beginRename(node) }
    }

    private func beginRename(_ node: FileNode) {
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        field.isEditable = true
        field.delegate = self
        outline.editColumn(0, row: row, with: nil, select: true)
    }

    // MARK: - Context menu (right-click a file/folder)

    private var contextNode: FileNode?

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode else { contextNode = nil; return }
        contextNode = node
        let items: [(String, Selector)?] = [
            ("Open in Finder", #selector(ctxRevealInFinder)),
            ("Open in Tab", #selector(ctxOpenInTab)),
            ("Rename", #selector(ctxRename)),
            nil,
            ("Copy Path", #selector(ctxCopyPath)),
            ("Copy Relative Path", #selector(ctxCopyRelativePath)),
            nil,
            ("Delete", #selector(ctxDelete)),
        ]
        for entry in items {
            guard let (title, action) = entry else { menu.addItem(.separator()); continue }
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
    }

    @objc private func ctxRevealInFinder() {
        guard let node = contextNode else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }
    @objc private func ctxOpenInTab() {
        guard let node = contextNode, !node.isDirectory else { return }
        openFile(node.url)
    }
    @objc private func ctxRename() {
        guard let node = contextNode else { return }
        beginRename(node)
    }
    @objc private func ctxCopyPath() {
        guard let node = contextNode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url.path, forType: .string)
    }
    @objc private func ctxCopyRelativePath() {
        guard let node = contextNode else { return }
        let full = node.url.path
        let rel: String
        if let repoPath, full.hasPrefix(repoPath + "/") { rel = String(full.dropFirst(repoPath.count + 1)) }
        else { rel = node.url.lastPathComponent }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rel, forType: .string)
    }
    @objc private func ctxDelete() {
        guard let node = contextNode else { return }
        do { try FileManager.default.trashItem(at: node.url, resultingItemURL: nil) } catch { NSSound.beep(); return }
        if let parent = outline.parent(forItem: node) as? FileNode {
            parent.children?.removeAll { $0 === node }
            outline.reloadItem(parent, reloadChildren: true)
        } else {
            rootNodes.removeAll { $0 === node }
            outline.reloadData()
        }
        if editorModel.fileURL == node.url { editorModel.fileURL = nil }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        field.isEditable = false
        let row = outline.row(for: field)
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != node.url.lastPathComponent else {
            field.stringValue = node.url.lastPathComponent   // revert empty / unchanged
            return
        }
        let dest = node.url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: node.url, to: dest)
        } catch {
            field.stringValue = node.url.lastPathComponent   // revert on failure (e.g. name exists)
            return
        }
        let old = node.url
        node.url = dest
        if node.isDirectory {
            node.children = nil   // child paths are now stale; reload on next expand
            outline.collapseItem(node)
        }
        if editorModel.fileURL == old { editorModel.fileURL = dest }   // keep autosave targeting the file
        outline.reloadItem(node)
    }

    // MARK: - File open / save

    private func openFile(_ url: URL) {
        flushSave()   // commit the previously-open file first
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= Self.maxFileBytes, (try? String(contentsOf: url, encoding: .utf8)) != nil else {
            return   // skip binaries / very large files
        }
        loadingFile = true
        editorModel.open(url: url)
        loadingFile = false
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushSave() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func flushSave() {
        saveWork?.cancel(); saveWork = nil
        guard let url = editorModel.fileURL else { return }
        try? editorModel.text.write(to: url, atomically: true, encoding: .utf8)
    }
}
