import AppKit
import WebKit

/// Owns a `WKWebView` plus a small address bar, hosted inside a window panel. The only file that
/// touches WebKit.
final class BrowserPanel: NSObject, WKNavigationDelegate {
    private let container = NSView()
    private let webView: WKWebView
    private let addressField = NSTextField()
    private let backButton = NSButton()
    private let forwardButton = NSButton()

    /// The page title changed — used to retitle the window panel.
    var onTitleChange: ((String) -> Void)?
    /// Navigation changed the URL — request an autosave so the browser restores where it was.
    var onURLChange: (() -> Void)?

    var currentURL: String? { webView.url?.absoluteString }

    private static let homePage = URL(string: "https://www.google.com")!

    init(url: URL?) {
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()
        webView.navigationDelegate = self
        buildUI()
        load(url ?? Self.homePage)
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
}
