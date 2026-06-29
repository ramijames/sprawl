import AppKit

final class MainWindowController: NSWindowController, NSToolbarDelegate {
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
        window.titlebarAppearsTransparent = true
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
        window.contentViewController = split

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .zoomControls, .addEntry]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .space, .zoomControls, .addEntry]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .zoomControls: return makeZoomItem()
        case .addEntry: return makeAddItem()
        default: return nil
        }
    }

    private func makeZoomItem() -> NSToolbarItem {
        let segmented = NSSegmentedControl(
            labels: ["\u{2212}", "1:1", "+"],
            trackingMode: .momentary,
            target: self,
            action: #selector(zoomSegment(_:)))
        segmented.segmentStyle = .texturedRounded
        let item = NSToolbarItem(itemIdentifier: .zoomControls)
        item.view = segmented
        item.label = "Zoom"
        return item
    }

    private func makeAddItem() -> NSToolbarItem {
        let image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")
        let button = NSButton(title: "", image: image ?? NSImage(), target: self, action: #selector(showAddMenu(_:)))
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        let item = NSToolbarItem(itemIdentifier: .addEntry)
        item.view = button
        item.label = "Add"
        return item
    }

    @objc private func zoomSegment(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: splitViewController.zoomOut(nil)
        case 1: splitViewController.zoomReset(nil)
        case 2: splitViewController.zoomIn(nil)
        default: break
        }
    }

    @objc private func showAddMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Terminal", action: #selector(MainSplitViewController.newTerminal(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "New Document", action: #selector(MainSplitViewController.newDocument(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "New Browser", action: #selector(MainSplitViewController.newBrowser(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Open File…", action: #selector(MainSplitViewController.openDocument(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "New Project", action: #selector(MainSplitViewController.newProject(_:)), keyEquivalent: "")
        menu.items.forEach { $0.target = splitViewController }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }
}

private extension NSToolbarItem.Identifier {
    static let zoomControls = NSToolbarItem.Identifier("zoomControls")
    static let addEntry = NSToolbarItem.Identifier("addEntry")
}
