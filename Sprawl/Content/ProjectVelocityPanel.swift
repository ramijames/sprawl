import AppKit

/// One contributor's share of the work.
struct Contributor {
    let name: String
    let commits: Int
    let fraction: Double
}

/// A glanceable summary of a repo: recency, a commit-over-time histogram, and who's doing the work.
struct ProjectPulse {
    var totalCommits = 0
    var firstCommit: Date?
    var lastCommit: Date?
    var buckets: [Int] = []                 // commits per equal time-slice, oldest → newest
    var contributors: [Contributor] = []    // sorted by commit count, descending
    var contributorCount = 0
}

/// Shows, at a glance: has the repo been updated lately, where the spikes of work were (a commit
/// histogram over the whole history), and who the core contributors are. Shells out to `git`.
final class ProjectVelocityPanel: NSObject {
    let containerView = NSView()
    private let bar = NSView()
    private let chooseButton = NSButton()
    private let pathLabel = NSTextField(labelWithString: "No repository selected")
    private let summary = ProjectPulseView()
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
    func focus() { containerView.window?.makeFirstResponder(summary) }

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
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        summary.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = summary

        // Empty state: a faded gauge icon + "Select Repository", centered, shown until a repo is chosen.
        let emptyIcon = NSImageView()
        emptyIcon.image = LucideIcon.image(LucideIcon.gauge, size: 56, color: NSColor(white: 1, alpha: 0.16))
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

            // Pin the document view to the clip (top/leading) and stretch it to the clip width.
            summary.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            summary.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            summary.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
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
        panel.prompt = "Measure"
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
            let commits = ProjectVelocityPanel.runGitLog(at: url)
            let pulse = ProjectVelocityPanel.computePulse(commits)
            DispatchQueue.main.async { self?.summary.pulse = pulse }
        }
    }

    // MARK: - Git

    /// Whole-history author + date for every (non-merge) commit — lightweight even for big repos.
    static func runGitLog(at url: URL) -> [(author: String, date: Date)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", url.path, "log", "--no-merges", "--date=unix",
                             "--pretty=format:%an\u{1f}%ad"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return [] }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return [] }

        var result: [(String, Date)] = []
        for line in text.split(separator: "\n") {
            let fields = line.components(separatedBy: "\u{1f}")
            guard fields.count == 2, let unix = TimeInterval(fields[1]) else { continue }
            result.append((fields[0], Date(timeIntervalSince1970: unix)))
        }
        return result
    }

    static let bucketCount = 52

    static func computePulse(_ commits: [(author: String, date: Date)]) -> ProjectPulse {
        guard !commits.isEmpty else { return ProjectPulse() }
        let dates = commits.map { $0.date }
        let first = dates.min()!
        let last = dates.max()!
        let span = last.timeIntervalSince(first)

        var buckets = [Int](repeating: 0, count: bucketCount)
        for d in dates {
            let idx = span <= 0 ? bucketCount - 1
                : min(bucketCount - 1, Int(d.timeIntervalSince(first) / span * Double(bucketCount)))
            buckets[max(0, idx)] += 1
        }

        var counts: [String: Int] = [:]
        for c in commits { counts[c.author, default: 0] += 1 }
        let total = commits.count
        let contributors = counts.sorted { $0.value > $1.value }
            .map { Contributor(name: $0.key, commits: $0.value, fraction: Double($0.value) / Double(total)) }

        return ProjectPulse(totalCommits: total, firstCommit: first, lastCommit: last,
                            buckets: buckets, contributors: contributors, contributorCount: counts.count)
    }
}

/// Draws the three glance sections top-to-bottom: recency header, commit histogram, contributor bars.
final class ProjectPulseView: NSView {
    var pulse = ProjectPulse() {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    private let pad: CGFloat = 16
    private let chartHeight: CGFloat = 88
    private let rowHeight: CGFloat = 24
    private let maxContributors = 8

    private static let green = NSColor(srgbRed: 0x39 / 255, green: 0xD3 / 255, blue: 0x53 / 255, alpha: 1)
    private static let amber = NSColor(srgbRed: 0xDF / 255, green: 0xA5 / 255, blue: 0x3A / 255, alpha: 1)
    private static let gray = NSColor(srgbRed: 0x8A / 255, green: 0x90 / 255, blue: 0xA6 / 255, alpha: 1)

    private var shownContributors: Int { min(pulse.contributors.count, maxContributors) }

    override var intrinsicContentSize: NSSize {
        guard pulse.totalCommits > 0 else { return NSSize(width: NSView.noIntrinsicMetric, height: 120) }
        var h = pad
        h += 24 + 26              // header: status line + subtitle
        h += 18 + chartHeight + 20 // histogram: label + chart + axis labels
        h += 22                   // contributors label
        h += CGFloat(shownContributors) * rowHeight
        if pulse.contributors.count > shownContributors { h += 20 }
        h += pad
        return NSSize(width: NSView.noIntrinsicMetric, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        guard w > 0 else { return }
        guard pulse.totalCommits > 0 else {
            drawText("No commits found", in: NSRect(x: 0, y: 50, width: w, height: 20),
                     font: .systemFont(ofSize: 13), color: .secondaryLabelColor, alignment: .center)
            return
        }
        var y = pad

        // ── Header: recency ─────────────────────────────────────────────
        let (statusText, statusColor) = recency(pulse.lastCommit)
        Self.colorBlend(statusColor).setFill()
        NSBezierPath(ovalIn: NSRect(x: pad, y: y + 4, width: 9, height: 9)).fill()
        drawText(statusText, in: NSRect(x: pad + 16, y: y, width: w - pad * 2 - 16, height: 18),
                 font: .systemFont(ofSize: 14, weight: .semibold), color: Palette.sidebarText)
        y += 24
        drawText(subtitle(), in: NSRect(x: pad, y: y, width: w - pad * 2, height: 16),
                 font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        y += 26

        // ── Histogram: commits over time ────────────────────────────────
        drawSectionLabel("COMMITS OVER TIME", at: &y, width: w)
        let chartRect = NSRect(x: pad, y: y, width: w - pad * 2, height: chartHeight)
        drawHistogram(in: chartRect)
        y += chartHeight + 2
        // Axis: first → last date.
        let monthYear = DateFormatter(); monthYear.dateFormat = "MMM yyyy"
        if let first = pulse.firstCommit {
            drawText(monthYear.string(from: first), in: NSRect(x: pad, y: y, width: 120, height: 14),
                     font: .systemFont(ofSize: 9), color: .secondaryLabelColor)
        }
        if let last = pulse.lastCommit {
            drawText(monthYear.string(from: last), in: NSRect(x: w - pad - 120, y: y, width: 120, height: 14),
                     font: .systemFont(ofSize: 9), color: .secondaryLabelColor, alignment: .right)
        }
        y += 18

        // ── Contributors: who's doing the work ──────────────────────────
        drawSectionLabel("CORE CONTRIBUTORS", at: &y, width: w)
        let nameW: CGFloat = 120, statW: CGFloat = 78
        let barX = pad + nameW + 8
        let barW = max(20, w - pad - statW - 8 - barX)
        let topShare = pulse.contributors.first.map { max($0.fraction, 0.0001) } ?? 1
        for (i, c) in pulse.contributors.prefix(maxContributors).enumerated() {
            let rowY = y + CGFloat(i) * rowHeight
            let mid = rowY + rowHeight / 2
            drawText(c.name, in: NSRect(x: pad, y: mid - 8, width: nameW, height: 16),
                     font: .systemFont(ofSize: 12), color: Palette.sidebarText)
            // Track + filled share bar (scaled so the top contributor's bar is full width).
            let track = NSRect(x: barX, y: mid - 4, width: barW, height: 8)
            NSColor(white: 1, alpha: 0.06).setFill()
            NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
            let fillW = max(3, CGFloat(c.fraction / topShare) * barW)
            Palette.projectColors[i % Palette.projectColors.count].setFill()
            NSBezierPath(roundedRect: NSRect(x: barX, y: mid - 4, width: fillW, height: 8), xRadius: 4, yRadius: 4).fill()
            drawText("\(c.commits) · \(Int((c.fraction * 100).rounded()))%",
                     in: NSRect(x: w - pad - statW, y: mid - 8, width: statW, height: 16),
                     font: .systemFont(ofSize: 11), color: .secondaryLabelColor, alignment: .right)
        }
        let extra = pulse.contributors.count - shownContributors
        if extra > 0 {
            let rowY = y + CGFloat(shownContributors) * rowHeight
            drawText("+\(extra) more contributor\(extra == 1 ? "" : "s")",
                     in: NSRect(x: pad, y: rowY, width: w - pad * 2, height: 16),
                     font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        }
    }

    private func drawHistogram(in rect: NSRect) {
        let buckets = pulse.buckets
        guard !buckets.isEmpty else { return }
        let maxV = max(buckets.max() ?? 1, 1)
        let bw = rect.width / CGFloat(buckets.count)
        for (i, v) in buckets.enumerated() {
            guard v > 0 else { continue }
            let h = max(1.5, CGFloat(v) / CGFloat(maxV) * rect.height)
            let x = rect.minX + CGFloat(i) * bw
            // Flipped view: the bar grows up from the chart's bottom edge.
            let barRect = NSRect(x: x + 0.5, y: rect.maxY - h, width: max(1.5, bw - 1), height: h)
            Self.green.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 1, yRadius: 1).fill()
        }
        // Baseline.
        NSColor(white: 1, alpha: 0.10).setFill()
        NSRect(x: rect.minX, y: rect.maxY, width: rect.width, height: 1).fill()
    }

    private func recency(_ last: Date?) -> (String, NSColor) {
        guard let last else { return ("No commits yet", Self.gray) }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let text = "Updated " + formatter.localizedString(for: last, relativeTo: Date())
        let days = Date().timeIntervalSince(last) / 86400
        let color: NSColor = days <= 7 ? Self.green : (days <= 30 ? Self.amber : Self.gray)
        return (text, color)
    }

    private func subtitle() -> String {
        let commits = "\(pulse.totalCommits) commit\(pulse.totalCommits == 1 ? "" : "s")"
        let people = "\(pulse.contributorCount) contributor\(pulse.contributorCount == 1 ? "" : "s")"
        if let first = pulse.firstCommit {
            let formatter = DateFormatter(); formatter.dateFormat = "MMM yyyy"
            return "\(commits) · \(people) · since \(formatter.string(from: first))"
        }
        return "\(commits) · \(people)"
    }

    private func drawSectionLabel(_ text: String, at y: inout CGFloat, width: CGFloat) {
        drawText(text, in: NSRect(x: pad, y: y, width: width - pad * 2, height: 14),
                 font: .systemFont(ofSize: 10, weight: .semibold), color: NSColor(white: 1, alpha: 0.35))
        y += 18
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor,
                          alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        text.draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    /// Slightly brighten the status dot so it reads on the dark panel.
    private static func colorBlend(_ color: NSColor) -> NSColor {
        color.blended(withFraction: 0.1, of: .white) ?? color
    }
}
