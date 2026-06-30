import AppKit
import WebKit

/// Wraps the Figma web app in a `WKWebView` so a Figma file can live as a panel on the canvas.
/// (Figma supports Safari, so WebKit renders it; you sign in inside the panel.)
final class FigmaPanel: NSObject {
    private let webView: WKWebView

    override init() {
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()
        webView.wantsLayer = true
        if let url = URL(string: "https://www.figma.com/files/recent") {
            webView.load(URLRequest(url: url))
        }
    }

    func attach(to window: WindowView) { window.setContent(webView) }
    func focus() { webView.window?.makeFirstResponder(webView) }
}
