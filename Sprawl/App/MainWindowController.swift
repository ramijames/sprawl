import AppKit

final class MainWindowController: NSWindowController, NSToolbarDelegate {
    private let model: AppModel
    private var splitViewController: MainSplitViewController!
    private weak var snapButton: NSButton?

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
        // Let the unified toolbar render its system material (Liquid Glass on macOS 26) instead of
        // being fully transparent — gives the top bar a frosted-glass look over the canvas.
        window.titlebarAppearsTransparent = false
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
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .undo, .redo, .snapToggle]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .space, .undo, .redo, .snapToggle]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        // Creation lives in the dock / right-click / ⌘1-9 and zoom in the View menu / ⌘-scroll;
        // the toolbar keeps undo/redo and the snapping toggle (right side).
        switch itemIdentifier {
        case .snapToggle: return makeSnapItem()
        case .undo: return makeActionItem(.undo, symbol: "arrow.uturn.backward", label: "Undo",
                                          action: #selector(MainSplitViewController.undo(_:)))
        case .redo: return makeActionItem(.redo, symbol: "arrow.uturn.forward", label: "Redo",
                                          action: #selector(MainSplitViewController.redo(_:)))
        default: return nil
        }
    }

    /// A toolbar button whose action routes through the responder chain (target nil) to the
    /// split-view controller's undo/redo.
    private func makeActionItem(_ id: NSToolbarItem.Identifier, symbol: String, label: String,
                                action: Selector) -> NSToolbarItem {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        let button = NSButton(title: "", image: image ?? NSImage(), target: nil, action: action)
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.toolTip = label
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = button
        item.label = label
        return item
    }

    private func makeSnapItem() -> NSToolbarItem {
        let button = NSButton(title: "", image: NSImage(), target: self, action: #selector(cycleSnap(_:)))
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        snapButton = button
        let item = NSToolbarItem(itemIdentifier: .snapToggle)
        item.view = button
        item.label = "Snapping"
        updateSnapButton()
        return item
    }

    @objc private func cycleSnap(_ sender: NSButton) {
        switch model.snapGrid {
        case 0: model.snapGrid = 10
        case 10: model.snapGrid = 100
        default: model.snapGrid = 0
        }
        updateSnapButton()
    }

    private func updateSnapButton() {
        let symbol: String, tip: String
        switch model.snapGrid {
        case 10: symbol = "square.grid.3x3"; tip = "Snapping: 10 px grid"
        case 100: symbol = "square.grid.2x2"; tip = "Snapping: 100 px grid"
        default: symbol = "square.dashed"; tip = "Snapping: Off"
        }
        snapButton?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        snapButton?.toolTip = tip
        snapButton?.contentTintColor = model.snapGrid > 0 ? .controlAccentColor : nil
    }
}

private extension NSToolbarItem.Identifier {
    static let snapToggle = NSToolbarItem.Identifier("snapToggle")
    static let undo = NSToolbarItem.Identifier("undo")
    static let redo = NSToolbarItem.Identifier("redo")
}
