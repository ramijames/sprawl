import AppKit

final class MainWindowController: NSWindowController {
    private let model: AppModel
    private var splitViewController: MainSplitViewController!

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        super.init(window: window)
        // We own window-frame persistence (via WorkspaceState), so disable AppKit's competing
        // mechanisms: controller cascading and automatic window state restoration. Otherwise
        // they reposition the window after restoreWindowFrame, leaving size but drifting origin.
        shouldCascadeWindows = false
        window.isRestorable = false
        configure(window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Flush the live canvas viewport into the model before the workspace is snapshotted.
    func prepareForSnapshot() {
        splitViewController.captureViewport()
    }

    /// Zoom the selected window to fit the viewport height ("~").
    func fitSelectedWindow() {
        splitViewController.fitSelectedItem()
    }

    /// Apply a saved window frame on launch (call before the window is shown). A frame that no
    /// longer intersects any screen (e.g. a disconnected external display) is ignored so the
    /// window can't be stranded off-screen — the centered default from `configure` stands.
    func restoreWindowFrame(_ frame: NSRect?) {
        guard let frame, let window else { return }
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return }
        window.setFrame(frame, display: false)
    }

    @objc private func windowGeometryChanged() {
        model.onPersistableChange?()
    }

    private func configure(_ window: NSWindow) {
        window.title = "Sprawl"
        window.titleVisibility = .hidden
        // Flat top bar: no system toolbar (so macOS 26 can't draw its rounded "glass" capsules).
        // A transparent titlebar over a solid #141414 window background; the bar itself (a custom
        // view at the top of the content) paints the #141414 fill and the 1px #383838 bottom border.
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(srgbRed: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()   // first-launch default; a saved frame is applied via restoreWindowFrame.

        // Persist on every OS-window move/resize (continuous autosave).
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowGeometryChanged),
                           name: NSWindow.didMoveNotification, object: window)
        center.addObserver(self, selector: #selector(windowGeometryChanged),
                           name: NSWindow.didResizeNotification, object: window)

        let split = MainSplitViewController(model: model)
        splitViewController = split

        // Root container hosting the flat top bar, the split view beneath it, and a "tab" row that
        // slides down from under the bar (content runs under the transparent titlebar via
        // .fullSizeContentView, so the bar occupies the very top edge). Assembly + z-order live in
        // MainSplitViewController.installChrome.
        let root = NSViewController()
        let container = NSView()
        root.view = container
        root.addChild(split)
        split.installChrome(in: container)
        window.contentViewController = root
    }
}
