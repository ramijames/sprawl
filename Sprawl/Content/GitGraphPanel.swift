import AppKit

/// One commit in the branch/merge graph.
struct GraphCommit {
    let hash: String
    let parents: [String]
    let refs: [String]
    let author: String
    let date: Date
    let subject: String
    var lane = 0
    var row = 0
    var shortHash: String { String(hash.prefix(7)) }
}

/// A connector between a commit and one of its parents, in (row, lane) space.
struct GraphEdge {
    let childRow: Int
    let childLane: Int
    let parentRow: Int
    let parentLane: Int
}

/// The laid-out graph: commits with assigned (row, lane), the edges, and how many lanes wide.
struct GraphLayout {
    var commits: [GraphCommit] = []
    var edges: [GraphEdge] = []
    var laneCount = 1
}

/// Visualizes a repo's branch & merge history as colored swim-lanes with commit nodes and curved
/// fork/merge connectors, plus a subject / author / short-hash column. Shells out to `git`.
final class GitGraphPanel: NSObject {
    let containerView = NSView()
    private let bar = NSView()
    private let chooseButton = NSButton()
    private let pathLabel = NSTextField(labelWithString: "No repository selected")
    private let graphView = GitGraphContentView()
    private let scroll = NSScrollView()
    private let emptyState = NSStackView()

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
    func focus() { containerView.window?.makeFirstResponder(graphView) }

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
        chooseButton.isHidden = true   // repo is chosen via the empty state + the options bar
        pathLabel.isHidden = true

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        graphView.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = graphView

        // Empty state: a faded graph icon + "Select Repository", centered, shown until a repo is chosen.
        let emptyIcon = NSImageView()
        emptyIcon.image = LucideIcon.image(LucideIcon.gitGraph, size: 56, color: NSColor(white: 1, alpha: 0.16))
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
        containerView.addSubview(scroll)
        containerView.addSubview(emptyState)

        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            bar.topAnchor.constraint(equalTo: containerView.topAnchor),
            bar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 0),
            chooseButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            chooseButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            pathLabel.leadingAnchor.constraint(equalTo: chooseButton.trailingAnchor, constant: 10),
            pathLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            pathLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
        // Pin the document view to the clip (top/leading) and let it stretch at least as wide as the
        // clip so the subject column fills. Without the position pins the view is under-constrained
        // and its frame can go NaN during a resize — which then traps in draw(_:).
        NSLayoutConstraint.activate([
            graphView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            graphView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            graphView.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
        ])
        updateEmptyState()
    }

    private func updateEmptyState() {
        let hasRepo = repoPath != nil
        emptyState.isHidden = hasRepo
        bar.isHidden = !hasRepo
        scroll.isHidden = !hasRepo
    }

    /// Public repository picker (invoked from the options bar).
    func chooseRepo() { chooseFolder() }

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
        pathLabel.stringValue = url.path
        onTitleChange?(url.lastPathComponent)
        if persist { onRepoChange?() }
        updateEmptyState()
        load(url)
    }

    private func load(_ url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let commits = GitGraphPanel.runGitLog(at: url)
            let layout = GitGraphPanel.assignLanes(commits)
            DispatchQueue.main.async { self?.graphView.layout = layout }
        }
    }

    // MARK: - Git

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func runGitLog(at url: URL) -> [GraphCommit] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", url.path, "log", "--all", "--date-order", "--max-count=2000",
                             "--date=iso-strict",
                             "--pretty=format:%H\u{1f}%P\u{1f}%D\u{1f}%an\u{1f}%ad\u{1f}%s"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return [] }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return [] }

        var result: [GraphCommit] = []
        for line in text.split(separator: "\n") {
            let fields = line.components(separatedBy: "\u{1f}")
            guard fields.count == 6, let date = isoFormatter.date(from: fields[4]) else { continue }
            let parents = fields[1].split(separator: " ").map(String.init)
            let refs = fields[2].split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "HEAD -> ", with: "")
                    .replacingOccurrences(of: "tag: ", with: "")
            }.filter { !$0.isEmpty }
            result.append(GraphCommit(hash: fields[0], parents: parents, refs: refs,
                                      author: fields[3], date: date, subject: fields[5]))
        }
        return result
    }

    /// Assign each commit a lane (column) and derive the connector edges. Commits arrive in
    /// --date-order (newest first), so a parent is always seen after all its children — by which
    /// point every lane leading to it already "expects" it.
    static func assignLanes(_ input: [GraphCommit]) -> GraphLayout {
        var commits = input
        var indexOf: [String: Int] = [:]
        for (i, c) in commits.enumerated() { indexOf[c.hash] = i }

        var lanes: [String?] = []   // lanes[i] = hash that lane i is currently waiting for
        func freeLaneOrAppend() -> Int {
            if let i = lanes.firstIndex(where: { $0 == nil }) { return i }
            lanes.append(nil); return lanes.count - 1
        }
        var maxLane = 0

        for r in commits.indices {
            let hash = commits[r].hash
            let myLane = lanes.firstIndex(where: { $0 == hash }) ?? freeLaneOrAppend()
            commits[r].lane = myLane
            commits[r].row = r
            maxLane = max(maxLane, myLane)
            lanes[myLane] = nil

            // Any other lanes also waiting for this commit collapse here.
            for l in lanes.indices where lanes[l] == hash { lanes[l] = nil }

            // Route parents: first parent continues this lane (unless already open elsewhere);
            // additional (merge) parents open or reuse their own lanes.
            let parents = commits[r].parents
            if let p0 = parents.first {
                if lanes.firstIndex(where: { $0 == p0 }) == nil { lanes[myLane] = p0 }
                for p in parents.dropFirst() where lanes.firstIndex(where: { $0 == p }) == nil {
                    let nl = freeLaneOrAppend()
                    lanes[nl] = p
                    maxLane = max(maxLane, nl)
                }
            }
        }

        // Edges fall out of the final (row, lane) coordinates: a parent's lane is reserved from its
        // first child down to itself, so each edge runs straight down that lane after one transition.
        var edges: [GraphEdge] = []
        for c in commits {
            for p in c.parents {
                guard let pi = indexOf[p] else { continue }
                edges.append(GraphEdge(childRow: c.row, childLane: c.lane,
                                       parentRow: pi, parentLane: commits[pi].lane))
            }
        }
        return GraphLayout(commits: commits, edges: edges, laneCount: maxLane + 1)
    }
}

/// Flipped view (row 0 at top) that draws the DAG: edges, then nodes, then the text column.
final class GitGraphContentView: NSView {
    var layout = GraphLayout() {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    private let rowHeight: CGFloat = 28
    private let laneWidth: CGFloat = 18
    private let graphLeft: CGFloat = 18
    private let nodeRadius: CGFloat = 5
    private let lineWidth: CGFloat = 2
    private let textGap: CGFloat = 14
    private let hashWidth: CGFloat = 64
    private let authorWidth: CGFloat = 140

    override var isFlipped: Bool { true }

    private func x(_ lane: Int) -> CGFloat { graphLeft + laneWidth * CGFloat(lane) }
    private func y(_ row: Int) -> CGFloat { rowHeight * CGFloat(row) + rowHeight / 2 }
    private var graphWidth: CGFloat { x(layout.laneCount - 1) + laneWidth }
    private var textX: CGFloat { graphWidth + textGap }
    private func laneColor(_ lane: Int) -> NSColor { Palette.projectColors[lane % Palette.projectColors.count] }

    override var intrinsicContentSize: NSSize {
        NSSize(width: textX + hashWidth + 240 + authorWidth,
               height: CGFloat(layout.commits.count) * rowHeight + 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        let commits = layout.commits
        guard !commits.isEmpty, rowHeight > 0, dirtyRect.minY.isFinite, dirtyRect.maxY.isFinite else { return }
        let first = max(0, Int((dirtyRect.minY / rowHeight).rounded(.down)) - 1)
        let last = min(commits.count - 1, Int((dirtyRect.maxY / rowHeight).rounded(.down)) + 1)
        guard first <= last else { return }

        // Edges first (under the nodes).
        for e in layout.edges where e.childRow <= last && e.parentRow >= first {
            let cx = x(e.childLane), px = x(e.parentLane)
            let cy = y(e.childRow), py = y(e.parentRow)
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            if cx == px {
                path.move(to: NSPoint(x: cx, y: cy))
                path.line(to: NSPoint(x: px, y: py))
            } else {
                let midY = cy + rowHeight   // confine the transition to the gap below the child
                path.move(to: NSPoint(x: cx, y: cy))
                path.curve(to: NSPoint(x: px, y: midY),
                           controlPoint1: NSPoint(x: cx, y: (cy + midY) / 2),
                           controlPoint2: NSPoint(x: px, y: (cy + midY) / 2))
                if midY < py { path.line(to: NSPoint(x: px, y: py)) }
            }
            laneColor(e.parentLane).setStroke()
            path.stroke()
        }

        // Nodes + text rows.
        let hashFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let subjectFont = NSFont.systemFont(ofSize: 12)
        let metaFont = NSFont.systemFont(ofSize: 11)
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated

        for r in first...last {
            let c = commits[r]
            let center = NSPoint(x: x(c.lane), y: y(r))

            // Node with a dark halo so it reads over crossing lanes.
            Palette.panelBody.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - nodeRadius - 1.5, y: center.y - nodeRadius - 1.5,
                                        width: (nodeRadius + 1.5) * 2, height: (nodeRadius + 1.5) * 2)).fill()
            laneColor(c.lane).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - nodeRadius, y: center.y - nodeRadius,
                                        width: nodeRadius * 2, height: nodeRadius * 2)).fill()

            var tx = textX
            for ref in c.refs { tx += drawChip(ref, at: NSPoint(x: tx, y: center.y), color: laneColor(c.lane)) }

            drawText(c.shortHash, in: NSRect(x: tx, y: center.y - 8, width: hashWidth, height: 16),
                     font: hashFont, color: .secondaryLabelColor)
            let subjectX = tx + hashWidth + 8
            let subjectW = max(40, bounds.width - subjectX - authorWidth - 12)
            drawText(c.subject, in: NSRect(x: subjectX, y: center.y - 9, width: subjectW, height: 16),
                     font: subjectFont, color: Palette.sidebarText)
            let meta = "\(c.author) · \(relative.localizedString(for: c.date, relativeTo: Date()))"
            drawText(meta, in: NSRect(x: bounds.width - authorWidth - 10, y: center.y - 8, width: authorWidth, height: 16),
                     font: metaFont, color: .secondaryLabelColor, alignment: .right)
        }
    }

    @discardableResult
    private func drawChip(_ text: String, at p: NSPoint, color: NSColor) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = text.size(withAttributes: attrs)
        let pad: CGFloat = 5
        let rect = NSRect(x: p.x, y: p.y - 8, width: size.width + pad * 2, height: 16)
        color.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: p.x + pad, y: p.y - size.height / 2), withAttributes: attrs)
        return rect.width + 6
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor,
                          alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        text.draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
}
