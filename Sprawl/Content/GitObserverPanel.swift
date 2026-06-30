import AppKit

struct GitCommit {
    let hash: String
    let date: Date
    let author: String
    let subject: String
}

/// Observes a local git repository: a GitHub-style contribution graph for a calendar year (with
/// year navigation), plus a timeline of that year's commits. Shells out to `git`.
final class GitObserverPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let containerView = NSView()
    private let bar = NSView()
    private let chooseButton = NSButton()
    private let pathLabel = NSTextField(labelWithString: "No repository selected")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let prevYearButton = NSButton()
    private let nextYearButton = NSButton()
    private let yearLabel = NSTextField(labelWithString: "")
    private let yearStack = NSStackView()
    private let graphView = ContributionGraphView()
    private let graphScroll = NSScrollView()
    private let tableView = NSTableView()
    private let tableScroll = NSScrollView()
    private let emptyState = NSStackView()

    private(set) var repoPath: String?
    private var commits: [GitCommit] = []           // the currently-shown year's commits (timeline)
    private var counts: [Date: Int] = [:]           // accumulated per-day counts across loaded years
    private var loadedYears: Set<Int> = []
    private var currentYear = Calendar.current.component(.year, from: Date())

    /// The selected repository changed — request an autosave.
    var onRepoChange: (() -> Void)?
    /// The title (repo name) changed — retitle the window.
    var onTitleChange: ((String) -> Void)?

    private static let cellID = NSUserInterfaceItemIdentifier("GitCommitCell")

    init(repoPath: String?) {
        super.init()
        buildUI()
        if let repoPath, !repoPath.isEmpty {
            selectRepo(URL(fileURLWithPath: repoPath), persist: false)
        }
    }

    func attach(to window: WindowView) { window.setContent(containerView) }
    func focus() { containerView.window?.makeFirstResponder(tableView) }

    // MARK: - UI

    private func buildUI() {
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = Palette.panelBody.cgColor

        bar.wantsLayer = true
        bar.layer?.backgroundColor = Palette.panelBody.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false

        chooseButton.title = "Choose Repository…"
        chooseButton.bezelStyle = .rounded
        chooseButton.controlSize = .small
        chooseButton.target = self
        chooseButton.action = #selector(chooseFolder)
        chooseButton.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(chooseButton)
        bar.addSubview(pathLabel)

        summaryLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        summaryLabel.textColor = Palette.sidebarText
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        for (button, arrow, action): (NSButton, String, Selector) in [
            (prevYearButton, "◀", #selector(goPrevYear)),
            (nextYearButton, "▶", #selector(goNextYear)),
        ] {
            button.title = arrow
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = action
        }
        yearLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        yearLabel.textColor = Palette.sidebarText
        yearLabel.alignment = .center
        yearStack.setViews([prevYearButton, yearLabel, nextYearButton], in: .leading)
        yearStack.orientation = .horizontal
        yearStack.spacing = 4
        yearStack.alignment = .centerY
        yearStack.translatesAutoresizingMaskIntoConstraints = false
        yearLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        graphScroll.translatesAutoresizingMaskIntoConstraints = false
        graphScroll.drawsBackground = false
        graphScroll.hasHorizontalScroller = true
        graphScroll.hasVerticalScroller = false
        graphScroll.scrollerStyle = .overlay
        graphScroll.autohidesScrollers = true
        graphView.translatesAutoresizingMaskIntoConstraints = false   // let the scroll view honor intrinsicContentSize
        graphScroll.documentView = graphView

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("commit"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 22
        tableView.dataSource = self
        tableView.delegate = self
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.drawsBackground = false
        tableScroll.hasVerticalScroller = true
        tableScroll.scrollerStyle = .overlay
        tableScroll.autohidesScrollers = true
        tableScroll.documentView = tableView

        // Empty state: a faded icon + "Select Repository", centered, shown until a repo is chosen.
        let emptyIcon = NSImageView()
        emptyIcon.image = LucideIcon.image(LucideIcon.gitCommit, size: 56, color: NSColor(white: 1, alpha: 0.16))
        let emptyButton = NSButton(title: "Select Repository", target: self, action: #selector(chooseFolder))
        emptyButton.bezelStyle = .rounded
        emptyButton.controlSize = .large
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 16
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.addArrangedSubview(emptyIcon)
        emptyState.addArrangedSubview(emptyButton)

        containerView.addSubview(bar)
        containerView.addSubview(summaryLabel)
        containerView.addSubview(yearStack)
        containerView.addSubview(graphScroll)
        containerView.addSubview(tableScroll)
        containerView.addSubview(emptyState)

        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            bar.topAnchor.constraint(equalTo: containerView.topAnchor),
            bar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 40),
            chooseButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            chooseButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            pathLabel.leadingAnchor.constraint(equalTo: chooseButton.trailingAnchor, constant: 10),
            pathLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            pathLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            summaryLabel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
            summaryLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),

            yearStack.centerYAnchor.constraint(equalTo: summaryLabel.centerYAnchor),
            yearStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            yearStack.leadingAnchor.constraint(greaterThanOrEqualTo: summaryLabel.trailingAnchor, constant: 8),

            graphScroll.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 8),
            graphScroll.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            graphScroll.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            graphScroll.heightAnchor.constraint(equalToConstant: 132),

            tableScroll.topAnchor.constraint(equalTo: graphScroll.bottomAnchor, constant: 4),
            tableScroll.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
        updateEmptyState()
    }

    private func updateEmptyState() {
        let hasRepo = repoPath != nil
        emptyState.isHidden = hasRepo
        for view in [bar, summaryLabel, yearStack, graphScroll, tableScroll] { view.isHidden = !hasRepo }
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Observe"
        panel.message = "Choose a folder containing a git repository"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.selectRepo(url, persist: true)
        }
    }

    private func selectRepo(_ url: URL, persist: Bool) {
        repoPath = url.path
        pathLabel.stringValue = url.path
        onTitleChange?(url.lastPathComponent)
        if persist { onRepoChange?() }
        updateEmptyState()
        counts = [:]
        loadedYears = []
        setYear(Calendar.current.component(.year, from: Date()))
    }

    private func setYear(_ year: Int) {
        currentYear = year
        graphView.year = year
        yearLabel.stringValue = String(year)
        graphScroll.contentView.scroll(to: .zero)              // back to January at the left
        graphScroll.reflectScrolledClipView(graphScroll.contentView)
        loadCommits(forYear: year)
    }

    @objc private func goPrevYear() { guard repoPath != nil else { return }; setYear(currentYear - 1) }
    @objc private func goNextYear() { guard repoPath != nil else { return }; setYear(currentYear + 1) }

    private func loadCommits(forYear year: Int) {
        guard let path = repoPath else { return }
        let url = URL(fileURLWithPath: path)
        summaryLabel.stringValue = "Loading \(year)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let commits = GitObserverPanel.runGitLog(at: url, year: year)
            DispatchQueue.main.async {
                guard let self, self.currentYear == year else { return }   // ignore stale year loads
                self.commits = commits
                self.loadedYears.insert(year)
                for (day, n) in GitObserverPanel.dailyCounts(commits) { self.counts[day] = n }
                self.graphView.counts = self.counts
                self.updateContent()
            }
        }
    }

    private func updateContent() {
        if commits.isEmpty {
            summaryLabel.stringValue = "No commits in \(currentYear)"
        } else {
            summaryLabel.stringValue = "\(commits.count) commit\(commits.count == 1 ? "" : "s") in \(currentYear)"
        }
        tableView.reloadData()
    }

    // MARK: - Git

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func runGitLog(at url: URL, year: Int) -> [GitCommit] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", url.path, "log",
                             "--since=\(year)-01-01T00:00:00", "--until=\(year + 1)-01-01T00:00:00",
                             "--no-merges", "--date=iso-strict",
                             "--pretty=format:%H\u{1f}%ad\u{1f}%an\u{1f}%s"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return [] }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()   // drains the pipe until EOF
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return [] }

        var result: [GitCommit] = []
        for line in text.split(separator: "\n") {
            let fields = line.components(separatedBy: "\u{1f}")
            guard fields.count == 4, let date = isoFormatter.date(from: fields[1]) else { continue }
            result.append(GitCommit(hash: fields[0], date: date, author: fields[2], subject: fields[3]))
        }
        return result
    }

    static func dailyCounts(_ commits: [GitCommit]) -> [Date: Int] {
        var counts: [Date: Int] = [:]
        let calendar = Calendar.current
        for commit in commits {
            counts[calendar.startOfDay(for: commit.date), default: 0] += 1
        }
        return counts
    }

    // MARK: - Timeline table

    func numberOfRows(in tableView: NSTableView) -> Int { commits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard commits.indices.contains(row) else { return nil }
        let commit = commits[row]
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? CommitCellView ?? CommitCellView()
        cell.identifier = Self.cellID
        cell.configure(commit)
        return cell
    }
}

/// A single timeline row: date, subject, and author.
private final class CommitCellView: NSTableCellView {
    private let dateField = NSTextField(labelWithString: "")
    private let subjectField = NSTextField(labelWithString: "")
    private let authorField = NSTextField(labelWithString: "")

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for (field, color, size): (NSTextField, NSColor, CGFloat) in [
            (dateField, .secondaryLabelColor, 11),
            (subjectField, Palette.sidebarText, 12),
            (authorField, .secondaryLabelColor, 11),
        ] {
            field.font = .systemFont(ofSize: size)
            field.textColor = color
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        NSLayoutConstraint.activate([
            dateField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dateField.centerYAnchor.constraint(equalTo: centerYAnchor),
            dateField.widthAnchor.constraint(equalToConstant: 48),
            subjectField.leadingAnchor.constraint(equalTo: dateField.trailingAnchor, constant: 8),
            subjectField.centerYAnchor.constraint(equalTo: centerYAnchor),
            authorField.leadingAnchor.constraint(greaterThanOrEqualTo: subjectField.trailingAnchor, constant: 8),
            authorField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            authorField.centerYAnchor.constraint(equalTo: centerYAnchor),
            authorField.widthAnchor.constraint(lessThanOrEqualToConstant: 120),
        ])
        subjectField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ commit: GitCommit) {
        dateField.stringValue = Self.dateFormatter.string(from: commit.date)
        subjectField.stringValue = commit.subject
        authorField.stringValue = commit.author
    }
}

/// GitHub-style contribution grid for one calendar year (Jan 1 – Dec 31): weeks as columns,
/// weekdays as rows, each cell shaded by that day's commit count.
final class ContributionGraphView: NSView {
    var counts: [Date: Int] = [:] { didSet { needsDisplay = true } }
    var year: Int = Calendar.current.component(.year, from: Date()) {
        didSet { guard year != oldValue else { return }; invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    private let cell: CGFloat = 11
    private let gap: CGFloat = 3
    private let topInset: CGFloat = 18
    private let leftInset: CGFloat = 30

    private var step: CGFloat { cell + gap }
    override var isFlipped: Bool { true }

    private struct YearGrid { let start: Date; let columns: Int; let jan1: Date; let dec31: Date }

    private func grid(for year: Int) -> YearGrid? {
        let cal = Calendar.current
        var comps = DateComponents(); comps.year = year; comps.month = 1; comps.day = 1
        guard let jan1 = cal.date(from: comps) else { return nil }
        comps.month = 12; comps.day = 31
        guard let dec31raw = cal.date(from: comps) else { return nil }
        let dec31 = cal.startOfDay(for: dec31raw)
        // First column starts on the firstWeekday on/just before Jan 1 (GitHub-style leading column).
        let weekday = cal.component(.weekday, from: jan1)
        let lead = (weekday - cal.firstWeekday + 7) % 7
        guard let start = cal.date(byAdding: .day, value: -lead, to: jan1) else { return nil }
        let days = cal.dateComponents([.day], from: start, to: dec31).day ?? 0
        return YearGrid(start: start, columns: days / 7 + 1, jan1: jan1, dec31: dec31)
    }

    override var intrinsicContentSize: NSSize {
        let columns = grid(for: year)?.columns ?? 53
        return NSSize(width: leftInset + CGFloat(columns) * step + 12, height: topInset + 7 * step + 6)
    }

    private static let levels: [NSColor] = [
        NSColor(white: 1, alpha: 0.07),
        NSColor(srgbRed: 0x0E / 255, green: 0x44 / 255, blue: 0x29 / 255, alpha: 1),
        NSColor(srgbRed: 0x00 / 255, green: 0x6D / 255, blue: 0x32 / 255, alpha: 1),
        NSColor(srgbRed: 0x26 / 255, green: 0xA6 / 255, blue: 0x41 / 255, alpha: 1),
        NSColor(srgbRed: 0x39 / 255, green: 0xD3 / 255, blue: 0x53 / 255, alpha: 1),
    ]

    private func level(_ count: Int) -> Int {
        switch count {
        case 0: return 0
        case 1...2: return 1
        case 3...5: return 2
        case 6...9: return 3
        default: return 4
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let cal = Calendar.current
        guard let g = grid(for: year) else { return }

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMM"

        var lastMonth = -1
        for col in 0..<g.columns {
            for row in 0..<7 {
                guard let date = cal.date(byAdding: .day, value: col * 7 + row, to: g.start) else { continue }
                if date < g.jan1 || date > g.dec31 { continue }   // bound to the calendar year
                let rect = NSRect(x: leftInset + CGFloat(col) * step,
                                  y: topInset + CGFloat(row) * step, width: cell, height: cell)
                Self.levels[level(counts[date] ?? 0)].setFill()
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            }
            // Month label where a new in-year month first appears at the top of a column.
            if let colTop = cal.date(byAdding: .day, value: col * 7, to: g.start) {
                let ref = max(colTop, g.jan1)
                let month = cal.component(.month, from: ref)
                if month != lastMonth, ref <= g.dec31 {
                    lastMonth = month
                    monthFormatter.string(from: ref).draw(
                        at: NSPoint(x: leftInset + CGFloat(col) * step, y: 2), withAttributes: labelAttrs)
                }
            }
        }

        // Day-of-week labels (Mon / Wed / Fri).
        for (row, name) in [(1, "Mon"), (3, "Wed"), (5, "Fri")] {
            name.draw(at: NSPoint(x: 2, y: topInset + CGFloat(row) * step - 1), withAttributes: labelAttrs)
        }
    }
}
