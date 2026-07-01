import AppKit
import WebKit

/// The browser toolbar's close control: a red dot that shows an ✕ on hover (matches window close).
final class CloseDotButton: NSButton {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { image = WindowView.closeImage("xmark.circle.fill") }
    override func mouseExited(with event: NSEvent) { image = WindowView.closeImage("circle.fill") }
}

/// App-wide ad / tracker blocker. Blocks a small curated set immediately, then fetches EasyList +
/// EasyPrivacy (public filter lists), converts them to WebKit content-blocker rules — including the
/// cosmetic (element-hiding) rules that hide first-party promoted content like Reddit's ads — and
/// compiles them in chunks (so one malformed rule can't sink the whole list). The raw list is cached
/// so it keeps working offline and updates in the background for the next launch.
@MainActor
final class AdBlocker {
    static let shared = AdBlocker()

    private struct WeakWebView { weak var view: WKWebView? }
    private var registered: [WeakWebView] = []
    private var lists: [WKContentRuleList] = []
    private var pending: [WKContentRuleList] = []
    private var flushGeneration = 0
    private var reloaded = Set<ObjectIdentifier>()
    private var started = false
    private let cacheURL: URL

    nonisolated static let sources = [
        "https://easylist-downloads.adblockplus.org/easylist.txt",
        "https://easylist-downloads.adblockplus.org/easyprivacy.txt",
    ]
    nonisolated static let chunkSize = 10000
    nonisolated static let maxRules = 50000

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))?
            .appendingPathComponent("Sprawl", isDirectory: true) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        cacheURL = base.appendingPathComponent("easylist.txt")
    }

    /// Warm up compilation early (called at app launch) so rule lists are ready before a browser opens.
    func prewarm() { start() }

    func install(on webView: WKWebView) {
        registered.append(WeakWebView(view: webView))
        // Lists already compiled are present from the first paint (no live re-render needed).
        if !lists.isEmpty {
            lists.forEach(webView.configuration.userContentController.add)
            reloaded.insert(ObjectIdentifier(webView))
        }
        start()
    }

    /// Register a freshly-compiled list. Adding a rule list to a *live* web view leaves WebKit in a
    /// half-painted state, so once compilation settles we add all lists and do one clean reload per
    /// page (which then renders fresh with blocking already applied).
    private func apply(_ list: WKContentRuleList) {
        lists.append(list)
        pending.append(list)
        flushGeneration += 1
        let generation = flushGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, generation == self.flushGeneration else { return }   // superseded by a later chunk
            let toAdd = self.pending
            self.pending.removeAll()
            for entry in self.registered {
                guard let view = entry.view else { continue }
                toAdd.forEach(view.configuration.userContentController.add)
                let id = ObjectIdentifier(view)
                if !self.reloaded.contains(id) { self.reloaded.insert(id); view.reload() }
            }
        }
    }

    private func start() {
        guard !started else { return }
        started = true
        compile(rules: Self.baseRules, idPrefix: "sprawl-ab-base")   // curated fallback, immediate
        if let text = try? String(contentsOf: cacheURL, encoding: .utf8), !text.isEmpty {
            Task { await self.build(from: text) }        // offline: use the cached list now
            Task { await self.refreshCache() }           // and refresh it for next launch
        } else {
            Task { await self.fetchAndBuild() }          // first run: fetch, cache, apply
        }
    }

    private func fetchAndBuild() async {
        guard let text = await Self.fetchSources() else { return }
        try? text.write(to: cacheURL, atomically: true, encoding: .utf8)
        await build(from: text)
    }

    private func refreshCache() async {
        if let text = await Self.fetchSources() { try? text.write(to: cacheURL, atomically: true, encoding: .utf8) }
    }

    private func build(from text: String) async {
        let chunks = await Task.detached { AdBlocker.convertChunks(text) }.value   // [Data] is Sendable
        for (index, data) in chunks.enumerated() {
            guard let json = String(data: data, encoding: .utf8) else { continue }
            WKContentRuleListStore.default()?.compileContentRuleList(
                forIdentifier: "sprawl-ab-el-\(index)", encodedContentRuleList: json) { [weak self] list, _ in
                if let list { self?.apply(list) }
            }
        }
    }

    private func compile(rules: [[String: Any]], idPrefix: String) {
        let chunks = stride(from: 0, to: rules.count, by: Self.chunkSize).map {
            Array(rules[$0..<min($0 + Self.chunkSize, rules.count)])
        }
        for (index, chunk) in chunks.enumerated() {
            guard let data = try? JSONSerialization.data(withJSONObject: chunk),
                  let json = String(data: data, encoding: .utf8) else { continue }
            WKContentRuleListStore.default()?.compileContentRuleList(
                forIdentifier: "\(idPrefix)-\(index)", encodedContentRuleList: json) { [weak self] list, _ in
                if let list { self?.apply(list) }
            }
        }
    }

    nonisolated private static func fetchSources() async -> String? {
        var combined = ""
        for source in sources {
            guard let url = URL(string: source),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8) else { continue }
            combined += text + "\n"
        }
        return combined.isEmpty ? nil : combined
    }

    /// Convert an ABP-syntax filter list to WebKit content-blocker rule chunks (serialized JSON).
    nonisolated static func convertChunks(_ text: String) -> [Data] {
        let rules = convert(text)
        return stride(from: 0, to: rules.count, by: chunkSize).compactMap { start in
            try? JSONSerialization.data(withJSONObject: Array(rules[start..<min(start + chunkSize, rules.count)]))
        }
    }

    nonisolated static func convert(_ text: String) -> [[String: Any]] {
        var rules: [[String: Any]] = []
        for rawLine in text.split(separator: "\n") {
            if rules.count >= maxRules { break }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }

            // Element-hiding (cosmetic) rule: [domains]##selector
            if let range = line.range(of: "##") {
                let domainPart = String(line[..<range.lowerBound])
                let selector = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard !selector.isEmpty else { continue }
                var trigger: [String: Any] = ["url-filter": ".*"]
                if !domainPart.isEmpty {
                    var ifDomains: [String] = [], unlessDomains: [String] = []
                    for domain in domainPart.split(separator: ",") {
                        if domain.hasPrefix("~") { unlessDomains.append("*" + domain.dropFirst()) }
                        else { ifDomains.append("*" + domain) }
                    }
                    if !ifDomains.isEmpty { trigger["if-domain"] = ifDomains }
                    if !unlessDomains.isEmpty { trigger["unless-domain"] = unlessDomains }
                }
                rules.append(["trigger": trigger, "action": ["type": "css-display-none", "selector": selector]])
                continue
            }
            if line.contains("#@#") || line.contains("#?#") || line.contains("#$#") { continue }   // exceptions / extended

            // Network rule.
            var isException = false
            var body = line
            if body.hasPrefix("@@") { isException = true; body = String(body.dropFirst(2)) }
            var optionStr = ""
            if let dollar = body.lastIndex(of: "$") { optionStr = String(body[body.index(after: dollar)...]); body = String(body[..<dollar]) }
            if body.hasPrefix("/") && body.hasSuffix("/") { continue }   // raw regex — skip
            guard let filter = urlFilter(from: body) else { continue }
            var trigger: [String: Any] = ["url-filter": filter]
            for option in optionStr.split(separator: ",") {
                let opt = String(option)
                if opt == "third-party" { trigger["load-type"] = ["third-party"] }
                else if opt == "~third-party" { trigger["load-type"] = ["first-party"] }
                else if opt.hasPrefix("domain=") {
                    var ifDomains: [String] = [], unlessDomains: [String] = []
                    for domain in opt.dropFirst("domain=".count).split(separator: "|") {
                        if domain.hasPrefix("~") { unlessDomains.append("*" + domain.dropFirst()) }
                        else { ifDomains.append("*" + domain) }
                    }
                    if !ifDomains.isEmpty { trigger["if-domain"] = ifDomains }
                    if !unlessDomains.isEmpty { trigger["unless-domain"] = unlessDomains }
                } else if ["script", "image", "font", "media", "websocket"].contains(opt) {
                    var types = trigger["resource-type"] as? [String] ?? []; types.append(opt); trigger["resource-type"] = types
                } else if opt == "stylesheet" {
                    var types = trigger["resource-type"] as? [String] ?? []; types.append("style-sheet"); trigger["resource-type"] = types
                }
                // Unknown/unsupported options (subdocument, csp, redirect, …) are ignored.
            }
            rules.append(["trigger": trigger, "action": ["type": isException ? "ignore-previous-rules" : "block"]])
        }
        return rules
    }

    /// Convert an ABP URL pattern to a WebKit `url-filter` regex (matched against a lowercased URL).
    nonisolated static func urlFilter(from pattern: String) -> String? {
        guard !pattern.isEmpty else { return nil }
        var p = pattern.lowercased()
        var out = ""
        if p.hasPrefix("||") { out += "^https?://([^/]*\\.)?"; p.removeFirst(2) }
        else if p.hasPrefix("|") { out += "^"; p.removeFirst() }
        var trailingAnchor = false
        if p.hasSuffix("|") { trailingAnchor = true; p.removeLast() }
        for ch in p {
            switch ch {
            case "*": out += ".*"
            case "^": out += "[^a-z0-9._%-]"   // ABP separator
            case ".", "?", "+", "(", ")", "[", "]", "{", "}", "\\", "$", "|": out += "\\" + String(ch)
            default: out += String(ch)
            }
        }
        if trailingAnchor { out += "$" }
        guard !out.isEmpty, out.canBeConverted(to: .ascii), out != ".*" else { return nil }
        return out
    }

    /// A small always-on set of ad/tracker hosts, applied instantly before EasyList finishes loading.
    static let baseRules: [[String: Any]] = {
        let domains = [
            "doubleclick.net", "googlesyndication.com", "google-analytics.com", "googletagmanager.com",
            "googletagservices.com", "googleadservices.com", "adservice.google.com", "adnxs.com",
            "amazon-adsystem.com", "scorecardresearch.com", "taboola.com", "outbrain.com", "criteo.com",
            "pubmatic.com", "rubiconproject.com", "openx.net", "moatads.com", "adroll.com",
        ]
        return domains.map { domain in
            ["trigger": ["url-filter": "^https?://([^/]*\\.)?" + NSRegularExpression.escapedPattern(for: domain),
                         "load-type": ["third-party"]],
             "action": ["type": "block"]]
        }
    }()
}

/// Persistent tally of how often each site (host) is opened, so the new-tab page can show the
/// most-used sites as a favicon grid. Stored as JSON in Application Support, shared by every
/// browser panel. Keyed by lowercased host.
final class TopSitesStore {
    struct Site: Codable { var host: String; var name: String; var count: Int }
    /// An imported bookmark (full URL + title), surfaced in the address bar, bookmarks bar, and menu.
    struct Bookmark: Codable, Equatable { var title: String; var url: String }

    private var sites: [String: Site] = [:]
    private var bookmarkList: [Bookmark] = []
    private let fileURL: URL
    private let bookmarksURL: URL

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))?
            .appendingPathComponent("Sprawl", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("topsites.json")
        bookmarksURL = base.appendingPathComponent("bookmarks.json")
        load()
        loadBookmarks()
    }

    // MARK: - Bookmarks + history (imported from other browsers during onboarding)

    /// Add an imported bookmark (deduped by URL). No save — call `flush()` once after a bulk import.
    func addBookmark(title: String, url: String) {
        guard let parsed = URL(string: url), parsed.scheme?.hasPrefix("http") == true else { return }
        guard !bookmarkList.contains(where: { $0.url == url }) else { return }
        bookmarkList.append(Bookmark(title: title.isEmpty ? url : title, url: url))
    }

    /// Seed `count` opens for a host at once (used to feed the frequent-sites grid from imported
    /// history visit counts). No save — call `flush()` once after a bulk import.
    func seed(host: String, name: String, count: Int) {
        let key = host.lowercased()
        guard !key.isEmpty, count > 0 else { return }
        var site = sites[key] ?? Site(host: key, name: name, count: 0)
        site.count += count
        if site.name.isEmpty { site.name = name }
        sites[key] = site
    }

    func bookmarks() -> [Bookmark] { bookmarkList }
    func isBookmarked(_ url: String) -> Bool { bookmarkList.contains { $0.url == url } }

    /// Add a bookmark and persist immediately (user action, vs. the bulk import which defers to `flush`).
    func addBookmarkAndSave(title: String, url: String) { addBookmark(title: title, url: url); saveBookmarks() }
    func removeBookmark(url: String) { bookmarkList.removeAll { $0.url == url }; saveBookmarks() }
    func renameBookmark(url: String, title: String) {
        guard let index = bookmarkList.firstIndex(where: { $0.url == url }) else { return }
        bookmarkList[index].title = title
        saveBookmarks()
    }

    /// Address-bar suggestions: matching bookmarks (full URL + title) first, then frequent hosts.
    func suggestions(_ query: String, limit: Int = 8) -> [(title: String, url: String)] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [(title: String, url: String)] = []
        for bm in bookmarkSuggestions(query, limit: limit) where seen.insert(bm.url).inserted {
            out.append((bm.title, bm.url))
        }
        for site in sites.values.sorted(by: { $0.count > $1.count }) where out.count < limit {
            guard site.host.contains(q) else { continue }
            let url = "https://\(site.host)"
            if seen.insert(url).inserted { out.append((site.name.isEmpty ? site.host : site.name, url)) }
        }
        return Array(out.prefix(limit))
    }

    /// Bookmarks whose title or URL contains `query` (for address-bar autocomplete), most-relevant
    /// first (prefix-of-host beats a mid-string match).
    func bookmarkSuggestions(_ query: String, limit: Int = 6) -> [Bookmark] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        let matches = bookmarkList.filter { $0.url.lowercased().contains(q) || $0.title.lowercased().contains(q) }
        return Array(matches.sorted { a, b in
            func rank(_ bm: Bookmark) -> Int {
                let host = (URL(string: bm.url)?.host ?? "").lowercased()
                if host.hasPrefix(q) { return 0 }
                if bm.title.lowercased().hasPrefix(q) { return 1 }
                return 2
            }
            return rank(a) < rank(b)
        }.prefix(limit))
    }

    /// Persist both stores after a bulk import.
    func flush() { save(); saveBookmarks() }

    private func loadBookmarks() {
        guard let data = try? Data(contentsOf: bookmarksURL),
              let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) else { return }
        bookmarkList = decoded
    }

    private func saveBookmarks() {
        guard let data = try? JSONEncoder().encode(bookmarkList) else { return }
        try? data.write(to: bookmarksURL, options: .atomic)
    }

    /// Count one "open" of `host`. Callers de-dupe per navigation so a site isn't counted on every
    /// in-page load — only when a tab actually lands on a new host.
    func record(host: String, name: String) {
        let key = host.lowercased()
        guard !key.isEmpty else { return }
        var site = sites[key] ?? Site(host: key, name: name, count: 0)
        site.count += 1
        if site.name.isEmpty { site.name = name }
        sites[key] = site
        save()
    }

    /// Most-opened first (ties broken by host for stable ordering), capped at `limit`.
    func top(_ limit: Int = 24) -> [Site] {
        Array(sites.values
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.host < $1.host }
            .prefix(limit))
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Site].self, from: data) else { return }
        sites = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sites) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// A `WKWebView` that adds keyboard history navigation: ⌘[ / ⌘← go back, ⌘] / ⌘→ go forward —
/// but only while the web content itself is focused, so the same keys still edit text in the
/// address bar (or anywhere else) normally.
final class NavigatingWebView: WKWebView {
    /// Open a new tab — invoked by the ⌘T "New Tab" menu item via the responder chain when this
    /// web view (i.e. a browser) is focused; the menu item disables itself when it isn't.
    var onNewTab: (() -> Void)?
    /// Close the active tab — invoked by the ⌘W "Close Tab" menu item via the responder chain.
    var onCloseTab: (() -> Void)?
    /// Knows whether an editable element is focused in the page, so ⌘←/⌘→ stay out of the way of
    /// caret movement inside web text fields.
    var focusTracker: FocusTracker?

    @objc func newBrowserTab(_ sender: Any?) { onNewTab?() }
    @objc func closeBrowserTab(_ sender: Any?) { onCloseTab?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), isWebContentFocused else {
            return super.performKeyEquivalent(with: event)
        }
        // (⌘T / ⌘W are handled by the app's key monitor against the selected window, not here.)
        switch event.charactersIgnoringModifiers {
        case "[": if canGoBack { goBack(); return true }
        case "]": if canGoForward { goForward(); return true }
        default: break
        }
        // ⌘←/⌘→ navigate history, but only when not editing text in the page (else they're the
        // standard "move caret to start/end of line" and we must leave them to WebKit).
        if focusTracker?.isEditingText != true {
            if event.keyCode == 123, canGoBack { goBack(); return true }      // ⌘←
            if event.keyCode == 124, canGoForward { goForward(); return true } // ⌘→
        }
        return super.performKeyEquivalent(with: event)
    }

    private var isWebContentFocused: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }
}

/// The browser panel's root content view. It implements the ⌘T / ⌘W menu actions and forwards
/// them to the panel, so the shortcuts work whenever the focus is anywhere inside the browser
/// (address bar, tab strip, or web content) — this view is an ancestor of all of them, so it's
/// always in the responder chain when the browser is focused.
final class BrowserContainerView: NSView {
    var onNewTab: (() -> Void)?
    var onCloseTab: (() -> Void)?

    @objc func newBrowserTab(_ sender: Any?) { onNewTab?() }
    @objc func closeBrowserTab(_ sender: Any?) { onCloseTab?() }
}

/// Reports, via an injected focus listener, whether an editable element is currently focused in
/// the page. Kept separate from the web view so the message-handler registration (which retains
/// its handler) can't form a retain cycle with the web view.
final class FocusTracker: NSObject, WKScriptMessageHandler {
    private(set) var isEditingText = false

    static let messageName = "sprawlFocus"
    static let script = """
    (function () {
      function editable() {
        var el = document.activeElement;
        if (!el) return false;
        var tag = (el.tagName || '').toUpperCase();
        return el.isContentEditable || tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT';
      }
      function report() {
        try { window.webkit.messageHandlers.sprawlFocus.postMessage(editable()); } catch (e) {}
      }
      document.addEventListener('focusin', report, true);
      document.addEventListener('focusout', function () { setTimeout(report, 0); }, true);
      report();
    })();
    """

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        isEditingText = (message.body as? Bool) ?? false
    }
}

/// Owns one or more browser tabs (each a `WKWebView`) plus a tab strip and an address bar, hosted
/// inside a window panel. The only file that touches WebKit.
final class BrowserPanel: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, Tabbable, NSTextFieldDelegate {
    /// One browser tab: its web view plus the bits we surface in the tab strip / persistence.
    private final class Tab {
        let webView: WKWebView
        var title: String = "New Tab"
        var url: String?
        var isStartPage = false
        /// Last host we counted an "open" for, so reloads/SPA navigations don't inflate the tally.
        var lastCountedHost: String?
        init(webView: WKWebView) { self.webView = webView }
    }

    private let container = BrowserContainerView()
    private let tabBar = BrowserTabBar(frame: .zero)
    private var tabBarHeight: NSLayoutConstraint!
    private let navBar = NSView()
    private let webContainer = NSView()
    private let addressField = NSTextField()
    private let closeButton = CloseDotButton()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let starButton = NSButton()
    private let bookmarksButton = NSButton()
    private let bookmarksBar = NSView()
    private let bookmarksStack = NSStackView()
    private var bookmarksBarHeight: NSLayoutConstraint!
    private var barBookmarks: [TopSitesStore.Bookmark] = []
    private let suggestionsView = NSView()
    private let suggestionStack = NSStackView()
    private var currentSuggestions: [(title: String, url: String)] = []
    private var suggestionIndex = -1
    private let findBar = NSView()
    private let findField = NSTextField()
    /// Close the whole browser window (the toolbar's × — the panel is chromeless, no title bar).
    var onCloseWindow: (() -> Void)?

    private let topSites: TopSitesStore
    private var tabs: [Tab] = []
    private var activeIndex = 0
    private var activeTab: Tab? { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil }

    /// The page title changed — used to retitle the window panel (reflects the active tab).
    var onTitleChange: ((String) -> Void)?
    /// Navigation/tab changes — request an autosave so the browser restores its tabs.
    var onURLChange: (() -> Void)?
    /// A sized popup (e.g. OAuth) asked for a new window: the model hosts this freshly-created
    /// browser panel as a separate item, centered over the opener at the requested size (so sign-ins
    /// feel like a modal). Plain `_blank` links open as a new tab instead.
    var onHostNewBrowser: ((BrowserPanel, NSSize) -> Void)?
    /// The last tab was closed, or `window.close()` fired on a popup — close this panel.
    var onRequestClose: (() -> Void)?

    /// Active tab's committed URL, or nil on the start page (legacy single-URL persistence field).
    var currentURL: String? { (activeTab?.isStartPage ?? true) ? nil : activeTab?.url }
    /// Every tab's URL in order (start-page tabs serialize as a sentinel), for persistence.
    var tabURLs: [String] {
        tabs.map { $0.isStartPage ? Self.startPageURLString
                                  : ($0.url ?? $0.webView.url?.absoluteString ?? Self.startPageURLString) }
    }
    var activeTabIndex: Int { activeIndex }
    /// The active tab's web view — what WebKit loads a popup request into.
    var webView: WKWebView? { activeTab?.webView }

    private static let startPageURLString = "sprawl://newtab"

    /// New browser item: a single tab showing the start page (or `url` if given).
    init(topSites: TopSitesStore, url: URL?) {
        self.topSites = topSites
        super.init()
        buildUI()
        let tab = makeTab(configuration: WKWebViewConfiguration())
        tabs.append(tab)
        selectTab(at: 0)
        if let url { load(url, in: tab) } else { loadStartPage(in: tab) }
    }

    /// Popup window (e.g. OAuth): adopt WebKit's configuration into a single tab and DON'T load —
    /// WebKit loads the popup request into the returned web view.
    init(topSites: TopSitesStore, adoptingPopupConfiguration configuration: WKWebViewConfiguration) {
        self.topSites = topSites
        super.init()
        buildUI()
        let tab = makeTab(configuration: configuration)
        tabs.append(tab)
        selectTab(at: 0)
    }

    /// Restore: rebuild one tab per saved URL (start-page sentinel restores the start page).
    init(topSites: TopSitesStore, tabURLs: [String], activeIndex: Int) {
        self.topSites = topSites
        super.init()
        buildUI()
        for string in tabURLs {
            let tab = makeTab(configuration: WKWebViewConfiguration())
            tabs.append(tab)
            if string == Self.startPageURLString || string.isEmpty {
                loadStartPage(in: tab)
            } else if let url = URL(string: string) {
                load(url, in: tab)
                tab.lastCountedHost = url.host   // a restored session isn't a fresh "open" — don't tally it
            } else {
                loadStartPage(in: tab)
            }
        }
        if tabs.isEmpty {
            let tab = makeTab(configuration: WKWebViewConfiguration())
            tabs.append(tab)
            loadStartPage(in: tab)
        }
        self.activeIndex = min(max(0, activeIndex), tabs.count - 1)
        selectTab(at: self.activeIndex)
    }

    func attach(to window: WindowView) {
        window.setContent(container)
    }

    // MARK: - UI

    private func buildUI() {
        container.wantsLayer = true
        container.layer?.backgroundColor = Palette.panelBody.cgColor
        // ⌘T / ⌘W are handled here too (not just on the web view) so they work whenever any part of
        // the browser is focused — the address bar, a tab, or the page — not only the web content.
        container.onNewTab = { [weak self] in self?.addNewTab() }
        container.onCloseTab = { [weak self] in self?.closeActiveTab() }

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onSelect = { [weak self] index in self?.selectTab(at: index) }
        tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }
        tabBar.onNewTab = { [weak self] in self?.addNewTab() }

        navBar.wantsLayer = true
        navBar.layer?.backgroundColor = Palette.panelBody.cgColor
        navBar.translatesAutoresizingMaskIntoConstraints = false

        webContainer.wantsLayer = true
        webContainer.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = WindowView.closeImage("circle.fill")   // the standard red close dot (✕ on hover)
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.contentTintColor = WindowView.closeColor
        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        closeButton.toolTip = "Close browser"
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        backButton.target = self
        backButton.action = #selector(goBack)
        forwardButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")
        forwardButton.target = self
        forwardButton.action = #selector(goForward)
        reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
        reloadButton.target = self
        reloadButton.action = #selector(reloadPage)
        reloadButton.toolTip = "Reload"
        for button in [backButton, forwardButton, reloadButton] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = Palette.sidebarText
        }

        addressField.placeholderString = "Search or enter address"
        addressField.font = .systemFont(ofSize: 12)
        addressField.focusRingType = .none
        addressField.lineBreakMode = .byTruncatingTail
        addressField.target = self
        addressField.action = #selector(go)
        addressField.delegate = self

        starButton.image = NSImage(systemSymbolName: "star", accessibilityDescription: "Bookmark")
        starButton.isBordered = false
        starButton.imagePosition = .imageOnly
        starButton.contentTintColor = Palette.sidebarText
        starButton.target = self
        starButton.action = #selector(toggleBookmarkCurrent)
        starButton.toolTip = "Bookmark this page"

        // Autocomplete dropdown (bookmarks + history), overlaying the page below the address bar.
        suggestionsView.wantsLayer = true
        suggestionsView.layer?.backgroundColor = Palette.panelBody.cgColor
        suggestionsView.layer?.cornerRadius = 8
        suggestionsView.layer?.borderWidth = 1
        suggestionsView.layer?.borderColor = Palette.panelBorder.cgColor
        suggestionsView.layer?.masksToBounds = true
        suggestionsView.translatesAutoresizingMaskIntoConstraints = false
        suggestionsView.isHidden = true
        suggestionStack.orientation = .vertical
        suggestionStack.spacing = 0
        suggestionStack.translatesAutoresizingMaskIntoConstraints = false
        suggestionsView.addSubview(suggestionStack)

        bookmarksButton.image = NSImage(systemSymbolName: "book", accessibilityDescription: "Bookmarks")
        bookmarksButton.isBordered = false
        bookmarksButton.imagePosition = .imageOnly
        bookmarksButton.contentTintColor = Palette.sidebarText
        bookmarksButton.target = self
        bookmarksButton.action = #selector(showBookmarksMenu)
        bookmarksButton.toolTip = "Bookmarks"

        bookmarksBar.wantsLayer = true
        bookmarksBar.layer?.backgroundColor = Palette.panelBody.cgColor
        bookmarksBar.translatesAutoresizingMaskIntoConstraints = false
        bookmarksStack.orientation = .horizontal
        bookmarksStack.spacing = 6
        bookmarksStack.translatesAutoresizingMaskIntoConstraints = false
        bookmarksBar.addSubview(bookmarksStack)

        // Order (top → bottom): address toolbar, tab strip, bookmarks bar, web content. The suggestions
        // dropdown is added last so it overlays the page.
        for view in [navBar, tabBar, bookmarksBar, webContainer, suggestionsView] { container.addSubview(view) }
        for view in [closeButton, backButton, forwardButton, reloadButton, addressField, starButton, bookmarksButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            navBar.addSubview(view)
        }

        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 32)
        bookmarksBarHeight = bookmarksBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            navBar.topAnchor.constraint(equalTo: container.topAnchor),
            navBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            navBar.heightAnchor.constraint(equalToConstant: 38),

            tabBar.topAnchor.constraint(equalTo: navBar.bottomAnchor),
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabBarHeight,

            bookmarksBar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            bookmarksBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bookmarksBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bookmarksBarHeight,

            webContainer.topAnchor.constraint(equalTo: bookmarksBar.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            closeButton.leadingAnchor.constraint(equalTo: navBar.leadingAnchor, constant: 10),
            closeButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            backButton.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
            backButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 22),
            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            forwardButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 22),
            reloadButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 2),
            reloadButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: 22),
            addressField.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor, constant: 8),
            addressField.trailingAnchor.constraint(equalTo: starButton.leadingAnchor, constant: -8),
            addressField.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            starButton.trailingAnchor.constraint(equalTo: bookmarksButton.leadingAnchor, constant: -6),
            starButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            starButton.widthAnchor.constraint(equalToConstant: 22),
            bookmarksButton.trailingAnchor.constraint(equalTo: navBar.trailingAnchor, constant: -10),
            bookmarksButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            bookmarksButton.widthAnchor.constraint(equalToConstant: 22),

            bookmarksStack.leadingAnchor.constraint(equalTo: bookmarksBar.leadingAnchor, constant: 10),
            bookmarksStack.trailingAnchor.constraint(lessThanOrEqualTo: bookmarksBar.trailingAnchor, constant: -10),
            bookmarksStack.centerYAnchor.constraint(equalTo: bookmarksBar.centerYAnchor),

            suggestionsView.topAnchor.constraint(equalTo: navBar.bottomAnchor, constant: -2),
            suggestionsView.leadingAnchor.constraint(equalTo: addressField.leadingAnchor, constant: -6),
            suggestionsView.trailingAnchor.constraint(equalTo: addressField.trailingAnchor, constant: 6),
            suggestionStack.topAnchor.constraint(equalTo: suggestionsView.topAnchor),
            suggestionStack.leadingAnchor.constraint(equalTo: suggestionsView.leadingAnchor),
            suggestionStack.trailingAnchor.constraint(equalTo: suggestionsView.trailingAnchor),
            suggestionStack.bottomAnchor.constraint(equalTo: suggestionsView.bottomAnchor),
        ])
        rebuildBookmarksBar()
        setupFindBar()
    }

    // MARK: - Find in page (⌘F)

    private func setupFindBar() {
        findBar.wantsLayer = true
        findBar.layer?.backgroundColor = Palette.panelBody.cgColor
        findBar.layer?.cornerRadius = 8
        findBar.layer?.borderWidth = 1
        findBar.layer?.borderColor = Palette.panelBorder.cgColor
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true

        findField.placeholderString = "Find in page"
        findField.font = .systemFont(ofSize: 12)
        findField.focusRingType = .none
        findField.translatesAutoresizingMaskIntoConstraints = false
        findField.delegate = self

        let prev = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous")!,
                            target: self, action: #selector(findPrevious))
        let next = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next")!,
                            target: self, action: #selector(findForward))
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!,
                             target: self, action: #selector(hideFind))
        for button in [prev, next, close] {
            button.isBordered = false; button.imagePosition = .imageOnly; button.contentTintColor = Palette.sidebarText
            button.translatesAutoresizingMaskIntoConstraints = false
        }

        for view in [findField, prev, next, close] { findBar.addSubview(view) }
        container.addSubview(findBar)   // topmost overlay
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: bookmarksBar.bottomAnchor, constant: 8),
            findBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            findBar.heightAnchor.constraint(equalToConstant: 34),
            findField.leadingAnchor.constraint(equalTo: findBar.leadingAnchor, constant: 10),
            findField.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            findField.widthAnchor.constraint(equalToConstant: 200),
            prev.leadingAnchor.constraint(equalTo: findField.trailingAnchor, constant: 8),
            prev.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            next.leadingAnchor.constraint(equalTo: prev.trailingAnchor, constant: 4),
            next.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            close.leadingAnchor.constraint(equalTo: next.trailingAnchor, constant: 8),
            close.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: findBar.trailingAnchor, constant: -10),
        ])
    }

    /// Show the find bar and focus it (⌘F).
    func showFind() {
        findBar.isHidden = false
        findField.textColor = .labelColor
        container.window?.makeFirstResponder(findField)
    }

    @objc private func hideFind() {
        findBar.isHidden = true
        container.window?.makeFirstResponder(activeTab?.webView)
    }

    @objc private func findForward() { find(forward: true) }
    @objc private func findPrevious() { find(forward: false) }

    private func find(forward: Bool) {
        let query = findField.stringValue
        guard !query.isEmpty, let webView = activeTab?.webView else { return }
        let config = WKFindConfiguration()
        config.backwards = !forward
        config.caseSensitive = false
        config.wraps = true
        webView.find(query, configuration: config) { [weak self] result in
            self?.findField.textColor = result.matchFound ? .labelColor : .systemRed
        }
    }

    // MARK: - Bookmarks bar + menu

    private func rebuildBookmarksBar() {
        barBookmarks = topSites.bookmarks()
        bookmarksStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !barBookmarks.isEmpty else { bookmarksBarHeight.constant = 0; bookmarksBar.isHidden = true; return }
        bookmarksBar.isHidden = false
        bookmarksBarHeight.constant = 30
        for (index, bm) in barBookmarks.prefix(30).enumerated() {
            let chip = NSButton(title: Self.shortTitle(bm), target: self, action: #selector(openBookmarkChip(_:)))
            chip.bezelStyle = .rounded
            chip.controlSize = .small
            chip.font = .systemFont(ofSize: 11)
            chip.tag = index
            chip.toolTip = bm.url
            chip.menu = bookmarkContextMenu(url: bm.url)   // right-click → rename / remove / copy
            if let host = URL(string: bm.url)?.host { Self.loadFavicon(host: host, into: chip) }
            bookmarksStack.addArrangedSubview(chip)
        }
    }

    private static var faviconCache: [String: NSImage] = [:]

    /// Load a host's favicon (cached) and show it before the chip's title.
    private static func loadFavicon(host: String, into button: NSButton) {
        if let image = faviconCache[host] { button.image = image; button.imagePosition = .imageLeading; return }
        guard let url = URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            image.size = NSSize(width: 14, height: 14)
            DispatchQueue.main.async {
                faviconCache[host] = image
                button.image = image
                button.imagePosition = .imageLeading
            }
        }.resume()
    }

    private static func shortTitle(_ bm: TopSitesStore.Bookmark) -> String {
        let raw = bm.title.isEmpty ? (URL(string: bm.url)?.host ?? bm.url) : bm.title
        return raw.count > 22 ? String(raw.prefix(22)) + "…" : raw
    }

    @objc private func openBookmarkChip(_ sender: NSButton) {
        guard barBookmarks.indices.contains(sender.tag) else { return }
        openBookmark(barBookmarks[sender.tag].url)
    }

    private func bookmarkContextMenu(url: String) -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("Rename…", #selector(renameBookmarkItem(_:))),
                                ("Remove", #selector(removeBookmarkItem(_:))),
                                ("Copy Link", #selector(copyBookmarkItem(_:)))] {
            if title == "Copy Link" { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = url
            menu.addItem(item)
        }
        return menu
    }

    @objc private func renameBookmarkItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String,
              let bookmark = topSites.bookmarks().first(where: { $0.url == url }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Bookmark"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = bookmark.title
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newTitle = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty else { return }
        topSites.renameBookmark(url: url, title: newTitle)
        rebuildBookmarksBar()
    }

    @objc private func removeBookmarkItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        topSites.removeBookmark(url: url)
        rebuildBookmarksBar()
        updateStar()
    }

    @objc private func copyBookmarkItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc private func showBookmarksMenu() {
        let menu = NSMenu()
        let all = topSites.bookmarks()
        if all.isEmpty {
            menu.addItem(withTitle: "No bookmarks", action: nil, keyEquivalent: "")
        }
        for bm in all.prefix(300) {
            let item = NSMenuItem(title: Self.shortTitle(bm), action: #selector(openBookmarkMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = bm.url
            item.toolTip = bm.url
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bookmarksButton.bounds.height + 4), in: bookmarksButton)
    }

    @objc private func openBookmarkMenuItem(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? String { openBookmark(url) }
    }

    private func openBookmark(_ urlString: String) {
        guard let url = URL(string: urlString), let tab = activeTab else { return }
        load(url, in: tab)
    }

    /// Toggle a bookmark for the current page (the toolbar ★).
    @objc private func toggleBookmarkCurrent() {
        guard let tab = activeTab, !tab.isStartPage,
              let urlString = tab.webView.url?.absoluteString ?? tab.url else { return }
        if topSites.isBookmarked(urlString) { topSites.removeBookmark(url: urlString) }
        else { topSites.addBookmarkAndSave(title: tab.title, url: urlString) }
        updateStar()
        rebuildBookmarksBar()
    }

    private func updateStar() {
        let urlString = activeTab.flatMap { $0.isStartPage ? nil : ($0.webView.url?.absoluteString ?? $0.url) }
        let marked = urlString.map { topSites.isBookmarked($0) } ?? false
        starButton.image = NSImage(systemSymbolName: marked ? "star.fill" : "star", accessibilityDescription: "Bookmark")
        starButton.contentTintColor = marked ? .systemYellow : Palette.sidebarText
        starButton.isEnabled = urlString != nil
        starButton.toolTip = marked ? "Remove bookmark" : "Bookmark this page"
    }

    // MARK: - Address-bar autocomplete (bookmarks + history)

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === addressField else { return }
        updateSuggestions(addressField.stringValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.hideSuggestions() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === findField {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)): find(forward: true); return true
            case #selector(NSResponder.cancelOperation(_:)): hideFind(); return true
            default: return false
            }
        }
        guard control === addressField, !suggestionsView.isHidden, !currentSuggestions.isEmpty else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            suggestionIndex = min(suggestionIndex + 1, currentSuggestions.count - 1); highlightSuggestion(); return true
        case #selector(NSResponder.moveUp(_:)):
            suggestionIndex = max(suggestionIndex - 1, -1); highlightSuggestion(); return true
        case #selector(NSResponder.insertNewline(_:)):
            if suggestionIndex >= 0 { openSuggestion(suggestionIndex); return true }
            return false   // nothing highlighted → let go() load the typed text
        case #selector(NSResponder.cancelOperation(_:)):
            hideSuggestions(); return true
        default:
            return false
        }
    }

    private func updateSuggestions(_ query: String) {
        currentSuggestions = topSites.suggestions(query)
        suggestionIndex = -1
        suggestionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !currentSuggestions.isEmpty else { hideSuggestions(); return }
        for (index, suggestion) in currentSuggestions.enumerated() {
            let row = NSButton(title: "", target: self, action: #selector(suggestionRowClicked(_:)))
            row.tag = index
            row.isBordered = false
            row.wantsLayer = true
            row.alignment = .left
            row.imagePosition = .noImage
            let title = suggestion.title.isEmpty ? suggestion.url : suggestion.title
            let attributed = NSMutableAttributedString(string: title + "   ", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: Palette.sidebarText])
            attributed.append(NSAttributedString(string: suggestion.url, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            row.attributedTitle = attributed
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 30).isActive = true
            suggestionStack.addArrangedSubview(row)
        }
        suggestionsView.isHidden = false
    }

    private func highlightSuggestion() {
        for (index, view) in suggestionStack.arrangedSubviews.enumerated() {
            view.layer?.backgroundColor = index == suggestionIndex
                ? NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor : NSColor.clear.cgColor
        }
    }

    @objc private func suggestionRowClicked(_ sender: NSButton) { openSuggestion(sender.tag) }

    private func openSuggestion(_ index: Int) {
        guard currentSuggestions.indices.contains(index),
              let url = URL(string: currentSuggestions[index].url), let tab = activeTab else { return }
        addressField.stringValue = currentSuggestions[index].url
        hideSuggestions()
        load(url, in: tab)
    }

    private func hideSuggestions() {
        suggestionsView.isHidden = true
        currentSuggestions = []
        suggestionIndex = -1
        suggestionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    // MARK: - Tabs

    private func makeTab(configuration: WKWebViewConfiguration) -> Tab {
        // Inject the editable-focus tracker before the web view is created (so it's part of the
        // config WebKit copies at init). A popup's adopted configuration (e.g. an OAuth sign-in
        // window) already carries the opener's handler/script, and re-adding a script message
        // handler with a name that already exists throws NSInvalidArgumentException — so clear any
        // prior registration first to stay idempotent.
        let focusTracker = FocusTracker()
        let userContent = configuration.userContentController
        userContent.removeAllScriptMessageHandlers()   // popups adopt the opener's config; avoid a dup-name crash
        userContent.add(focusTracker, name: FocusTracker.messageName)
        userContent.removeAllUserScripts()
        userContent.addUserScript(
            WKUserScript(source: FocusTracker.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        let webView = NavigatingWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.focusTracker = focusTracker
        webView.allowsBackForwardNavigationGestures = true   // two-finger swipe = back/forward
        AdBlocker.shared.install(on: webView)   // ad/tracker blocking (EasyList, on by default)
        webView.onNewTab = { [weak self] in self?.addNewTab() }            // ⌘T
        webView.onCloseTab = { [weak self] in self?.closeActiveTab() }     // ⌘W
        webView.translatesAutoresizingMaskIntoConstraints = false
        return Tab(webView: webView)
    }

    private func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeIndex = index
        let tab = tabs[index]
        webContainer.subviews.forEach { $0.removeFromSuperview() }
        let webView = tab.webView
        webContainer.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
        ])
        syncChromeFromActive()
        onTitleChange?(tab.title)
        rebuildTabBar()
    }

    /// Open a new tab (⌘T). Public so the app's key monitor can drive it off the selected window.
    func openNewTab() { addNewTab() }
    /// Close the active tab (⌘W); closing the last tab closes the panel.
    func closeCurrentTab() { closeActiveTab() }

    @objc private func addNewTab() {
        let tab = makeTab(configuration: WKWebViewConfiguration())
        tabs.append(tab)
        selectTab(at: tabs.count - 1)
        loadStartPage(in: tab)
        onURLChange?()
    }

    private func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        if tabs.count == 1 { onRequestClose?(); return }   // closing the last tab closes the panel

        let tab = tabs.remove(at: index)
        tab.webView.navigationDelegate = nil
        tab.webView.uiDelegate = nil
        tab.webView.removeFromSuperview()

        if index < activeIndex { activeIndex -= 1 }
        activeIndex = min(activeIndex, tabs.count - 1)
        selectTab(at: activeIndex)
        onURLChange?()
    }

    private func closeActiveTab() { closeTab(at: activeIndex) }

    private func tab(for webView: WKWebView) -> Tab? { tabs.first { $0.webView === webView } }

    private func rebuildTabBar() {
        tabBar.setTabs(titles: tabs.map { $0.title }, activeIndex: activeIndex)
        let show = tabs.count > 1   // a lone tab hides the strip
        tabBar.isHidden = !show
        tabBarHeight.constant = show ? 32 : 0
    }

    // MARK: - Navigation

    private func load(_ url: URL, in tab: Tab) {
        tab.isStartPage = false
        tab.url = url.absoluteString
        if tab === activeTab { addressField.stringValue = url.absoluteString }
        tab.webView.load(URLRequest(url: url))
    }

    /// Turn the address-bar text into a URL: use it as-is if it has a scheme, prepend https:// for
    /// a bare domain, otherwise run it as a Google search.
    @objc private func go() {
        guard let tab = activeTab else { return }
        let text = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let url: URL?
        if text.contains("://") {
            url = URL(string: text)
        } else if text.contains("."), !text.contains(" ") {
            url = URL(string: "https://\(text)")
        } else {
            let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
            url = URL(string: "https://www.google.com/search?q=\(q)")
        }
        if let url { load(url, in: tab) }
    }

    @objc private func goBack() { activeTab?.webView.goBack() }
    @objc private func goForward() { activeTab?.webView.goForward() }
    @objc private func reloadPage() { activeTab?.webView.reload() }
    @objc private func closeWindow() { onCloseWindow?() }


    private func syncChromeFromActive() {
        guard let tab = activeTab else { return }
        addressField.stringValue = tab.isStartPage ? "" : (tab.webView.url?.absoluteString ?? tab.url ?? "")
        backButton.isEnabled = tab.webView.canGoBack
        forwardButton.isEnabled = tab.webView.canGoForward
        updateStar()
    }

    private func focusAddressBar() {
        addressField.window?.makeFirstResponder(addressField)
    }

    private func displayName(for host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - Start page (most-opened favicon grid)

    private func loadStartPage(in tab: Tab) {
        tab.isStartPage = true
        tab.url = Self.startPageURLString
        tab.title = "New Tab"
        tab.lastCountedHost = nil
        if tab === activeTab { addressField.stringValue = "" }
        tab.webView.loadHTMLString(startPageHTML(), baseURL: nil)
        rebuildTabBar()
    }

    private func startPageHTML() -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let tiles = topSites.top(24).map { site -> String in
            let host = site.host
            let icon = "https://icons.duckduckgo.com/ip3/\(host).ico"
            return "<a class=\"tile\" href=\"https://\(esc(host))\" title=\"\(esc(host))\"><img src=\"\(icon)\" loading=\"lazy\" alt=\"\"></a>"
        }.joined(separator: "\n")
        let bookmarks = topSites.bookmarks()
        let bmItems = bookmarks.prefix(60).map { bm -> String in
            let host = URL(string: bm.url)?.host ?? ""
            let icon = "https://icons.duckduckgo.com/ip3/\(host).ico"
            return "<a class=\"bm\" href=\"\(esc(bm.url))\" title=\"\(esc(bm.url))\"><img src=\"\(icon)\" loading=\"lazy\" alt=\"\"><span>\(esc(bm.title))</span></a>"
        }.joined(separator: "\n")
        let bookmarksSection = bookmarks.isEmpty ? "" : """
        <div class="section">Bookmarks</div>
        <div class="bmlist">\(bmItems)</div>
        """
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: dark; }
          html, body { margin: 0; height: 100%; background: #212029;
            font-family: -apple-system, system-ui, sans-serif; }
          .wrap { max-width: 860px; margin: 0 auto; padding: 40px 24px 60px; }
          .section { color: #8A90A6; font-size: 12px; font-weight: 600; letter-spacing: 0.06em;
            text-transform: uppercase; margin: 8px 0 16px; }
          .grid { display: flex; flex-wrap: wrap; gap: 18px;
            justify-content: flex-start; align-content: flex-start; }
          a.tile { width: 54px; height: 54px; border-radius: 12px; background: #2C2A36;
            display: flex; align-items: center; justify-content: center; overflow: hidden;
            text-decoration: none; box-shadow: 0 1px 3px rgba(0,0,0,0.35); }
          a.tile img { width: 54px; height: 54px; border-radius: 12px; display: block;
            object-fit: cover; }
          a.add { color: #8A90A6; font-size: 26px; line-height: 0; background: transparent;
            box-shadow: none; border: 1px dashed #45444F; }
          .bmlist { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 32px; }
          a.bm { display: flex; align-items: center; gap: 8px; max-width: 240px;
            padding: 7px 12px 7px 8px; border-radius: 8px; background: #2C2A36;
            text-decoration: none; color: #D8D9E0; font-size: 13px; }
          a.bm:hover { background: #38363f; }
          a.bm img { width: 16px; height: 16px; border-radius: 4px; flex: 0 0 16px; }
          a.bm span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        </style></head>
        <body><div class="wrap">
        <div class="section">Frequently browsed</div>
        <div class="grid">
        \(tiles)
        <a class="tile add" href="sprawl://focus-address" title="Add">+</a>
        </div>
        \(bookmarksSection)
        </div></body></html>
        """
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.scheme == "sprawl" {
            decisionHandler(.cancel)
            if url.host == "focus-address" { focusAddressBar() }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)   // non-viewable → download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        if let url = webView.url, url.scheme?.hasPrefix("http") == true {
            tab.isStartPage = false
            tab.url = url.absoluteString
        }
        if tab === activeTab { syncChromeFromActive() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        if !tab.isStartPage, let url = webView.url, url.scheme?.hasPrefix("http") == true {
            tab.url = url.absoluteString
            if let title = webView.title, !title.isEmpty { tab.title = title }
            if let host = url.host, host != tab.lastCountedHost {
                tab.lastCountedHost = host
                topSites.record(host: host, name: displayName(for: host))
            }
        }
        rebuildTabBar()
        if tab === activeTab {
            syncChromeFromActive()
            onTitleChange?(tab.title)
        }
        onURLChange?()
    }

    // MARK: - WKDownloadDelegate (save to ~/Downloads, reveal in Finder when done)

    private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        var destination = dir.appendingPathComponent(name)
        let base = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        var counter = 1
        while FileManager.default.fileExists(atPath: destination.path) {   // de-dupe
            let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            destination = dir.appendingPathComponent(candidate)
            counter += 1
        }
        downloadDestinations[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) {
            NSWorkspace.shared.activateFileViewerSelecting([url])   // reveal the saved file in Finder
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
    }

    // MARK: - WKUIDelegate

    /// Links/JS asking for a new window: a sized popup (OAuth/sign-in) opens as a separate panel;
    /// a plain `_blank` / `window.open()` opens as a new tab in this panel.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        if windowFeatures.width != nil || windowFeatures.height != nil {
            let popup = BrowserPanel(topSites: topSites, adoptingPopupConfiguration: configuration)
            let size = NSSize(width: windowFeatures.width.map { CGFloat(truncating: $0) } ?? 480,
                              height: windowFeatures.height.map { CGFloat(truncating: $0) } ?? 640)
            onHostNewBrowser?(popup, size)
            return popup.webView
        }
        let tab = makeTab(configuration: configuration)   // adopt WebKit's config; it loads the request
        tabs.append(tab)
        selectTab(at: tabs.count - 1)
        onURLChange?()
        return tab.webView
    }

    /// `window.close()` from script (e.g. an OAuth popup after login) — close that tab.
    func webViewDidClose(_ webView: WKWebView) {
        if let index = tabs.firstIndex(where: { $0.webView === webView }) {
            closeTab(at: index)
        } else {
            onRequestClose?()
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        runAlert(alert, on: webView) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        runAlert(alert, on: webView) { response in completionHandler(response == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        runAlert(alert, on: webView) { response in
            completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    private func runAlert(_ alert: NSAlert, on webView: WKWebView,
                          completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}

// MARK: - Tab strip

/// The horizontal tab strip: a row of `TabChip`s that shrink to fit, plus a trailing "+" button.
/// Laid out manually so chips compress gracefully when many tabs are open.
final class BrowserTabBar: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?

    private var chips: [TabChip] = []
    private let newTabButton = NSButton()
    private let maxChipWidth: CGFloat = 180
    private let minChipWidth: CGFloat = 46
    private let chipSpacing: CGFloat = 2
    private let newTabWidth: CGFloat = 26

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = Palette.tabBarBackground.cgColor
        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
        newTabButton.imagePosition = .imageOnly
        newTabButton.isBordered = false
        newTabButton.contentTintColor = Palette.sidebarText
        newTabButton.target = self
        newTabButton.action = #selector(newTabClicked)
        addSubview(newTabButton)
    }

    @objc private func newTabClicked() { onNewTab?() }

    func setTabs(titles: [String], activeIndex: Int) {
        while chips.count < titles.count {
            let chip = TabChip(frame: .zero)
            addSubview(chip)
            chips.append(chip)
        }
        while chips.count > titles.count {
            chips.removeLast().removeFromSuperview()
        }
        for (index, chip) in chips.enumerated() {
            chip.title = titles[index]
            chip.isActive = (index == activeIndex)
            chip.onSelect = { [weak self] in self?.onSelect?(index) }
            chip.onClose = { [weak self] in self?.onClose?(index) }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let count = chips.count
        let buttonY = (bounds.height - 22) / 2
        guard count > 0 else {
            newTabButton.frame = NSRect(x: 6, y: buttonY, width: newTabWidth, height: 22)
            return
        }
        let available = bounds.width - newTabWidth - 12
        let raw = (available - CGFloat(count - 1) * chipSpacing) / CGFloat(count)
        let chipWidth = max(minChipWidth, min(maxChipWidth, raw))
        var x: CGFloat = 0
        for chip in chips {
            chip.frame = NSRect(x: x, y: 0, width: chipWidth, height: bounds.height)
            x += chipWidth + chipSpacing
        }
        newTabButton.frame = NSRect(x: x + 4, y: buttonY, width: newTabWidth, height: 22)
    }
}

/// A single tab in the strip: truncating title + a close button, with an active highlight.
final class TabChip: NSView {
    var title: String = "" {
        didSet { titleLabel.stringValue = title; titleLabel.toolTip = title }
    }
    var isActive: Bool = false {
        didSet { guard isActive != oldValue else { return }; needsLayout = true; needsDisplay = true }
    }
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 7
        titleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        titleLabel.textColor = Palette.sidebarText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.drawsBackground = false
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        addSubview(titleLabel)

        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")?
            .withSymbolConfiguration(config)
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.contentTintColor = Palette.sidebarText
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        addSubview(closeButton)
    }

    override func layout() {
        super.layout()
        let closeSize: CGFloat = 16
        closeButton.frame = NSRect(x: bounds.width - closeSize - 6, y: (bounds.height - closeSize) / 2,
                                   width: closeSize, height: closeSize)
        titleLabel.frame = NSRect(x: 9, y: (bounds.height - 16) / 2,
                                  width: max(0, bounds.width - closeSize - 20), height: 16)
    }

    override func updateLayer() {
        layer?.backgroundColor = (isActive ? Palette.tabActiveFill : NSColor.clear).cgColor
    }

    // Route clicks anywhere on the chip (incl. the title) to selection, except over the close button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, bounds.contains(local) else { return super.hitTest(point) }
        return closeButton.frame.contains(local) ? closeButton : self
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }

    @objc private func closeClicked() { onClose?() }
}
