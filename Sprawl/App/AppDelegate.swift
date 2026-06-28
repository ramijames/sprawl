import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let store = WorkspaceStore()
    private var mainWindowController: MainWindowController?
    private var scrollMonitor: Any?
    private var pendingSave: DispatchWorkItem?

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

    /// SwiftTerm consumes trackpad scroll for its own scrollback, so it never reaches the canvas.
    /// This monitor redirects scrolls that land on a terminal to the enclosing canvas (so you can
    /// pan/zoom over terminals); hold ⌥ to scroll the terminal's scrollback instead.
    private func installScrollPanMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard !event.modifierFlags.contains(.option),
                  let contentView = event.window?.contentView,
                  let hit = contentView.hitTest(event.locationInWindow),
                  hit.isInsideTerminal,
                  let scrollView = hit.enclosingScrollView as? CanvasScrollView else {
                return event
            }
            scrollView.scrollWheel(with: event)
            return nil
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
