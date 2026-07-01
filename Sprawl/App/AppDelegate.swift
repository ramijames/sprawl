import AppKit
import ObjectiveC

extension NSScroller {
    /// Force thin, auto-hiding overlay scrollers app-wide — even when the user's system setting is
    /// "Show scroll bars: Always", which otherwise gives every scroll view (including the editor,
    /// terminal, and web views we don't own) thick legacy scrollbars. Done by overriding the
    /// class getter `preferredScrollerStyle` so scroll views created afterward pick up overlay.
    static func forceOverlayStyleAppWide() {
        guard let method = class_getClassMethod(NSScroller.self, NSSelectorFromString("preferredScrollerStyle")) else { return }
        let block: @convention(block) (AnyObject) -> NSScroller.Style = { _ in .overlay }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let store = WorkspaceStore()
    private var mainWindowController: MainWindowController?
    private var scrollMonitor: Any?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    /// ⌘/⌥ flags captured at the start of a trackpad scroll gesture, so a modifier pressed
    /// mid-scroll can't turn an in-progress plain scroll into a zoom/pan.
    private var scrollGestureModifiers: NSEvent.ModifierFlags = []
    private var pendingSave: DispatchWorkItem?
    /// Carries fractional scroll lines across the many small events a trackpad emits.
    private var terminalScrollAccumulator: CGFloat = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        CrashReporter.install()                 // capture crashes to console.log before anything else
        NSScroller.forceOverlayStyleAppWide()   // thin scrollers everywhere, before any are created
        AdBlocker.shared.prewarm()              // compile ad/tracker rules before any browser opens
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
            // Lock the ⌘/⌥ decision at the START of a trackpad gesture so a modifier pressed
            // mid-scroll can't flip an in-progress plain scroll into a zoom/pan. Mouse wheels
            // (no phase) use the live modifiers.
            if event.phase.contains(.began) { self.scrollGestureModifiers = event.modifierFlags }
            let isGesture = event.phase != [] || event.momentumPhase != []
            let modifiers = isGesture ? self.scrollGestureModifiers : event.modifierFlags

            // ⌘ zooms / ⌥ pans the canvas, no matter what's under the cursor.
            if let canvas = hit.enclosingCanvasScrollView {
                if modifiers.contains(.command) { canvas.zoom(with: event); return nil }
                if modifiers.contains(.option) { canvas.pan(with: event); return nil }
            }
            // Plain scroll over a terminal scrolls its buffer.
            if hit.isInsideTerminal {
                let points = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 16
                hit.scrollEnclosingTerminal(points: points, locationInWindow: event.locationInWindow,
                                            accumulator: &self.terminalScrollAccumulator)
                return nil
            }
            // Otherwise let the content under the cursor scroll itself (browser page, editor, file
            // list). Over empty canvas this reaches CanvasScrollView, which ignores plain scroll —
            // moving the canvas requires ⌥.
            return event
        }

        // Clicking anywhere inside a panel selects that item — including terminal/document CONTENT,
        // which is the SwiftTerm/editor view (not the WindowView), so it never reaches the panel's
        // own mouseDown. Canvas (folder/empty) clicks fall through to CanvasView.mouseDown.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            if self.model.isDrawingLine || self.model.isPlacing { return event }   // a tool owns clicks
            guard let contentView = event.window?.contentView,
                  let hit = contentView.hitTest(event.locationInWindow),
                  let windowView = hit.enclosingWindowView,
                  let item = self.model.item(for: windowView) else {
                return event
            }
            if event.modifierFlags.contains(.shift) { self.model.toggleItemSelection(item) }
            else { self.model.selectItem(item) }
            return event
        }

        // ⌘T / ⌘W act on the SELECTED browser window, regardless of keyboard focus. This monitor
        // runs before the menu/responder chain (and before WKWebView can swallow the keys), so the
        // shortcuts work whenever a browser window is selected — not only after clicking the page.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.model.isDrawingLine || self.model.isPlacing { return event }   // a tool handles keys (ESC)

            // Delete / forward-delete removes the SELECTED item (or project) — unless focus is inside
            // an editable content view (text/terminal/browser/editor), where it edits text instead.
            if (event.keyCode == 51 || event.keyCode == 117),
               event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
               !AppDelegate.isEditingContent(event.window?.firstResponder) {
                if !self.model.selectedItemIDs.isEmpty {
                    self.model.deleteSelection(); return nil   // removes every selected item
                }
                if case .project(let id) = self.model.selection,
                   let project = self.model.projects.first(where: { $0.id == id }) {
                    self.model.removeProject(project); return nil
                }
                return event
            }

            // Escape clears the selection. It passes through to a focused terminal/editor/browser
            // (where Esc is meaningful, e.g. vim) — but an annotation text field deselects instead.
            if event.keyCode == 53,
               event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
                let responder = event.window?.firstResponder
                if responder is AnnotationTextView || !AppDelegate.isEditingContent(responder) {
                    self.model.clearSelection()
                    return nil
                }
                return event
            }

            // These act on the SELECTED window regardless of keyboard focus, so they run before the
            // menu/responder chain (and before a terminal/WebKit can swallow them).
            guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                  let key = event.charactersIgnoringModifiers else {
                return event
            }
            // ⌘F opens find-in-page on the selected browser.
            if key == "f", let browser = self.model.selectedItem?.browser {
                browser.showFind()
                return nil
            }
            // ⌘W closes the active file tab of the selected Code editor (its tabs aren't Tabbable tabs).
            if key == "w", let editor = self.model.selectedItem?.codeEditor {
                if !event.isARepeat { editor.closeCurrentTab() }
                return nil
            }
            // ⌘T / ⌘W — new/close tab on the selected window (browser, terminal, document, files).
            if key == "t" || key == "w", let tabbable = self.model.selectedTabbable {
                if !event.isARepeat {
                    if key == "t" { tabbable.openNewTab() } else { tabbable.closeCurrentTab() }
                }
                return nil
            }
            return event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private lazy var preferencesController = PreferencesWindowController()

    @objc func showPreferences(_ sender: Any?) {
        preferencesController.present()
    }

    /// True if the responder is inside a panel's content area (a text editor, terminal, browser, …),
    /// so Delete should edit rather than remove the selected object.
    static func isEditingContent(_ responder: NSResponder?) -> Bool {
        var view = responder as? NSView
        while let current = view {
            if current is ContentContainerView { return true }
            view = current.superview
        }
        return false
    }

    // Programmatic main menu (no nib). Actions route through the responder chain to
    // MainSplitViewController.
    private func setupMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Sprawl",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Preferences…",
                        action: #selector(AppDelegate.showPreferences(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Sprawl",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Sprawl",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Terminal",
                         action: #selector(MainSplitViewController.newTerminal(_:)),
                         keyEquivalent: "1")
        fileMenu.addItem(withTitle: "New Document",
                         action: #selector(MainSplitViewController.newDocument(_:)),
                         keyEquivalent: "2")
        fileMenu.addItem(withTitle: "New Browser",
                         action: #selector(MainSplitViewController.newBrowser(_:)),
                         keyEquivalent: "3")
        fileMenu.addItem(withTitle: "New Git Observer",
                         action: #selector(MainSplitViewController.newGitObserver(_:)),
                         keyEquivalent: "4")
        fileMenu.addItem(withTitle: "New Git Graph",
                         action: #selector(MainSplitViewController.newGitGraph(_:)),
                         keyEquivalent: "5")
        fileMenu.addItem(withTitle: "New Project Velocity",
                         action: #selector(MainSplitViewController.newProjectVelocity(_:)),
                         keyEquivalent: "6")
        fileMenu.addItem(withTitle: "New Claude",
                         action: #selector(MainSplitViewController.newClaude(_:)),
                         keyEquivalent: "7")
        fileMenu.addItem(withTitle: "New Sticky Pad",
                         action: #selector(MainSplitViewController.newSticky(_:)),
                         keyEquivalent: "8")
        fileMenu.addItem(withTitle: "New Free Text",
                         action: #selector(MainSplitViewController.newFreeText(_:)),
                         keyEquivalent: "9")
        fileMenu.addItem(withTitle: "New Line",
                         action: #selector(MainSplitViewController.newLine(_:)),
                         keyEquivalent: "0")
        // ⌘T opens a tab in the focused browser; auto-disabled when no browser is focused (the
        // action is only implemented by NavigatingWebView).
        fileMenu.addItem(withTitle: "New Tab",
                         action: #selector(NavigatingWebView.newBrowserTab(_:)),
                         keyEquivalent: "t")
        // ⌘W closes the focused browser's active tab (closing the last tab closes the panel);
        // auto-disabled when no browser is focused.
        fileMenu.addItem(withTitle: "Close Tab",
                         action: #selector(NavigatingWebView.closeBrowserTab(_:)),
                         keyEquivalent: "w")
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
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Replay Onboarding…",
                         action: #selector(MainSplitViewController.replayOnboarding(_:)),
                         keyEquivalent: "")
        fileMenuItem.submenu = fileMenu

        // Edit menu — standard responder-chain actions so ⌘X/⌘C/⌘V/⌘A reach the focused
        // terminal or text field (SwiftTerm and NSTextField implement these). Without it,
        // ⌘V has nothing to route to and pasting into a terminal silently fails.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo",
                         action: #selector(MainSplitViewController.undo(_:)), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo",
                                  action: #selector(MainSplitViewController.redo(_:)), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Command Palette…",
                         action: #selector(MainSplitViewController.showCommandPalette(_:)),
                         keyEquivalent: "k")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Toggle Sidebar",
                         action: #selector(NSSplitViewController.toggleSidebar(_:)),
                         keyEquivalent: "\\")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Zoom In",
                         action: #selector(MainSplitViewController.zoomIn(_:)),
                         keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom Out",
                         action: #selector(MainSplitViewController.zoomOut(_:)),
                         keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size",
                         action: #selector(MainSplitViewController.zoomReset(_:)),
                         keyEquivalent: "0")
        viewMenu.addItem(.separator())
        // ⌘` as a menu key equivalent reliably claims the shortcut (a bare local monitor loses it
        // to macOS's built-in "cycle windows"). Routed through the responder chain to the split VC.
        viewMenu.addItem(withTitle: "Fit Window to Screen",
                         action: #selector(MainSplitViewController.fitWindowToScreen(_:)),
                         keyEquivalent: "`")
        let tile = viewMenu.addItem(withTitle: "Tile Windows",
                                    action: #selector(MainSplitViewController.tileWindows(_:)),
                                    keyEquivalent: "t")
        tile.keyEquivalentModifierMask = [.command, .option]
        let format = viewMenu.addItem(withTitle: "Format Document",
                                      action: #selector(MainSplitViewController.formatDocument(_:)),
                                      keyEquivalent: "f")
        format.keyEquivalentModifierMask = [.command, .option, .shift]
        let rename = viewMenu.addItem(withTitle: "Rename Symbol",
                                      action: #selector(MainSplitViewController.renameSymbol(_:)),
                                      keyEquivalent: "r")
        rename.keyEquivalentModifierMask = [.command, .option]
        viewMenuItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }
}
