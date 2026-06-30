import AppKit
import WebKit

/// Persistent tally of how often each site (host) is opened, so the new-tab page can show the
/// most-used sites as a favicon grid. Stored as JSON in Application Support, shared by every
/// browser panel. Keyed by lowercased host.
final class TopSitesStore {
    struct Site: Codable { var host: String; var name: String; var count: Int }

    private var sites: [String: Site] = [:]
    private let fileURL: URL

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))?
            .appendingPathComponent("Sprawl", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("topsites.json")
        load()
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
final class BrowserPanel: NSObject, WKNavigationDelegate, WKUIDelegate, Tabbable {
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
    private let backButton = NSButton()
    private let forwardButton = NSButton()

    private let topSites: TopSitesStore
    private var tabs: [Tab] = []
    private var activeIndex = 0
    private var activeTab: Tab? { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil }

    /// The page title changed — used to retitle the window panel (reflects the active tab).
    var onTitleChange: ((String) -> Void)?
    /// Navigation/tab changes — request an autosave so the browser restores its tabs.
    var onURLChange: (() -> Void)?
    /// A sized popup (e.g. OAuth) asked for a new window: the model hosts this freshly-created
    /// browser panel as a separate item. Plain `_blank` links open as a new tab instead.
    var onHostNewBrowser: ((BrowserPanel) -> Void)?
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

        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        backButton.target = self
        backButton.action = #selector(goBack)
        forwardButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")
        forwardButton.target = self
        forwardButton.action = #selector(goForward)
        for button in [backButton, forwardButton] {
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

        for view in [tabBar, navBar, webContainer] {
            container.addSubview(view)
        }
        for view in [backButton, forwardButton, addressField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            navBar.addSubview(view)
        }

        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 32)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: container.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabBarHeight,

            navBar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            navBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            navBar.heightAnchor.constraint(equalToConstant: 34),

            webContainer.topAnchor.constraint(equalTo: navBar.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            backButton.leadingAnchor.constraint(equalTo: navBar.leadingAnchor, constant: 8),
            backButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 22),
            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            forwardButton.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 22),
            addressField.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 8),
            addressField.trailingAnchor.constraint(equalTo: navBar.trailingAnchor, constant: -8),
            addressField.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),
        ])
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
        userContent.removeScriptMessageHandler(forName: FocusTracker.messageName)
        userContent.add(focusTracker, name: FocusTracker.messageName)
        userContent.removeAllUserScripts()
        userContent.addUserScript(
            WKUserScript(source: FocusTracker.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        let webView = NavigatingWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.focusTracker = focusTracker
        webView.allowsBackForwardNavigationGestures = true   // two-finger swipe = back/forward
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

    private func syncChromeFromActive() {
        guard let tab = activeTab else { return }
        addressField.stringValue = tab.isStartPage ? "" : (tab.webView.url?.absoluteString ?? tab.url ?? "")
        backButton.isEnabled = tab.webView.canGoBack
        forwardButton.isEnabled = tab.webView.canGoForward
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
        let tiles = topSites.top(24).map { site -> String in
            let host = site.host
            let icon = "https://icons.duckduckgo.com/ip3/\(host).ico"
            return "<a class=\"tile\" href=\"https://\(host)\" title=\"\(host)\"><img src=\"\(icon)\" loading=\"lazy\" alt=\"\"></a>"
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: dark; }
          html, body { margin: 0; height: 100%; background: #212029;
            font-family: -apple-system, system-ui, sans-serif; }
          .grid { display: flex; flex-wrap: wrap; gap: 18px; padding: 40px;
            justify-content: center; align-content: flex-start; }
          a.tile { width: 54px; height: 54px; border-radius: 12px; background: #2C2A36;
            display: flex; align-items: center; justify-content: center; overflow: hidden;
            text-decoration: none; box-shadow: 0 1px 3px rgba(0,0,0,0.35); }
          a.tile img { width: 54px; height: 54px; border-radius: 12px; display: block;
            object-fit: cover; }
          a.add { color: #8A90A6; font-size: 26px; line-height: 0; background: transparent;
            box-shadow: none; border: 1px dashed #45444F; }
        </style></head>
        <body><div class="grid">
        \(tiles)
        <a class="tile add" href="sprawl://focus-address" title="Add">+</a>
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

    // MARK: - WKUIDelegate

    /// Links/JS asking for a new window: a sized popup (OAuth/sign-in) opens as a separate panel;
    /// a plain `_blank` / `window.open()` opens as a new tab in this panel.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        if windowFeatures.width != nil || windowFeatures.height != nil {
            let popup = BrowserPanel(topSites: topSites, adoptingPopupConfiguration: configuration)
            onHostNewBrowser?(popup)
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
