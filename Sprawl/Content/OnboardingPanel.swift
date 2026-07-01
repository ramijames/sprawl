import AppKit

/// First-run wizard. Lives as a special panel in a "Welcome" project: introduces Sprawl, offers to
/// import browser bookmarks, collects an Anthropic API key, and creates the user's first project.
final class OnboardingPanel: NSObject {
    let containerView = NSView()
    private let topSites: TopSitesStore

    /// Called when the wizard finishes — passes the chosen first-project name (nil = default). The
    /// app creates that project, removes the onboarding project, and marks onboarding complete.
    var onFinish: ((String?) -> Void)?

    private let content = NSView()
    private let backButton = NSButton()
    private let primaryButton = NSButton()
    private var dots: [NSView] = []
    private var step = 0
    private let stepCount = 4

    // Per-step state.
    private var browserChecks: [(button: NSButton, browser: DetectedBrowser)] = []
    private let keyField = NSSecureTextField()
    private let projectField = NSTextField()

    private static let accent = NSColor(srgbRed: 0x9E / 255, green: 0x63 / 255, blue: 0xE0 / 255, alpha: 1)
    private static let fadedIcon = NSColor(white: 1, alpha: 0.16)   // matches the empty-state icons

    init(topSites: TopSitesStore) {
        self.topSites = topSites
        super.init()
        buildChrome()
        goTo(0)
    }

    func attach(to window: WindowView) { window.setContent(containerView) }
    func focus() {}

    // MARK: - Chrome

    private func buildChrome() {
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = Palette.panelBody.cgColor

        content.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false

        backButton.title = "Back"
        backButton.bezelStyle = .rounded
        backButton.target = self
        backButton.action = #selector(backTapped)
        backButton.translatesAutoresizingMaskIntoConstraints = false

        primaryButton.bezelStyle = .rounded
        primaryButton.keyEquivalent = "\r"
        primaryButton.controlSize = .large
        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)
        primaryButton.translatesAutoresizingMaskIntoConstraints = false

        let dotRow = NSStackView()
        dotRow.orientation = .horizontal
        dotRow.spacing = 7
        dotRow.translatesAutoresizingMaskIntoConstraints = false
        dots = (0..<stepCount).map { _ in
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
            dotRow.addArrangedSubview(dot)
            return dot
        }

        footer.addSubview(backButton)
        footer.addSubview(dotRow)
        footer.addSubview(primaryButton)

        containerView.addSubview(content)
        containerView.addSubview(footer)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 24),
            content.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -28),
            content.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),

            footer.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -18),
            footer.heightAnchor.constraint(equalToConstant: 32),

            backButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            dotRow.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            dotRow.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            primaryButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            primaryButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
    }

    private func goTo(_ newStep: Int) {
        step = max(0, min(stepCount - 1, newStep))
        content.subviews.forEach { $0.removeFromSuperview() }

        let view: NSView
        let primaryTitle: String
        switch step {
        case 0: view = makeWelcome(); primaryTitle = "Get Started"
        case 1: view = makeBrowsers(); primaryTitle = "Continue"
        case 2: view = makeClaude(); primaryTitle = "Continue"
        default: view = makeProject(); primaryTitle = "Create Project"
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            view.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor),
            view.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor),
            view.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])

        primaryButton.title = primaryTitle
        backButton.isHidden = step == 0
        for (i, dot) in dots.enumerated() {
            dot.layer?.backgroundColor = (i <= step ? Self.accent : NSColor(white: 1, alpha: 0.18)).cgColor
        }
    }

    @objc private func backTapped() { goTo(step - 1) }

    @objc private func primaryTapped() {
        switch step {
        case 0:
            goTo(1)
        case 1:
            importSelectedBrowsers()
            goTo(2)
        case 2:
            let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { APIKeyStore.save(key) }
            goTo(3)
        default:
            let name = projectField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            onFinish?(name.isEmpty ? nil : name)
        }
    }

    // MARK: - Steps

    private func makeWelcome() -> NSView {
        let icon = NSImageView()
        icon.image = LucideIcon.image(LucideIcon.sparkles, size: 44, color: Self.accent)
        let stack = column([
            icon,
            label("Welcome to Sprawl", size: 24, weight: .bold),
            label("A spatial canvas for your work — terminals, editors, browsers, git insight, and Claude, all laid out together on one infinite, zoomable surface.",
                  size: 13, color: .secondaryLabelColor, multiline: true, width: 380, center: true),
        ])
        return stack
    }

    private func makeBrowsers() -> NSView {
        browserChecks = []
        let detected = Self.detectBrowsers()
        let icon = NSImageView()
        icon.image = LucideIcon.image(LucideIcon.importIcon, size: 52, color: Self.fadedIcon)
        var checks: [NSView] = []
        if detected.isEmpty {
            checks.append(label("No supported browsers found — you can skip this step.",
                                size: 12, color: .tertiaryLabelColor, multiline: true, width: 380, center: true))
        } else {
            for browser in detected {
                let check = NSButton(checkboxWithTitle: "  " + browser.name, target: nil, action: nil)
                check.state = .on
                check.font = .systemFont(ofSize: 13)
                browserChecks.append((check, browser))
                checks.append(check)
            }
        }
        // Centered title/body; the checkbox list is a leading-aligned block, itself centered.
        let checkStack = NSStackView(views: checks)
        checkStack.orientation = .vertical
        checkStack.alignment = .leading
        checkStack.spacing = 10
        return column([
            icon,
            label("Bring your sites with you", size: 20, weight: .semibold, center: true),
            label("Import bookmarks from your browsers to fill your new-tab page. macOS may ask permission to read each browser's data.",
                  size: 12, color: .secondaryLabelColor, multiline: true, width: 380, center: true),
            checkStack,
        ], spacing: 14)
    }

    private func makeClaude() -> NSView {
        let icon = NSImageView()
        icon.image = LucideIcon.filledImage([LucideIcon.anthropicGlyphPath], size: 52, color: Self.fadedIcon, viewBox: 512)
        let rows: [NSView] = [
            icon,
            label("Add Claude", size: 20, weight: .semibold, center: true),
            label("Paste an Anthropic API key to enable the Claude assistant panel. It's stored in your macOS Keychain, never in the workspace file.",
                  size: 12, color: .secondaryLabelColor, multiline: true, width: 380, center: true),
            APIKeyStore.hasKey
                ? label("✓ A key is already set — you can continue.", size: 12, color: Self.accent, multiline: true, width: 380, center: true)
                : keyField,
            link("Get a key at console.anthropic.com →", url: "https://console.anthropic.com/settings/keys"),
        ]
        keyField.placeholderString = "sk-ant-…"
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.widthAnchor.constraint(equalToConstant: 360).isActive = true
        return column(rows, spacing: 12)
    }

    private func makeProject() -> NSView {
        projectField.stringValue = projectField.stringValue.isEmpty ? "My Project" : projectField.stringValue
        projectField.translatesAutoresizingMaskIntoConstraints = false
        projectField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let icon = NSImageView()
        icon.image = LucideIcon.image(LucideIcon.folderPlus, size: 52, color: Self.fadedIcon)
        let rows: [NSView] = [
            icon,
            label("Create your first project", size: 20, weight: .semibold, center: true),
            label("Projects are folders on the canvas that group related windows. Name your first one to get started.",
                  size: 12, color: .secondaryLabelColor, multiline: true, width: 380, center: true),
            projectField,
        ]
        return column(rows, spacing: 12)
    }

    // MARK: - Browser import

    enum BrowserKind { case chromium, firefox, safari }
    struct DetectedBrowser { let name: String; let url: URL; let kind: BrowserKind }

    private static func detectBrowsers() -> [DetectedBrowser] {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                           appropriateFor: nil, create: false) else { return [] }
        var result: [DetectedBrowser] = []

        // Chromium-family: bookmarks are plain JSON (no lock, no decryption).
        let chromium: [(String, String)] = [
            ("Google Chrome", "Google/Chrome/Default/Bookmarks"),
            ("Microsoft Edge", "Microsoft Edge/Default/Bookmarks"),
            ("Brave", "BraveSoftware/Brave-Browser/Default/Bookmarks"),
            ("Vivaldi", "Vivaldi/Default/Bookmarks"),
            ("Arc", "Arc/User Data/Default/Bookmarks"),
            ("Chromium", "Chromium/Default/Bookmarks"),
        ]
        for (name, rel) in chromium {
            let url = appSupport.appendingPathComponent(rel)
            if fm.fileExists(atPath: url.path) { result.append(DetectedBrowser(name: name, url: url, kind: .chromium)) }
        }

        // Firefox: a profile dir under Firefox/Profiles containing places.sqlite (SQLite).
        let profiles = appSupport.appendingPathComponent("Firefox/Profiles")
        if let entries = try? fm.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil) {
            let withPlaces = entries.filter { fm.fileExists(atPath: $0.appendingPathComponent("places.sqlite").path) }
            if let chosen = withPlaces.first(where: { $0.lastPathComponent.hasSuffix("default-release") }) ?? withPlaces.first {
                result.append(DetectedBrowser(name: "Firefox", url: chosen, kind: .firefox))
            }
        }

        // Safari: present on every Mac; reading its bookmarks needs Full Disk Access (best-effort).
        if fm.fileExists(atPath: "/Applications/Safari.app") {
            let plist = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/Bookmarks.plist")
            result.append(DetectedBrowser(name: "Safari", url: plist, kind: .safari))
        }
        return result
    }

    private func importSelectedBrowsers() {
        for entry in browserChecks where entry.button.state == .on {
            switch entry.browser.kind {
            case .chromium:
                Self.importChromiumBookmarks(from: entry.browser.url, into: topSites)
                Self.importChromiumHistory(bookmarksFile: entry.browser.url, into: topSites)
            case .firefox:
                Self.importFirefox(profile: entry.browser.url, into: topSites)
            case .safari:
                Self.importSafari(plist: entry.browser.url, into: topSites)
                Self.importSafariHistory(into: topSites)
            }
        }
        topSites.flush()   // one write after the whole import (addBookmark/seed don't save)
    }

    /// Record a bookmark: keep the full URL/title, and seed the host into the frequent-sites grid.
    private static func addBookmark(_ urlString: String, _ title: String, into store: TopSitesStore) {
        guard let host = URLComponents(string: urlString)?.host, !host.isEmpty else { return }
        let name = title.isEmpty ? host : title
        store.addBookmark(title: name, url: urlString)
        store.record(host: host, name: name)
    }

    /// Run a read-only sqlite query (tab-separated) and return one row per line, split into columns.
    private static func sqliteRows(_ dbPath: String, _ query: String) -> [[String]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-separator", "\t", dbPath, query]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { $0.components(separatedBy: "\t") }
    }

    /// Seed the frequent-sites grid from history rows of `(url, title, visitCount)`.
    private static func seedHistory(_ rows: [[String]], into store: TopSitesStore) {
        for row in rows where row.count >= 3 {
            guard let host = URLComponents(string: row[0])?.host, !host.isEmpty,
                  let visits = Int(row[2]), visits > 0 else { continue }
            store.seed(host: host, name: row[1].isEmpty ? host : row[1], count: visits)
        }
    }

    /// Copy a possibly-locked sqlite DB to a temp file, query it, and clean up. Returns [] on failure.
    private static func withCopiedDB(_ source: URL, _ query: String) -> [[String]] {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprawl-db-\(UUID().uuidString).sqlite")
        guard (try? FileManager.default.copyItem(at: source, to: tmp)) != nil else { return [] }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return sqliteRows(tmp.path, query)
    }

    /// Firefox: places.sqlite holds both bookmarks and history (visit_count). Copy it (it may be
    /// locked) and query read-only.
    private static func importFirefox(profile url: URL, into store: TopSitesStore) {
        let places = url.appendingPathComponent("places.sqlite")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprawl-places-\(UUID().uuidString).sqlite")
        guard (try? FileManager.default.copyItem(at: places, to: tmp)) != nil else { return }
        defer { try? FileManager.default.removeItem(at: tmp) }
        for row in sqliteRows(tmp.path,
            "SELECT p.url, IFNULL(b.title, p.title) FROM moz_bookmarks b JOIN moz_places p ON b.fk = p.id "
            + "WHERE b.type = 1 AND p.url LIKE 'http%' LIMIT 500;") where !row.isEmpty {
            addBookmark(row[0], row.count > 1 ? row[1] : "", into: store)
        }
        seedHistory(sqliteRows(tmp.path,
            "SELECT url, IFNULL(title,''), visit_count FROM moz_places WHERE url LIKE 'http%' "
            + "AND visit_count > 0 ORDER BY visit_count DESC LIMIT 500;"), into: store)
    }

    /// Safari bookmarks are a binary plist (reading it requires Full Disk Access — best-effort).
    private static func importSafari(plist url: URL, into store: TopSitesStore) {
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return }
        var imported = 0
        func walk(_ node: [String: Any]) {
            guard imported < 500 else { return }
            if node["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf",
               let urlString = node["URLString"] as? String {
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
                addBookmark(urlString, title, into: store)
                imported += 1
            }
            if let children = node["Children"] as? [[String: Any]] {
                for child in children { walk(child) }
            }
        }
        walk(root)
    }

    /// Safari history lives in ~/Library/Safari/History.db (needs Full Disk Access — best-effort).
    private static func importSafariHistory(into store: TopSitesStore) {
        let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Safari/History.db")
        guard FileManager.default.fileExists(atPath: db.path) else { return }
        seedHistory(withCopiedDB(db,
            "SELECT url, '', visit_count FROM history_items WHERE url LIKE 'http%' "
            + "ORDER BY visit_count DESC LIMIT 500;"), into: store)
    }

    /// Walk a Chromium Bookmarks JSON tree, keeping the full URL/title and seeding the grid by host.
    private static func importChromiumBookmarks(from url: URL, into store: TopSitesStore) {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else { return }
        var imported = 0
        func walk(_ node: [String: Any]) {
            guard imported < 500 else { return }
            if node["type"] as? String == "url", let urlString = node["url"] as? String {
                addBookmark(urlString, node["name"] as? String ?? "", into: store)
                imported += 1
            }
            if let children = node["children"] as? [[String: Any]] {
                for child in children { walk(child) }
            }
        }
        for key in ["bookmark_bar", "other", "synced"] {
            if let node = roots[key] as? [String: Any] { walk(node) }
        }
    }

    /// Chromium history is the `History` sqlite next to `Bookmarks` (locked while the browser runs).
    private static func importChromiumHistory(bookmarksFile: URL, into store: TopSitesStore) {
        let history = bookmarksFile.deletingLastPathComponent().appendingPathComponent("History")
        guard FileManager.default.fileExists(atPath: history.path) else { return }
        seedHistory(withCopiedDB(history,
            "SELECT url, IFNULL(title,''), visit_count FROM urls WHERE url LIKE 'http%' "
            + "ORDER BY visit_count DESC LIMIT 500;"), into: store)
    }

    // MARK: - Small builders

    private func column(_ views: [NSView], spacing: CGFloat = 14, alignment: NSLayoutConstraint.Attribute = .centerX) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = spacing
        stack.alignment = alignment
        return stack
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor = Palette.sidebarText, multiline: Bool = false,
                       width: CGFloat = 0, center: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.alignment = center ? .center : .natural
        if multiline {
            field.lineBreakMode = .byWordWrapping
            field.maximumNumberOfLines = 0
            if width > 0 { field.preferredMaxLayoutWidth = width; field.widthAnchor.constraint(equalToConstant: width).isActive = true }
        }
        return field
    }

    private func link(_ text: String, url: String) -> NSButton {
        let button = NSButton(title: text, target: self, action: #selector(openLink(_:)))
        button.isBordered = false
        button.bezelStyle = .inline
        button.contentTintColor = Self.accent
        button.font = .systemFont(ofSize: 11)
        button.toolTip = url
        button.identifier = NSUserInterfaceItemIdentifier(url)
        return button
    }

    @objc private func openLink(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue, let url = URL(string: id) { NSWorkspace.shared.open(url) }
    }
}
