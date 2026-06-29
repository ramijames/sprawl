import AppKit

/// Anything that supports ⌘T / ⌘W on the selected window: a browser, or a tabbed terminal /
/// document container.
protocol Tabbable: AnyObject {
    func openNewTab()
    func closeCurrentTab()
}

/// One tab's content inside a `TabbedContainer` — a terminal or a document.
protocol ContentTab: AnyObject {
    var view: NSView { get }
    var title: String { get }
    /// The content retitled itself (shell title, file rename) — container updates the chip/window.
    var onTitleChange: ((String) -> Void)? { get set }
    /// The content asked to close (e.g. a terminal's shell exited) — container closes this tab.
    var onRequestClose: (() -> Void)? { get set }
    /// Persistable content changed (terminal cwd, document text) — container bubbles for autosave.
    var onContentChange: (() -> Void)? { get set }
    func focus()
}

/// Hosts one or more same-kind tabs (terminals or documents) behind a shared tab strip, showing
/// only the active tab's view. Mirrors the browser's tab UX so ⌘T / ⌘W behave the same everywhere.
final class TabbedContainer: NSObject, Tabbable {
    let containerView = NSView()
    private let tabBar = BrowserTabBar(frame: .zero)
    private let contentArea = NSView()
    private var tabBarHeight: NSLayoutConstraint!

    private(set) var leaves: [ContentTab] = []
    private(set) var activeIndex = 0
    var activeLeaf: ContentTab? { leaves.indices.contains(activeIndex) ? leaves[activeIndex] : nil }

    /// Factory for a brand-new tab (⌘T / the + button), supplied by the model.
    var makeLeaf: (() -> ContentTab)?
    /// Active tab's title changed — drives the window title.
    var onActiveTitleChange: ((String) -> Void)?
    /// The last tab was closed — close the whole window/item.
    var onRequestClose: (() -> Void)?
    /// A tab was added/removed/reselected — reload the sidebar and autosave.
    var onStructureChange: (() -> Void)?
    /// A tab's content changed — autosave only.
    var onContentChange: (() -> Void)?

    override init() {
        super.init()
        build()
    }

    private func build() {
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = Palette.panelBody.cgColor
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onSelect = { [weak self] index in self?.selectTab(at: index) }
        tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }
        tabBar.onNewTab = { [weak self] in self?.openNewTab() }
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(tabBar)
        containerView.addSubview(contentArea)
        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 32)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: containerView.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            tabBarHeight,
            contentArea.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentArea.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            contentArea.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
    }

    func attach(to window: WindowView) { window.setContent(containerView) }

    /// Add a leaf (used by the model when creating/restoring). Wires the leaf's callbacks to this
    /// container. Pass `select: true` to make it the active tab.
    func addLeaf(_ leaf: ContentTab, select: Bool) {
        leaf.onTitleChange = { [weak self, weak leaf] _ in
            guard let self, let leaf, let index = self.indexOf(leaf) else { return }
            self.rebuildTabBar()
            if index == self.activeIndex { self.onActiveTitleChange?(leaf.title) }
        }
        leaf.onRequestClose = { [weak self, weak leaf] in
            guard let self, let leaf, let index = self.indexOf(leaf) else { return }
            self.closeTab(at: index)
        }
        leaf.onContentChange = { [weak self] in self?.onContentChange?() }
        leaves.append(leaf)
        if select { selectTab(at: leaves.count - 1) } else { rebuildTabBar() }
    }

    /// Select a tab by index (clamped). `focus` makes the tab's content first responder — true for
    /// user actions, false when restoring so we don't steal focus across many restored windows.
    func selectTab(at index: Int, focus: Bool = true) {
        guard !leaves.isEmpty else { return }
        activeIndex = min(max(0, index), leaves.count - 1)
        let leaf = leaves[activeIndex]
        contentArea.subviews.forEach { $0.removeFromSuperview() }
        let view = leaf.view
        view.translatesAutoresizingMaskIntoConstraints = false
        contentArea.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentArea.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
        ])
        rebuildTabBar()
        onActiveTitleChange?(leaf.title)
        if focus { leaf.focus() }
    }

    // MARK: - Tabbable

    func openNewTab() {
        guard let leaf = makeLeaf?() else { return }
        addLeaf(leaf, select: true)
        onStructureChange?()
    }

    func closeCurrentTab() { closeTab(at: activeIndex) }

    private func closeTab(at index: Int) {
        guard leaves.indices.contains(index) else { return }
        if leaves.count == 1 { onRequestClose?(); return }   // last tab → close the window/item
        let closedActive = (index == activeIndex)
        let leaf = leaves.remove(at: index)
        leaf.view.removeFromSuperview()
        if index < activeIndex { activeIndex -= 1 }
        if closedActive {
            selectTab(at: min(activeIndex, leaves.count - 1))   // bring a neighbor forward + focus it
        } else {
            rebuildTabBar()   // active tab unchanged — don't tear down its view or steal focus
        }
        onStructureChange?()
    }

    private func indexOf(_ leaf: ContentTab) -> Int? { leaves.firstIndex { $0 === leaf } }

    private func rebuildTabBar() {
        tabBar.setTabs(titles: leaves.map { $0.title }, activeIndex: activeIndex)
        let show = leaves.count > 1   // a lone tab hides the strip
        tabBar.isHidden = !show
        tabBarHeight.constant = show ? 32 : 0
    }
}

/// A terminal tab: wraps a `TerminalPanel` as `ContentTab`.
final class TerminalLeaf: NSObject, ContentTab {
    let panel: TerminalPanel
    private(set) var title: String
    var onTitleChange: ((String) -> Void)?
    var onRequestClose: (() -> Void)?
    var onContentChange: (() -> Void)?

    var view: NSView { panel.terminalView }

    init(startDirectory: String?, name: String) {
        panel = TerminalPanel(startDirectory: startDirectory)
        title = name
        super.init()
        panel.onTitleChange = { [weak self] newTitle in
            guard let self, !newTitle.isEmpty else { return }
            self.title = newTitle
            self.onTitleChange?(newTitle)
        }
        panel.onProcessTerminated = { [weak self] in self?.onRequestClose?() }
        panel.onDirectoryChange = { [weak self] in self?.onContentChange?() }
    }

    func focus() { panel.focus() }
}

/// A document tab: wraps a `DocumentPanel` as `ContentTab`.
final class DocumentLeaf: NSObject, ContentTab {
    let panel: DocumentPanel
    private(set) var title: String
    var onTitleChange: ((String) -> Void)?
    var onRequestClose: (() -> Void)?
    var onContentChange: (() -> Void)?

    var view: NSView { panel.contentView }

    init(fileURL: URL?, initialText: String?, name: String) {
        panel = DocumentPanel(fileURL: fileURL, initialText: initialText)
        title = name
        super.init()
        panel.onTextChange = { [weak self] in self?.onContentChange?() }
    }

    /// Rename the tab (after a Save As) so the chip and window title follow the file.
    func setName(_ name: String) {
        title = name
        onTitleChange?(name)
    }

    func focus() { panel.contentView.window?.makeFirstResponder(panel.contentView) }
}
