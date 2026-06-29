import AppKit
import WebKit

/// Owns a `WKWebView` plus a small address bar, hosted inside a window panel. The only file that
/// touches WebKit.
final class BrowserPanel: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let container = NSView()
    let webView: WKWebView
    private let addressField = NSTextField()
    private let backButton = NSButton()
    private let forwardButton = NSButton()

    /// The page title changed — used to retitle the window panel.
    var onTitleChange: ((String) -> Void)?
    /// Navigation changed the URL — request an autosave so the browser restores where it was.
    var onURLChange: (() -> Void)?
    /// A link/script asked for a new window: the model should host this freshly-created browser
    /// panel as a new item in the project. (WebKit then loads the popup into its web view.)
    var onHostNewBrowser: ((BrowserPanel) -> Void)?
    /// The page called `window.close()` — close this panel (so OAuth/sign-in popups self-dismiss).
    var onRequestClose: (() -> Void)?

    var currentURL: String? { webView.url?.absoluteString }

    private static let homePage = URL(string: "https://www.google.com")!

    init(url: URL?) {
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()
        commonSetup()
        load(url ?? Self.homePage)
    }

    /// For popups: WebKit hands us its `configuration` and loads the popup request into the web
    /// view we return, so we must NOT load anything here.
    init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        commonSetup()
    }

    private func commonSetup() {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        buildUI()
    }

    func attach(to window: WindowView) {
        window.setContent(container)
    }

    private func buildUI() {
        container.wantsLayer = true

        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = Palette.panelBody.cgColor

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

        for view in [bar, webView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        for view in [backButton, forwardButton, addressField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(view)
        }

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 34),

            webView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            backButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            backButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 22),
            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            forwardButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 22),
            addressField.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 8),
            addressField.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            addressField.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        updateNavButtons()
    }

    private func load(_ url: URL) {
        addressField.stringValue = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    /// Turn the address-bar text into a URL: use it as-is if it has a scheme, prepend https:// for
    /// a bare domain, otherwise run it as a Google search.
    @objc private func go() {
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
        if let url { load(url) }
    }

    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }

    private func updateNavButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url?.absoluteString { addressField.stringValue = url }
        updateNavButtons()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url?.absoluteString { addressField.stringValue = url }
        if let title = webView.title, !title.isEmpty { onTitleChange?(title) }
        updateNavButtons()
        onURLChange?()
    }

    // MARK: - WKUIDelegate

    /// Links/JS that ask for a new window (`target="_blank"`, `window.open`) have no target frame.
    /// Open them as a new browser panel rather than dropping or navigating in place.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        let popup = BrowserPanel(configuration: configuration)
        onHostNewBrowser?(popup)
        return popup.webView   // WebKit loads the popup request into this web view
    }

    /// `window.close()` from script (e.g. an OAuth popup after login) — close this panel.
    func webViewDidClose(_ webView: WKWebView) {
        onRequestClose?()
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
