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
    /// Set when a file is opened from a search hit — the editor scrolls to this line once built.
    var jumpLine: Int?
    lazy var jumpCoordinator = JumpCoordinator(model: self)

    func open(url: URL, line: Int? = nil) {
        fileURL = url
        language = CodeLanguage.detectLanguageFrom(url: url)
        text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        jumpLine = line
        fileID += 1
    }
}

/// Scrolls the freshly-built editor to `model.jumpLine` (set when opening from a search result). The
/// editor is rebuilt per file via `.id`, so `prepareCoordinator` fires once per opened file.
final class JumpCoordinator: TextViewCoordinator {
    private weak var model: CodeFileModel?
    init(model: CodeFileModel) { self.model = model }
    func prepareCoordinator(controller: TextViewController) {
        guard let line = model?.jumpLine, line > 0 else { return }
        model?.jumpLine = nil
        DispatchQueue.main.async { [weak controller] in
            controller?.setCursorPositions([CursorPosition(line: line, column: 1)], scrollToVisible: true)
        }
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
            state: $editorState,
            coordinators: [model.jumpCoordinator])
    }
}

/// A repo-oriented code editor: pick a repository, browse its file tree, and edit files in a native
/// source editor (syntax highlighting + line numbers). Edits autosave to disk.
final class CodeEditorPanel: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate,
                             NSMenuDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum Mode { case explorer, search }

    let containerView = NSView()
    private let outline = NSOutlineView()
    private let treeScroll = NSScrollView()
    private let emptyState = NSStackView()
    private let divider = NSView()

    // Activity bar (left icon rail) + the swappable left panel (Explorer / Search).
    private let activityBar = NSView()
    private let panelContainer = NSView()
    private var explorerButton: NSButton?
    private var searchButton: NSButton?
    private var mode: Mode = .explorer

    // Search panel.
    private let searchPane = NSView()
    private let searchField = NSTextField()
    private let replaceField = NSTextField()
    private let caseButton = NSButton()    // match case
    private let wordButton = NSButton()    // whole word
    private let regexButton = NSButton()   // regular expression
    private let replaceAllButton = NSButton()
    private let searchTable = NSTableView()
    private let searchScroll = NSScrollView()
    private struct SearchHit { let url: URL; let line: Int; let text: String }
    private var searchResults: [SearchHit] = []
    private let editorModel = CodeFileModel()
    private lazy var hostingView = NSHostingView(rootView: CodeFileEditorView(model: editorModel))

    private var rootNodes: [FileNode] = []
    private(set) var repoPath: String?
    private var gitStatus: [String: (letter: String, color: NSColor)] = [:]   // repo-relative path → status
    private var loadingFile = false

    private static let modifiedColor = NSColor(srgbRed: 0.89, green: 0.75, blue: 0.55, alpha: 1)   // yellow
    private static let addedColor = NSColor(srgbRed: 0.45, green: 0.78, blue: 0.57, alpha: 1)       // green
    private static let deletedColor = NSColor(srgbRed: 0.86, green: 0.46, blue: 0.46, alpha: 1)     // red
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

        buildActivityBar()
        buildSearchPane()

        // The left panel container hosts either the Explorer tree or the Search pane.
        panelContainer.translatesAutoresizingMaskIntoConstraints = false
        panelContainer.addSubview(treeScroll)
        panelContainer.addSubview(searchPane)
        for v in [treeScroll, searchPane] {
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: panelContainer.topAnchor),
                v.bottomAnchor.constraint(equalTo: panelContainer.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: panelContainer.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: panelContainer.trailingAnchor),
            ])
        }

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

        containerView.addSubview(activityBar)
        containerView.addSubview(panelContainer)
        containerView.addSubview(divider)
        containerView.addSubview(hostingView)
        containerView.addSubview(emptyState)

        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),

            activityBar.topAnchor.constraint(equalTo: containerView.topAnchor),
            activityBar.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            activityBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            activityBar.widthAnchor.constraint(equalToConstant: 44),

            panelContainer.topAnchor.constraint(equalTo: containerView.topAnchor),
            panelContainer.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            panelContainer.leadingAnchor.constraint(equalTo: activityBar.trailingAnchor),
            panelContainer.widthAnchor.constraint(equalToConstant: 220),

            divider.leadingAnchor.constraint(equalTo: panelContainer.trailingAnchor),
            divider.topAnchor.constraint(equalTo: containerView.topAnchor),
            divider.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            hostingView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
        setMode(.explorer)
        updateEmptyState()
    }

    private func updateEmptyState() {
        let hasRepo = repoPath != nil
        emptyState.isHidden = hasRepo
        for view in [activityBar, panelContainer, divider, hostingView] { view.isHidden = !hasRepo }
    }

    // MARK: - Activity bar + Search

    private func buildActivityBar() {
        activityBar.wantsLayer = true
        activityBar.layer?.backgroundColor = NSColor(white: 0, alpha: 0.18).cgColor
        activityBar.translatesAutoresizingMaskIntoConstraints = false

        func barButton(_ symbol: String, _ tip: String, action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                             target: self, action: action)
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.toolTip = tip
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 36).isActive = true
            b.heightAnchor.constraint(equalToConstant: 36).isActive = true
            return b
        }
        let explorer = barButton("doc.on.doc", "Explorer", action: #selector(showExplorer))
        let search = barButton("magnifyingglass", "Search", action: #selector(showSearch))
        explorerButton = explorer
        searchButton = search
        let stack = NSStackView(views: [explorer, search])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        activityBar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: activityBar.topAnchor, constant: 8),
            stack.centerXAnchor.constraint(equalTo: activityBar.centerXAnchor),
        ])
        updateActivityHighlight()
    }

    private func buildSearchPane() {
        searchPane.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(runSearch)   // fires on Enter

        replaceField.placeholderString = "Replace"
        replaceField.translatesAutoresizingMaskIntoConstraints = false
        replaceField.target = self
        replaceField.action = #selector(replaceAll)   // Enter in the replace field replaces all

        func configToggle(_ b: NSButton, _ title: String, _ tip: String) {
            b.title = title
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .smallSquare
            b.font = .systemFont(ofSize: 10, weight: .medium)
            b.toolTip = tip
            b.target = self
            b.action = #selector(runSearch)   // toggling re-runs the search
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        }
        configToggle(caseButton, "Aa", "Match case")
        configToggle(wordButton, "W", "Whole word")
        configToggle(regexButton, ".*", "Regular expression")
        let toggles = NSStackView(views: [caseButton, wordButton, regexButton])
        toggles.orientation = .horizontal
        toggles.spacing = 4
        toggles.translatesAutoresizingMaskIntoConstraints = false

        replaceAllButton.title = "Replace All"
        replaceAllButton.bezelStyle = .rounded
        replaceAllButton.controlSize = .small
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAll)
        replaceAllButton.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hit"))
        col.resizingMask = .autoresizingMask
        searchTable.addTableColumn(col)
        searchTable.headerView = nil
        searchTable.backgroundColor = .clear
        searchTable.rowHeight = 34
        searchTable.dataSource = self
        searchTable.delegate = self
        searchTable.target = self
        searchTable.action = #selector(searchResultClicked)
        searchTable.focusRingType = .none
        searchScroll.documentView = searchTable
        searchScroll.drawsBackground = false
        searchScroll.hasVerticalScroller = true
        searchScroll.scrollerStyle = .overlay
        searchScroll.translatesAutoresizingMaskIntoConstraints = false

        for v in [searchField, toggles, replaceField, replaceAllButton, searchScroll] { searchPane.addSubview(v) }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: searchPane.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: searchPane.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchPane.trailingAnchor, constant: -8),

            toggles.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            toggles.leadingAnchor.constraint(equalTo: searchPane.leadingAnchor, constant: 8),

            replaceField.topAnchor.constraint(equalTo: toggles.bottomAnchor, constant: 8),
            replaceField.leadingAnchor.constraint(equalTo: searchPane.leadingAnchor, constant: 8),
            replaceField.trailingAnchor.constraint(equalTo: searchPane.trailingAnchor, constant: -8),

            replaceAllButton.topAnchor.constraint(equalTo: replaceField.bottomAnchor, constant: 6),
            replaceAllButton.trailingAnchor.constraint(equalTo: searchPane.trailingAnchor, constant: -8),

            searchScroll.topAnchor.constraint(equalTo: replaceAllButton.bottomAnchor, constant: 8),
            searchScroll.leadingAnchor.constraint(equalTo: searchPane.leadingAnchor),
            searchScroll.trailingAnchor.constraint(equalTo: searchPane.trailingAnchor),
            searchScroll.bottomAnchor.constraint(equalTo: searchPane.bottomAnchor),
        ])
    }

    @objc private func showExplorer() { setMode(.explorer) }
    @objc private func showSearch() { setMode(.search); searchPane.window?.makeFirstResponder(searchField) }

    private func setMode(_ m: Mode) {
        mode = m
        treeScroll.isHidden = m != .explorer
        searchPane.isHidden = m != .search
        updateActivityHighlight()
    }

    private func updateActivityHighlight() {
        explorerButton?.contentTintColor = mode == .explorer ? .controlAccentColor : .secondaryLabelColor
        searchButton?.contentTintColor = mode == .search ? .controlAccentColor : .secondaryLabelColor
    }

    // MARK: - Search (find across the repo)

    private static let searchSkip: Set<String> =
        [".git", ".DS_Store", "node_modules", ".build", "DerivedData", ".next", "dist"]

    /// Build the matcher for the current query + toggle state (plain / whole-word / regex, case).
    private func currentRegex() -> NSRegularExpression? {
        let query = searchField.stringValue
        guard !query.isEmpty else { return nil }
        var pattern = regexButton.state == .on ? query : NSRegularExpression.escapedPattern(for: query)
        if wordButton.state == .on { pattern = "\\b\(pattern)\\b" }
        let opts: NSRegularExpression.Options = caseButton.state == .on ? [] : [.caseInsensitive]
        return try? NSRegularExpression(pattern: pattern, options: opts)
    }

    @objc private func runSearch() {
        guard let repoPath, let regex = currentRegex() else {
            searchResults = []; searchTable.reloadData(); return
        }
        let root = URL(fileURLWithPath: repoPath)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hits = CodeEditorPanel.search(regex: regex, in: root)
            DispatchQueue.main.async {
                guard let self else { return }
                self.searchResults = hits
                self.searchTable.reloadData()
            }
        }
    }

    /// Search across the repo's text files for lines matching `regex` (capped for responsiveness).
    private static func search(regex: NSRegularExpression, in root: URL) -> [SearchHit] {
        var hits: [SearchHit] = []
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in en {
            if searchSkip.contains(url.lastPathComponent) { en.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= 2_000_000, let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var lineNo = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                lineNo += 1
                let s = String(line)
                if regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
                    hits.append(SearchHit(url: url, line: lineNo, text: s.trimmingCharacters(in: .whitespaces)))
                    if hits.count >= 500 { return hits }
                }
            }
        }
        return hits
    }

    /// Replace every match of the current query with the Replace field's text across the repo, then
    /// re-run the search. In regex mode the replacement is a template ($1, …); otherwise it's literal.
    @objc private func replaceAll() {
        guard let repoPath, let regex = currentRegex() else { return }
        let raw = replaceField.stringValue
        let template = regexButton.state == .on ? raw : NSRegularExpression.escapedTemplate(for: raw)
        let root = URL(fileURLWithPath: repoPath)
        let openPath = editorModel.fileURL?.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return }
            for case let url as URL in en {
                if CodeEditorPanel.searchSkip.contains(url.lastPathComponent) { en.skipDescendants(); continue }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                guard size <= 2_000_000, let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let updated = regex.stringByReplacingMatches(
                    in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
                if updated != text { try? updated.write(to: url, atomically: true, encoding: .utf8) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                // The open file may have changed on disk — reload it (don't flushSave; that would clobber).
                if let openPath { self.editorModel.open(url: URL(fileURLWithPath: openPath)) }
                self.loadGitStatus()
                self.runSearch()
            }
        }
    }

    @objc private func searchResultClicked() {
        let row = searchTable.clickedRow >= 0 ? searchTable.clickedRow : searchTable.selectedRow
        guard searchResults.indices.contains(row) else { return }
        let hit = searchResults[row]
        openFile(hit.url, line: hit.line)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { searchResults.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let hit = searchResults[row]
        let id = NSUserInterfaceItemIdentifier("SearchHitCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView(); c.identifier = id
            let loc = NSTextField(labelWithString: ""); loc.translatesAutoresizingMaskIntoConstraints = false
            loc.font = .systemFont(ofSize: 10); loc.textColor = .secondaryLabelColor
            loc.lineBreakMode = .byTruncatingHead; loc.tag = 1
            let txt = NSTextField(labelWithString: ""); txt.translatesAutoresizingMaskIntoConstraints = false
            txt.font = .monospacedSystemFont(ofSize: 11, weight: .regular); txt.lineBreakMode = .byTruncatingTail
            c.addSubview(loc); c.addSubview(txt); c.textField = txt
            NSLayoutConstraint.activate([
                loc.topAnchor.constraint(equalTo: c.topAnchor, constant: 3),
                loc.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8),
                loc.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8),
                txt.topAnchor.constraint(equalTo: loc.bottomAnchor, constant: 1),
                txt.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8),
                txt.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8),
            ])
            return c
        }()
        let rel: String
        if let repoPath, hit.url.path.hasPrefix(repoPath + "/") { rel = String(hit.url.path.dropFirst(repoPath.count + 1)) }
        else { rel = hit.url.lastPathComponent }
        (cell.viewWithTag(1) as? NSTextField)?.stringValue = "\(rel):\(hit.line)"
        cell.textField?.stringValue = hit.text
        return cell
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
        loadGitStatus()
    }

    // MARK: - Git status (decorates the tree like VS Code)

    private func loadGitStatus() {
        guard let path = repoPath else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let raw = CodeEditorPanel.git(path, ["status", "--porcelain"])
            var map: [String: (letter: String, color: NSColor)] = [:]
            for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
                let s = String(line)
                guard s.count > 3 else { continue }
                let code = s.prefix(2)
                var rel = String(s.dropFirst(3))
                if let arrow = rel.range(of: " -> ") { rel = String(rel[arrow.upperBound...]) }   // rename → new path
                rel = rel.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if code.contains("?") { map[rel] = ("U", CodeEditorPanel.addedColor) }
                else if code.contains("A") { map[rel] = ("A", CodeEditorPanel.addedColor) }
                else if code.contains("D") { map[rel] = ("D", CodeEditorPanel.deletedColor) }
                else if code.contains("R") { map[rel] = ("R", CodeEditorPanel.modifiedColor) }
                else { map[rel] = ("M", CodeEditorPanel.modifiedColor) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.gitStatus = map
                self.outline.reloadData()
            }
        }
    }

    /// Status for a node: a file's own status, or a "modified" tint for a folder that contains changes.
    private func statusForNode(_ node: FileNode) -> (letter: String, color: NSColor)? {
        guard let repoPath, node.url.path.hasPrefix(repoPath + "/") else { return nil }
        let rel = String(node.url.path.dropFirst(repoPath.count + 1))
        if node.isDirectory {
            return gitStatus.keys.contains { $0 == rel || $0.hasPrefix(rel + "/") }
                ? ("", CodeEditorPanel.modifiedColor) : nil
        }
        return gitStatus[rel]
    }

    private static func git(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
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
            let st = NSTextField(labelWithString: ""); st.translatesAutoresizingMaskIntoConstraints = false
            st.font = .systemFont(ofSize: 11, weight: .semibold); st.tag = 99
            st.setContentHuggingPriority(.required, for: .horizontal)
            st.setContentCompressionResistancePriority(.required, for: .horizontal)
            c.addSubview(iv); c.addSubview(tf); c.addSubview(st); c.imageView = iv; c.textField = tf
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                tf.trailingAnchor.constraint(lessThanOrEqualTo: st.leadingAnchor, constant: -6),
                st.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8),
                st.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        let icon = NSWorkspace.shared.icon(forFile: node.url.path)
        icon.size = NSSize(width: 16, height: 16)
        cell.imageView?.image = icon
        cell.textField?.stringValue = node.url.lastPathComponent
        // Colour the name + show a git status letter (VS Code style) when the file/folder has changes.
        let status = statusForNode(node)
        cell.textField?.textColor = status?.color ?? .labelColor
        if let st = cell.viewWithTag(99) as? NSTextField {
            st.stringValue = status?.letter ?? ""
            st.textColor = status?.color ?? .secondaryLabelColor
        }
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

    private func openFile(_ url: URL, line: Int? = nil) {
        flushSave()   // commit the previously-open file first
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= Self.maxFileBytes, (try? String(contentsOf: url, encoding: .utf8)) != nil else {
            return   // skip binaries / very large files
        }
        loadingFile = true
        editorModel.open(url: url, line: line)
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
        loadGitStatus()   // the file may now be modified — refresh the tree decorations
    }
}
