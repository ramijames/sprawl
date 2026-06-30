import AppKit

/// One rendered diff row.
struct DiffLine {
    enum Kind { case context, addition, deletion, hunk, fileHeader, meta }
    var kind: Kind
    var oldNum: Int?
    var newNum: Int?
    var text: String
}

/// A single changed file's diff (its name, +/- counts, and the rows to render).
struct ChangedFile {
    let name: String
    let adds: Int
    let dels: Int
    var lines: [DiffLine]
}

/// Shows the repository's uncommitted changes (`git diff HEAD`): a changed-files list on the left
/// and, for the selected file, a GitHub-style unified diff (hunks + red/green rows with line numbers)
/// on the right.
final class DiffPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let containerView = NSView()
    private let topBar = NSView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()
    private let filesTable = NSTableView()
    private let filesScroll = NSScrollView()
    private let divider = NSView()
    private let diffScroll = NSScrollView()
    private let splitView = SplitDiffView()
    private let emptyState = NSStackView()

    private var files: [ChangedFile] = []
    private(set) var repoPath: String?
    var onRepoChange: (() -> Void)?
    var onTitleChange: ((String) -> Void)?

    init(repoPath: String?) {
        super.init()
        buildUI()
        if let repoPath, !repoPath.isEmpty {
            selectRepo(URL(fileURLWithPath: repoPath), persist: false)
        }
    }

    func attach(to window: WindowView) { window.setContent(containerView) }
    func focus() { containerView.window?.makeFirstResponder(filesTable) }
    func chooseRepo() { chooseFolder() }

    // MARK: - UI

    private func buildUI() {
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = Palette.panelBody.cgColor

        topBar.wantsLayer = true
        topBar.layer?.backgroundColor = Palette.panelBody.cgColor
        topBar.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.bezelStyle = .texturedRounded
        refreshButton.imagePosition = .imageOnly
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.toolTip = "Refresh diff"
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        topBar.addSubview(summaryLabel)
        topBar.addSubview(refreshButton)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        filesTable.addTableColumn(column)
        filesTable.headerView = nil
        filesTable.backgroundColor = .clear
        filesTable.rowHeight = 24
        filesTable.dataSource = self
        filesTable.delegate = self
        filesTable.focusRingType = .none
        filesScroll.documentView = filesTable
        filesScroll.drawsBackground = false
        filesScroll.hasVerticalScroller = true
        filesScroll.scrollerStyle = .overlay
        filesScroll.autohidesScrollers = true
        filesScroll.translatesAutoresizingMaskIntoConstraints = false

        divider.wantsLayer = true
        divider.layer?.backgroundColor = Palette.panelBorder.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        splitView.translatesAutoresizingMaskIntoConstraints = false
        diffScroll.documentView = splitView
        diffScroll.drawsBackground = false
        diffScroll.hasVerticalScroller = true
        diffScroll.hasHorizontalScroller = false   // lines wrap within each column
        diffScroll.scrollerStyle = .overlay
        diffScroll.autohidesScrollers = true
        diffScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: diffScroll.contentView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: diffScroll.contentView.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: diffScroll.contentView.topAnchor),
        ])

        let emptyIcon = NSImageView()
        emptyIcon.image = LucideIcon.image(LucideIcon.diff, size: 56, color: NSColor(white: 1, alpha: 0.16))
        let emptyButton = NSButton(title: "Select Repository", target: self, action: #selector(chooseFolder))
        emptyButton.bezelStyle = .rounded
        emptyButton.controlSize = .large
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 16
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.addArrangedSubview(emptyIcon)
        emptyState.addArrangedSubview(emptyButton)

        containerView.addSubview(topBar)
        containerView.addSubview(filesScroll)
        containerView.addSubview(divider)
        containerView.addSubview(diffScroll)
        containerView.addSubview(emptyState)

        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),

            topBar.topAnchor.constraint(equalTo: containerView.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 34),
            summaryLabel.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 12),
            summaryLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -10),
            refreshButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: refreshButton.leadingAnchor, constant: -8),

            filesScroll.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            filesScroll.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            filesScroll.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            filesScroll.widthAnchor.constraint(equalToConstant: 230),

            divider.leadingAnchor.constraint(equalTo: filesScroll.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            divider.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            diffScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            diffScroll.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            diffScroll.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            diffScroll.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
        updateEmptyState()
    }

    private func updateEmptyState() {
        let hasRepo = repoPath != nil
        emptyState.isHidden = hasRepo
        for view in [topBar, filesScroll, divider, diffScroll] { view.isHidden = !hasRepo }
    }

    // MARK: - Repository

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder containing a git repository"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.selectRepo(url, persist: true)
        }
    }

    private func selectRepo(_ url: URL, persist: Bool) {
        repoPath = url.path
        onTitleChange?(url.lastPathComponent)
        if persist { onRepoChange?() }
        updateEmptyState()
        reload()
    }

    @objc private func refreshTapped() { reload() }

    func reload() {
        guard let path = repoPath else { return }
        summaryLabel.stringValue = "Loading…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let raw = DiffPanel.git(path, ["diff", "HEAD"])
            let parsed = DiffPanel.parse(raw)
            DispatchQueue.main.async {
                guard let self else { return }
                self.files = parsed.files
                self.filesTable.reloadData()
                let adds = parsed.files.reduce(0) { $0 + $1.adds }
                let dels = parsed.files.reduce(0) { $0 + $1.dels }
                if self.files.isEmpty {
                    self.summaryLabel.stringValue = "No changes since the last commit."
                    self.splitView.rows = []
                } else {
                    self.summaryLabel.stringValue = "\(self.files.count) changed file\(self.files.count == 1 ? "" : "s") · "
                        + "+\(adds) −\(dels)"
                    self.filesTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    self.showFile(0)
                }
            }
        }
    }

    private func showFile(_ row: Int) {
        guard files.indices.contains(row) else { splitView.rows = []; return }
        splitView.rows = SplitRow.build(from: files[row].lines)
        diffScroll.contentView.scroll(to: .zero)
        diffScroll.reflectScrolledClipView(diffScroll.contentView)
    }

    // MARK: - Files table

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let file = files[row]
        let id = NSUserInterfaceItemIdentifier("DiffFileCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView(); c.identifier = id
            let name = NSTextField(labelWithString: ""); name.translatesAutoresizingMaskIntoConstraints = false
            name.font = .systemFont(ofSize: 12); name.lineBreakMode = .byTruncatingTail
            let stat = NSTextField(labelWithString: ""); stat.translatesAutoresizingMaskIntoConstraints = false
            stat.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            stat.setContentHuggingPriority(.required, for: .horizontal)
            stat.setContentCompressionResistancePriority(.required, for: .horizontal)
            c.addSubview(name); c.addSubview(stat); c.textField = name
            NSLayoutConstraint.activate([
                // Filename on the left (truncates), the +/- stat pinned on the right; the name stops
                // before the stat so it never overlaps it.
                name.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8),
                name.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                name.trailingAnchor.constraint(lessThanOrEqualTo: stat.leadingAnchor, constant: -8),
                stat.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -10),
                stat.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = (file.name as NSString).lastPathComponent
        cell.textField?.toolTip = file.name
        if let stat = cell.subviews.compactMap({ $0 as? NSTextField }).last(where: { $0 !== cell.textField }) {
            let s = NSMutableAttributedString()
            s.append(NSAttributedString(string: "+\(file.adds) ", attributes: [.foregroundColor: NSColor.systemGreen]))
            s.append(NSAttributedString(string: "−\(file.dels)", attributes: [.foregroundColor: NSColor.systemRed]))
            stat.attributedStringValue = s
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if filesTable.selectedRow >= 0 { showFile(filesTable.selectedRow) }
    }

    // MARK: - git + parsing

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

    /// Parse `git diff HEAD` output into one `ChangedFile` per file.
    private static func parse(_ raw: String) -> (files: [ChangedFile], total: Int) {
        var files: [ChangedFile] = []
        var name = ""
        var lines: [DiffLine] = []
        var adds = 0, dels = 0
        var oldN = 0, newN = 0

        func flush() {
            if !name.isEmpty || !lines.isEmpty {
                files.append(ChangedFile(name: name, adds: adds, dels: dels, lines: lines))
            }
        }

        for sub in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(sub)
            if s.hasPrefix("diff --git") {
                flush()
                name = s.components(separatedBy: " b/").last ?? s
                lines = []; adds = 0; dels = 0; oldN = 0; newN = 0
            } else if s.hasPrefix("@@") {
                (oldN, newN) = parseHunk(s)
                lines.append(DiffLine(kind: .hunk, oldNum: nil, newNum: nil, text: s))
            } else if s.hasPrefix("+++") || s.hasPrefix("---") || s.hasPrefix("index ")
                        || s.hasPrefix("new file") || s.hasPrefix("deleted file")
                        || s.hasPrefix("similarity") || s.hasPrefix("rename ") || s.hasPrefix("old mode")
                        || s.hasPrefix("new mode") || s.hasPrefix("Binary files") {
                continue
            } else if s.hasPrefix("+") {
                adds += 1
                lines.append(DiffLine(kind: .addition, oldNum: nil, newNum: newN, text: String(s.dropFirst())))
                newN += 1
            } else if s.hasPrefix("-") {
                dels += 1
                lines.append(DiffLine(kind: .deletion, oldNum: oldN, newNum: nil, text: String(s.dropFirst())))
                oldN += 1
            } else if s.hasPrefix(" ") {
                lines.append(DiffLine(kind: .context, oldNum: oldN, newNum: newN, text: String(s.dropFirst())))
                oldN += 1; newN += 1
            }
        }
        flush()
        return (files, files.count)
    }

    /// Old/new starting line numbers from a hunk header like `@@ -1,5 +1,6 @@`.
    private static func parseHunk(_ s: String) -> (Int, Int) {
        var o = 0, n = 0
        for part in s.components(separatedBy: " ") {
            if part.hasPrefix("-") { o = Int(part.dropFirst().components(separatedBy: ",").first ?? "") ?? 0 }
            if part.hasPrefix("+") { n = Int(part.dropFirst().components(separatedBy: ",").first ?? "") ?? 0 }
        }
        return (o, n)
    }
}

/// One side-by-side diff row: an old-side (left) cell and a new-side (right) cell, or a hunk header
/// that spans both columns. Changes pair deletions with additions; context shows on both sides.
struct SplitRow {
    enum Cell { case empty; case line(num: Int, text: String, changed: Bool) }
    var left: Cell
    var right: Cell
    var hunk: String?

    /// Convert a file's unified diff lines into aligned side-by-side rows.
    static func build(from lines: [DiffLine]) -> [SplitRow] {
        var rows: [SplitRow] = []
        var dels: [(Int, String)] = []
        var adds: [(Int, String)] = []
        func flush() {
            for i in 0..<max(dels.count, adds.count) {
                let l: Cell = i < dels.count ? .line(num: dels[i].0, text: dels[i].1, changed: true) : .empty
                let r: Cell = i < adds.count ? .line(num: adds[i].0, text: adds[i].1, changed: true) : .empty
                rows.append(SplitRow(left: l, right: r, hunk: nil))
            }
            dels.removeAll(); adds.removeAll()
        }
        for line in lines {
            switch line.kind {
            case .hunk:
                flush(); rows.append(SplitRow(left: .empty, right: .empty, hunk: line.text))
            case .deletion: dels.append((line.oldNum ?? 0, line.text))
            case .addition: adds.append((line.newNum ?? 0, line.text))
            case .context:
                flush()
                rows.append(SplitRow(left: .line(num: line.oldNum ?? 0, text: line.text, changed: false),
                                     right: .line(num: line.newNum ?? 0, text: line.text, changed: false), hunk: nil))
            default: break
            }
        }
        flush()
        return rows
    }
}

/// Renders side-by-side diff rows with wrapping: each side has a line-number gutter and a text
/// column; changed cells get a red (old) / green (new) background; rows size to the taller side.
final class SplitDiffView: NSView {
    var rows: [SplitRow] = [] { didSet { recomputeHeights() } }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    private let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private let lineHeight: CGFloat = 16
    private let vpad: CGFloat = 3
    private let gutterW: CGFloat = 40
    private let textPad: CGFloat = 8
    private var heights: [CGFloat] = []
    private var totalHeight: CGFloat = 0
    private var lastWidth: CGFloat = 0

    private let addBg = NSColor(srgbRed: 0.20, green: 0.55, blue: 0.33, alpha: 0.18)
    private let delBg = NSColor(srgbRed: 0.78, green: 0.25, blue: 0.30, alpha: 0.16)
    private let hunkBg = NSColor(srgbRed: 0.36, green: 0.50, blue: 0.92, alpha: 0.14)
    private let addNumBg = NSColor(srgbRed: 0.20, green: 0.55, blue: 0.33, alpha: 0.28)
    private let delNumBg = NSColor(srgbRed: 0.78, green: 0.25, blue: 0.30, alpha: 0.26)
    private lazy var numAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular),
        .foregroundColor: NSColor(white: 1, alpha: 0.35)]

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: totalHeight) }

    override func layout() {
        super.layout()
        if abs(bounds.width - lastWidth) > 0.5 { recomputeHeights() }
    }

    private var columnWidth: CGFloat { bounds.width / 2 }
    private var textWidth: CGFloat { max(20, columnWidth - gutterW - textPad * 2) }

    private func recomputeHeights() {
        lastWidth = bounds.width
        let tw = textWidth
        heights = rows.map { row in
            if row.hunk != nil { return lineHeight + vpad * 2 }
            return max(cellHeight(row.left, "-", tw), cellHeight(row.right, "+", tw), lineHeight) + vpad * 2
        }
        totalHeight = heights.reduce(0, +)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private func display(_ cell: SplitRow.Cell, _ sign: String) -> String? {
        guard case .line(_, let text, let changed) = cell else { return nil }
        return (changed ? "\(sign) " : "  ") + text
    }

    private func cellHeight(_ cell: SplitRow.Cell, _ sign: String, _ width: CGFloat) -> CGFloat {
        guard let s = display(cell, sign) else { return 0 }
        let r = (s as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return max(lineHeight, ceil(r.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.editorBackground.setFill(); dirtyRect.fill()
        guard !rows.isEmpty else { return }
        if heights.count != rows.count { recomputeHeights() }
        let colW = columnWidth, tw = textWidth
        var y: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let h = heights[i]
            let rowRect = NSRect(x: 0, y: y, width: bounds.width, height: h)
            if rowRect.intersects(dirtyRect) {
                if let hunk = row.hunk {
                    hunkBg.setFill(); rowRect.fill()
                    (hunk as NSString).draw(at: NSPoint(x: gutterW, y: y + vpad),
                        withAttributes: [.font: font, .foregroundColor: NSColor(srgbRed: 0.6, green: 0.72, blue: 1.0, alpha: 1)])
                } else {
                    drawCell(row.left, x: 0, colW: colW, tw: tw, y: y, h: h, sign: "-",
                             bg: delBg, numBg: delNumBg, textColor: NSColor(srgbRed: 1.0, green: 0.72, blue: 0.74, alpha: 1))
                    drawCell(row.right, x: colW, colW: colW, tw: tw, y: y, h: h, sign: "+",
                             bg: addBg, numBg: addNumBg, textColor: NSColor(srgbRed: 0.70, green: 0.98, blue: 0.78, alpha: 1))
                    NSColor(white: 1, alpha: 0.08).setFill()
                    NSRect(x: colW - 0.5, y: y, width: 1, height: h).fill()
                }
            }
            y += h
        }
    }

    private func drawCell(_ cell: SplitRow.Cell, x: CGFloat, colW: CGFloat, tw: CGFloat, y: CGFloat, h: CGFloat,
                          sign: String, bg: NSColor, numBg: NSColor, textColor: NSColor) {
        guard case .line(let num, _, let changed) = cell, let s = display(cell, sign) else { return }
        if changed {
            bg.setFill(); NSRect(x: x, y: y, width: colW, height: h).fill()
            numBg.setFill(); NSRect(x: x, y: y, width: gutterW, height: h).fill()
        }
        let ns = String(num) as NSString
        let nw = ns.size(withAttributes: numAttrs).width
        ns.draw(at: NSPoint(x: x + gutterW - nw - 6, y: y + vpad + 1), withAttributes: numAttrs)
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byWordWrapping
        (s as NSString).draw(with: NSRect(x: x + gutterW + textPad, y: y + vpad, width: tw, height: h - vpad),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .foregroundColor: changed ? textColor : NSColor(white: 0.88, alpha: 1), .paragraphStyle: para])
    }
}
