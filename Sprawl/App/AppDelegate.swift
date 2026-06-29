import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let store = WorkspaceStore()
    private var mainWindowController: MainWindowController?
    private var scrollMonitor: Any?
    private var clickMonitor: Any?
    private var pendingSave: DispatchWorkItem?
    /// Carries fractional scroll lines across the many small events a trackpad emits.
    private var terminalScrollAccumulator: CGFloat = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()

        // Restore the saved workspace before the UI is built, so MainSplitViewController sees a
        // populated model and skips seeding a default project.
        let saved = store.load()
        if let saved {
            model.restore(saved)
        }
        // Autosave (debounced) whenever something persistable changes.
        model.onPersistableChange = { [weak self] in self?.scheduleSave() }

        let controller = MainWindowController(model: model)
        controller.restoreWindowFrame(saved?.windowFrame)   // before showing, so it doesn't flash
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        mainWindowController = controller

        installScrollPanMonitor()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        pendingSave?.cancel()
        saveNow()
    }

    /// Coalesce bursts of changes (drags, keystrokes, scroll) into a single write ~0.5s later.
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveNow() {
        mainWindowController?.prepareForSnapshot()
        var state = model.snapshot()
        state.windowFrame = mainWindowController?.window?.frame
        store.save(state)
    }

    /// Plain scroll over a terminal scrolls that terminal (its scrollback, or — on the alternate
    /// screen — the running TUI via arrow keys). SwiftTerm ignores trackpad scroll itself, so we
    /// drive it. Hold ⌥ to pan/zoom the canvas instead.
    private func installScrollPanMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  let contentView = event.window?.contentView,
                  let hit = contentView.hitTest(event.locationInWindow) else {
                return event
            }
            // ⌘ + scroll zooms the canvas wherever the cursor is over it — even over a terminal or
            // editor that would otherwise swallow the scroll.
            if event.modifierFlags.contains(.command), let canvas = hit.enclosingCanvasScrollView {
                canvas.scrollWheel(with: event)
                return nil
            }
            guard hit.isInsideTerminal else { return event }   // non-terminal: normal canvas pan/zoom
            if event.modifierFlags.contains(.option) {
                hit.enclosingCanvasScrollView?.scrollWheel(with: event)
                return nil     // ⌥ over a terminal: pan the canvas
            }
            let points = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 16
            hit.scrollEnclosingTerminal(points: points, locationInWindow: event.locationInWindow,
                                        accumulator: &self.terminalScrollAccumulator)
            return nil
        }

        // Clicking anywhere inside a panel selects that item — including terminal/document CONTENT,
        // which is the SwiftTerm/editor view (not the WindowView), so it never reaches the panel's
        // own mouseDown. Canvas (folder/empty) clicks fall through to CanvasView.mouseDown.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self,
                  let contentView = event.window?.contentView,
                  let hit = contentView.hitTest(event.locationInWindow),
                  let windowView = hit.enclosingWindowView,
                  let item = self.model.item(for: windowView) else {
                return event
            }
            self.model.selectItem(item)
            return event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // Programmatic main menu (no nib). Actions route through the responder chain to
    // MainSplitViewController.
    private func setupMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Sprawl",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Terminal",
                         action: #selector(MainSplitViewController.newTerminal(_:)),
                         keyEquivalent: "t")
        fileMenu.addItem(withTitle: "New Document",
                         action: #selector(MainSplitViewController.newDocument(_:)),
                         keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open File…",
                         action: #selector(MainSplitViewController.openDocument(_:)),
                         keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Save",
                         action: #selector(MainSplitViewController.saveDocument(_:)),
                         keyEquivalent: "s")
        fileMenu.addItem(.separator())
        let newProjectItem = NSMenuItem(title: "New Project",
                                        action: #selector(MainSplitViewController.newProject(_:)),
                                        keyEquivalent: "n")
        newProjectItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(newProjectItem)
        fileMenuItem.submenu = fileMenu

        // Edit menu — standard responder-chain actions so ⌘X/⌘C/⌘V/⌘A reach the focused
        // terminal or text field (SwiftTerm and NSTextField implement these). Without it,
        // ⌘V has nothing to route to and pasting into a terminal silently fails.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Zoom In",
                         action: #selector(MainSplitViewController.zoomIn(_:)),
                         keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom Out",
                         action: #selector(MainSplitViewController.zoomOut(_:)),
                         keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size",
                         action: #selector(MainSplitViewController.zoomReset(_:)),
                         keyEquivalent: "0")
        viewMenuItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }
}
