import AppKit

/// Composes the translucent sidebar and the canvas, and wires the model's change callbacks.
/// Also serves as the responder-chain target for the app's menu/toolbar actions.
final class MainSplitViewController: NSSplitViewController {
    let model: AppModel
    private let sidebarVC: SidebarViewController
    private let canvasVC: CanvasViewController
    private let annotateDock = NSView()        // small right-edge pill: Sticky / Text / Arrow
    private let optionsBar = OptionsBar(frame: .zero)
    private weak var optionsBarWindow: WindowView?

    // Top-bar group tabs (each opens a custom dropdown of tools) + click-to-place state.
    private weak var snapButton: NSButton?
    private weak var chromeContainer: NSView?     // hosts the top bar, the split view, and the dropdown
    private weak var topBarView: NSView?          // the flat top bar (dropdown anchors under it)
    private var dropdown: NSView?                 // the open group's dropdown (nil when closed)
    private var dropdownTop: NSLayoutConstraint?  // dropdown.top relative to the bar's bottom (animated)
    private var dropdownMonitor: Any?             // dismisses the dropdown on an outside click / ESC
    private var groupButtons: [Int: NSButton] = [:]
    private var activeGroupTag = -1               // which group's dropdown is open (-1 = closed)
    private var placeKind: WorkItem.Kind?
    private var placeMonitor: Any?

    // Connector drawing state (click-drag to place a two-point line).
    private var lineDrawing = false
    private weak var drawingItem: WorkItem?
    private weak var drawingPanel: LinePanel?
    private var drawMonitor: Any?
    private var lineGhost: NSView?
    private var drawTwoClick = false      // first node placed by a click; waiting for the 2nd click
    private var drawDidDrag = false       // the initial press moved (→ drag gesture, not a click)
    private var drawDownPoint = CGPoint.zero

    /// Notifies the toolbar when the current project changes (to update its name label).
    var onProjectChanged: ((Project?) -> Void)?

    init(model: AppModel) {
        self.model = model
        self.sidebarVC = SidebarViewController(model: model)
        self.canvasVC = CanvasViewController(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        addSplitViewItem(sidebarItem)

        let canvasItem = NSSplitViewItem(viewController: canvasVC)
        addSplitViewItem(canvasItem)

        splitView.autosaveName = "MainSplit"

        wireModel()
        installDock()

        // A restored workspace already has projects; only seed on a truly fresh launch. First-ever
        // launch shows the onboarding wizard; afterwards just seed an empty project.
        let isFreshLaunch = model.projects.isEmpty
        if isFreshLaunch {
            if UserDefaults.standard.bool(forKey: AppModel.hasOnboardedKey) {
                model.addProject(name: "Project 1")
            } else {
                model.beginOnboarding()
            }
        }
        canvasVC.restoreGlobalViewport()
        sidebarVC.reload()
        onProjectChanged?(model.currentProject)

        // Xcode-like default sidebar width on first launch only; a restored width is left to
        // the split view's autosave so it survives relaunch.
        if isFreshLaunch {
            DispatchQueue.main.async { [weak self] in
                self?.splitView.setPosition(260, ofDividerAt: 0)
            }
        }
    }

    /// The right-edge **Annotate** dock (Sticky / Text / Arrow) — small, icon-only. The rest of the
    /// tools live in the custom top bar (see `makeTopBar`).
    private func installDock() {
        annotateDock.wantsLayer = true
        annotateDock.layer?.backgroundColor = Palette.dockFill.cgColor
        annotateDock.layer?.cornerRadius = 18
        annotateDock.layer?.borderWidth = 1
        annotateDock.layer?.borderColor = Palette.dockBorder.cgColor
        annotateDock.layer?.shadowColor = NSColor.black.cgColor
        annotateDock.layer?.shadowOpacity = 0.45
        annotateDock.layer?.shadowRadius = 16
        annotateDock.layer?.shadowOffset = CGSize(width: -4, height: 0)
        annotateDock.layer?.masksToBounds = false
        annotateDock.translatesAutoresizingMaskIntoConstraints = false

        let sticky = DockButton(icon: LucideIcon.stickyNote, tooltip: "Sticky", compact: true) { [weak self] in self?.beginPlacement(.sticky) }
        let text = DockButton(icon: LucideIcon.type, tooltip: "Text", compact: true) { [weak self] in self?.beginPlacement(.freeText) }
        let arrow = DockButton(icon: LucideIcon.spline, tooltip: "Arrow", compact: true) { [weak self] in self?.beginLineDrawing() }
        let stack = NSStackView(views: [sticky, text, arrow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        annotateDock.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: annotateDock.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: annotateDock.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: annotateDock.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: annotateDock.trailingAnchor, constant: -8),
        ])

        canvasVC.view.addSubview(annotateDock)
        NSLayoutConstraint.activate([
            annotateDock.trailingAnchor.constraint(equalTo: canvasVC.view.trailingAnchor, constant: -16),
            annotateDock.centerYAnchor.constraint(equalTo: canvasVC.view.centerYAnchor),
        ])

        optionsBar.isHidden = true
        canvasVC.view.addSubview(optionsBar)   // floats above the selected annotation
    }

    // MARK: - Toolbar tool groups (Project / Ideate / Review / Create / Manage)

    /// Assemble the window's content: the flat top bar across the top and the split view filling the
    /// area beneath it. Clicking a group tab opens a custom dropdown (see openDropdown) added on top.
    func installChrome(in container: NSView) {
        chromeContainer = container
        let bar = makeTopBar()
        topBarView = bar
        view.translatesAutoresizingMaskIntoConstraints = false   // the split view

        container.addSubview(view)
        container.addSubview(bar)   // above the split view

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            view.topAnchor.constraint(equalTo: bar.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// The app's custom flat top bar (replaces the system NSToolbar so macOS 26 can't draw its
    /// rounded "glass" capsules around the items). A solid #141414 strip with a 1px #383838 bottom
    /// border: sidebar toggle, the tool groups, then undo/redo and the snap toggle on the right.
    /// Empty areas drag the window (`TopBar.mouseDownCanMoveWindow`).
    private func makeTopBar() -> NSView {
        let bar = TopBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 60).isActive = true

        func icon(_ symbol: String? = nil, lucide: [LucideIcon.Shape]? = nil, tip: String,
                  action: Selector, tag: Int = 0) -> NSButton {
            let image: NSImage
            if let symbol {
                image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
            } else if let lucide {
                image = LucideIcon.image(lucide, size: 18, color: Palette.dockIcon)
            } else {
                image = NSImage()
            }
            let b = NSButton(title: "", image: image, target: self, action: action)
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.imagePosition = .imageOnly
            b.contentTintColor = Palette.dockIcon
            b.toolTip = tip
            b.tag = tag
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 30).isActive = true
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
            return b
        }
        func divider() -> NSView {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor(srgbRed: 0x38 / 255, green: 0x38 / 255, blue: 0x38 / 255, alpha: 1).cgColor
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: 1).isActive = true
            v.heightAnchor.constraint(equalToConstant: 22).isActive = true
            return v
        }

        let sidebar = icon("sidebar.left", tip: "Toggle Sidebar", action: #selector(toggleSidebarAction))
        let project = icon(lucide: LucideIcon.folderPlus, tip: "New Project", action: #selector(newProjectAction))
        let left = NSStackView(views: [sidebar, divider(), project])
        left.orientation = .horizontal
        left.alignment = .centerY
        left.spacing = 8
        left.translatesAutoresizingMaskIntoConstraints = false

        let pill = makeGroupPill()   // the group tabs, centered in the bar

        let snap = icon("square.dashed", tip: "Snapping", action: #selector(cycleSnap))
        snapButton = snap
        let right = NSStackView(views: [
            icon("arrow.uturn.backward", tip: "Undo", action: #selector(undo(_:))),
            icon("arrow.uturn.forward", tip: "Redo", action: #selector(redo(_:))),
            divider(),
            icon("rectangle.grid.2x2", tip: "Tile Windows", action: #selector(showTileMenu(_:))),
            snap,
        ])
        right.orientation = .horizontal
        right.alignment = .centerY
        right.spacing = 8
        right.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(left)
        bar.addSubview(pill)
        bar.addSubview(right)
        NSLayoutConstraint.activate([
            // Leading inset clears the traffic-light cluster (window uses fullSizeContentView).
            left.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 84),
            left.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            pill.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            right.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            right.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        updateSnapButton()
        return bar
    }

    /// The four group tabs (Ideate / Review / Create / Manage) grouped in a rounded pill, like a
    /// segmented control. The open tab gets a white chip with a dark glyph (see updateGroupHighlights).
    private func makeGroupPill() -> NSView {
        func tab(_ lucide: [LucideIcon.Shape], _ tip: String, tag: Int) -> NSButton {
            let glyph = LucideIcon.image(lucide, size: 22, color: Palette.dockIcon)
            glyph.isTemplate = true   // so contentTintColor can flip it dark when selected
            let b = NSButton(title: "", image: glyph, target: self, action: #selector(toolbarGroupClicked(_:)))
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.imagePosition = .imageOnly
            b.contentTintColor = Palette.dockIcon
            b.toolTip = tip
            b.tag = tag
            b.wantsLayer = true
            b.layer?.cornerRadius = 9
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 44).isActive = true
            b.heightAnchor.constraint(equalToConstant: 34).isActive = true
            groupButtons[tag] = b
            return b
        }
        let stack = NSStackView(views: [
            tab(LucideIcon.lightbulb, "Ideate", tag: 1),
            tab(LucideIcon.chartColumn, "Review", tag: 2),
            tab(LucideIcon.appWindow, "Create", tag: 3),
            tab(LucideIcon.squareKanban, "Manage", tag: 4),
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(srgbRed: 0x1c / 255, green: 0x1c / 255, blue: 0x1c / 255, alpha: 1).cgColor
        pill.layer?.cornerRadius = 16
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = NSColor(srgbRed: 0x38 / 255, green: 0x38 / 255, blue: 0x38 / 255, alpha: 1).cgColor
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: pill.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -5),
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -6),
        ])
        return pill
    }

    @objc private func toggleSidebarAction() { toggleSidebar(nil) }

    @objc private func cycleSnap() {
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
        snapButton?.contentTintColor = model.snapGrid > 0 ? .controlAccentColor : Palette.dockIcon
    }

    @objc private func newProjectAction() { newProject(nil) }

    /// Tile the current project's windows into a uniform grid (⌥⌘T / View menu).
    @objc func tileWindows(_ sender: Any?) { model.tileCurrentProject() }

    /// The top-bar tile button drops a menu of layouts (Uniform / 2×2 / 3×3 / Columns / Pack).
    @objc private func showTileMenu(_ sender: NSButton) {
        let menu = NSMenu()
        func add(_ title: String, _ layout: TileLayout) {
            let item = menu.addItem(withTitle: title, action: #selector(tileLayoutPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = LayoutBox(layout)
        }
        add("Uniform Grid", .gridAuto)
        add("Grid 2×2", .grid(cols: 2))
        add("Grid 3×3", .grid(cols: 3))
        add("Columns", .columns)
        menu.addItem(.separator())
        add("Pack (keep sizes)", .pack)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func tileLayoutPicked(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? LayoutBox else { return }
        model.tileCurrentProject(layout: box.layout)
    }

    /// Clicking a group tab toggles its dropdown: the open group closes; another group switches.
    @objc private func toolbarGroupClicked(_ sender: NSButton) {
        let tag = sender.tag
        if activeGroupTag == tag {
            closeDropdown()
        } else {
            openDropdown(tag)
        }
    }

    private func toolsForGroup(_ tag: Int) -> [DockTool] {
        switch tag {
        case 1: return ideateTools()
        case 2: return reviewTools()
        case 3: return createTools()
        case 4: return manageTools()
        default: return []
        }
    }

    /// Open the group's custom dropdown beneath its tab: a rounded dark panel of rows, each an icon
    /// on the left with the tool's name beside it. Fades/slides in and dismisses on an outside click,
    /// ESC, picking a tool, or clicking the tab again.
    private func openDropdown(_ tag: Int) {
        closeDropdown()
        guard let container = chromeContainer, let bar = topBarView, let tab = groupButtons[tag] else { return }
        let panel = makeDropdown(toolsForGroup(tag))
        container.addSubview(panel)   // frontmost — over the bar and canvas
        let top = panel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 0)
        dropdownTop = top
        let centerX = panel.centerXAnchor.constraint(equalTo: tab.centerXAnchor)
        centerX.priority = NSLayoutConstraint.Priority(750)   // yields to the edge clamps below
        NSLayoutConstraint.activate([
            top, centerX,
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 8),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
        ])
        dropdown = panel
        activeGroupTag = tag
        updateGroupHighlights()

        panel.alphaValue = 0
        container.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
            top.constant = 6
            container.layoutSubtreeIfNeeded()
        }

        dropdownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let panel = self.dropdown, let container = self.chromeContainer else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.closeDropdown(); return nil }   // ESC
                return event
            }
            let point = container.convert(event.locationInWindow, from: nil)
            let onTab = self.groupButtons[self.activeGroupTag].map { container.convert($0.bounds, from: $0).contains(point) } ?? false
            if !panel.frame.contains(point) && !onTab { self.closeDropdown() }   // click outside → dismiss
            return event
        }
    }

    private func closeDropdown() {
        if let m = dropdownMonitor { NSEvent.removeMonitor(m); dropdownMonitor = nil }
        dropdown?.removeFromSuperview()
        dropdown = nil
        dropdownTop = nil
        activeGroupTag = -1
        updateGroupHighlights()
    }

    /// Build the dropdown panel: a rounded dark card holding one [icon  name] row per tool.
    private func makeDropdown(_ tools: [DockTool]) -> NSView {
        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(srgbRed: 0x1c / 255, green: 0x1c / 255, blue: 0x1c / 255, alpha: 1).cgColor
        panel.layer?.cornerRadius = 12
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor(srgbRed: 0x38 / 255, green: 0x38 / 255, blue: 0x38 / 255, alpha: 1).cgColor
        panel.layer?.shadowColor = NSColor.black.cgColor
        panel.layer?.shadowOpacity = 0.4
        panel.layer?.shadowRadius = 14
        panel.layer?.shadowOffset = CGSize(width: 0, height: -4)
        panel.layer?.masksToBounds = false

        let rows: [NSView]
        if tools.isEmpty {
            let label = NSTextField(labelWithString: "No tools in this group yet.")
            label.font = .systemFont(ofSize: 12)
            label.textColor = Palette.dockIcon.withAlphaComponent(0.5)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.heightAnchor.constraint(equalToConstant: 30).isActive = true
            rows = [label]
        } else {
            rows = tools.map { tool in
                let row = DropdownRow(icon: tool.icon, label: tool.tooltip) { [weak self] in
                    tool.onSelect()
                    self?.closeDropdown()
                }
                row.widthAnchor.constraint(equalToConstant: 184).isActive = true
                return row
            }
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -6),
        ])
        return panel
    }

    private func updateGroupHighlights() {
        let darkGlyph = NSColor(srgbRed: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255, alpha: 1)
        for (tag, btn) in groupButtons {
            let active = tag == activeGroupTag
            btn.layer?.backgroundColor = active ? NSColor.white.cgColor : NSColor.clear.cgColor
            btn.contentTintColor = active ? darkGlyph : Palette.dockIcon
        }
    }

    private func ideateTools() -> [DockTool] { [] }   // placeholder group
    private func manageTools() -> [DockTool] { [] }   // placeholder group
    private func reviewTools() -> [DockTool] {
        [DockTool(icon: LucideIcon.diff, tooltip: "Diff") { [weak self] in self?.beginPlacement(.diff) },
         DockTool(icon: LucideIcon.gauge, tooltip: "Velocity") { [weak self] in self?.beginPlacement(.projectVelocity) },
         DockTool(icon: LucideIcon.gitCommit, tooltip: "Observer") { [weak self] in self?.beginPlacement(.gitObserver) },
         DockTool(icon: LucideIcon.gitGraph, tooltip: "Graph") { [weak self] in self?.beginPlacement(.gitGraph) }]
    }
    private func createTools() -> [DockTool] {
        [DockTool(icon: LucideIcon.squareTerminal, tooltip: "Terminal") { [weak self] in self?.beginPlacement(.terminal) },
         DockTool(icon: LucideIcon.fileText, tooltip: "Document") { [weak self] in self?.beginPlacement(.document) },
         DockTool(icon: LucideIcon.code, tooltip: "Code") { [weak self] in self?.beginPlacement(.codeEditor) },
         DockTool(icon: LucideIcon.globe, tooltip: "Browser") { [weak self] in self?.beginPlacement(.browser) },
         DockTool(icon: LucideIcon.sparkles, tooltip: "Claude") { [weak self] in self?.beginPlacement(.assistant) }]
    }

    /// Show/configure the floating options bar for the selected annotation or git/analytics tool,
    /// or hide it.
    private func updateOptionsBar() {
        optionsBarWindow?.onGeometryChange2 = nil
        if model.isMultiSelect {   // multi-selection only supports Delete / Escape — no options bar
            optionsBar.isHidden = true
            optionsBarWindow = nil
            return
        }
        let repoKinds: Set<WorkItem.Kind> = [.gitObserver, .gitGraph, .projectVelocity, .codeEditor, .diff]
        let annotationKinds: Set<WorkItem.Kind> = [.sticky, .freeText]
        let lineKinds: Set<WorkItem.Kind> = [.line]
        guard let item = model.selectedItem,
              annotationKinds.contains(item.kind) || repoKinds.contains(item.kind)
                || lineKinds.contains(item.kind) || item.kind == .document,
              let window = item.window else {
            optionsBar.isHidden = true
            optionsBarWindow = nil
            return
        }
        if item.kind == .document {
            optionsBar.configureDocument(wrapOn: item.activeDocumentLeaf?.panel.wrapLines ?? true)
            optionsBar.onOpen = { [weak self] in self?.openDocument(nil) }
            optionsBar.onSave = { [weak self] in self?.saveDocument(nil) }
            optionsBar.onWrap = { [weak self] in
                guard let panel = item.activeDocumentLeaf?.panel else { return }
                panel.toggleWrap()
                self?.optionsBar.setDocWrap(panel.wrapLines)
            }
        } else if repoKinds.contains(item.kind) {
            optionsBar.configureRepo()
            optionsBar.onRepo = {
                switch item.kind {
                case .gitObserver: item.gitObserver?.chooseRepo()
                case .gitGraph: item.gitGraph?.chooseRepo()
                case .projectVelocity: item.projectVelocity?.chooseRepo()
                case .codeEditor: item.codeEditor?.chooseRepo()
                case .diff: item.diff?.chooseRepo()
                default: break
                }
            }
        } else if lineKinds.contains(item.kind) {
            let line = item.line
            optionsBar.configureLine(colorIndex: line?.colorIndex ?? 0,
                                     thickness: line?.thickness ?? 2,
                                     arrowStart: line?.hasArrowStart ?? false,
                                     arrowEnd: line?.hasArrowEnd ?? false)
            optionsBar.onColor = { index in item.line?.setColor(index) }
            optionsBar.onThickness = { t in item.line?.setThickness(t) }
            optionsBar.onArrowStart = { on in item.line?.setArrowStart(on) }
            optionsBar.onArrowEnd = { on in item.line?.setArrowEnd(on) }
        } else {
            let colorIndex = item.sticky?.colorIndex ?? item.freeText?.colorIndex ?? 0
            optionsBar.configure(showsFont: item.kind == .freeText, colorIndex: colorIndex,
                                 fontName: item.freeText?.fontName, fontSize: item.freeText?.fontSize)
            optionsBar.onColor = { index in item.sticky?.setColor(index); item.freeText?.setColor(index) }
            optionsBar.onFont = { name in item.freeText?.setFontName(name) }
            optionsBar.onSize = { size in item.freeText?.setFontSize(size) }
        }
        optionsBar.onDelete = { [weak self] in self?.model.removeItem(item) }
        optionsBar.isHidden = false
        optionsBarWindow = window
        window.onGeometryChange2 = { [weak self] in self?.positionOptionsBar() }
        positionOptionsBar()
    }

    private func positionOptionsBar() {
        guard !optionsBar.isHidden, let window = optionsBarWindow else { return }
        optionsBar.layoutSubtreeIfNeeded()
        let size = optionsBar.fittingSize
        let rect = canvasVC.view.convert(window.bounds, from: window)
        let y = canvasVC.view.isFlipped ? rect.minY - size.height - 8 : rect.maxY + 8
        optionsBar.setFrameSize(size)
        optionsBar.setFrameOrigin(NSPoint(x: rect.midX - size.width / 2, y: y))
    }

    /// Create an item in the focused project and pan the canvas to it (dock affordance).
    private func newItemFromDock(_ kind: WorkItem.Kind) {
        guard let item = model.addItem(kind: kind) else { return }
        canvasVC.centerOnItem(item)
    }

    // MARK: - Click-to-place

    /// Arm a dock tool: the next canvas click creates `kind` at that point. (Lines have their own
    /// multi-click flow.) ESC cancels.
    func beginPlacement(_ kind: WorkItem.Kind) {
        closeDropdown()
        if kind == .line { beginLineDrawing(); return }
        cancelPlacement()
        placeKind = kind
        model.isPlacing = true
        model.canvas.toolCursor = .crosshair
        NSCursor.crosshair.set()
        placeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] e in
            self?.handlePlacementEvent(e) ?? e
        }
    }

    private func handlePlacementEvent(_ e: NSEvent) -> NSEvent? {
        guard placeKind != nil else { return e }
        if e.type == .keyDown {
            if e.keyCode == 53 { cancelPlacement() }   // ESC
            return e
        }
        guard isCanvasDrawClick(e) else { return e }   // let dock / options bar work
        let p = model.canvas.convert(e.locationInWindow, from: nil)
        if let kind = placeKind, let project = model.currentProject ?? model.projects.first {
            _ = model.addItem(kind: kind, in: project, at: p)   // centered on the click; already in view
        }
        cancelPlacement()
        return nil
    }

    private func cancelPlacement() {
        guard placeKind != nil else { return }
        placeKind = nil
        model.isPlacing = false
        if let m = placeMonitor { NSEvent.removeMonitor(m); placeMonitor = nil }
        model.canvas.toolCursor = nil
        NSCursor.arrow.set()
    }

    // MARK: - Connector tool

    /// Arm the connector tool: the next press-drag-release on the canvas places a two-point line
    /// (press = start, release = end). A plain click drops a default-length connector. ESC cancels.
    func beginLineDrawing() {
        if lineDrawing { cancelLineDrawing() }
        lineDrawing = true
        model.isDrawingLine = true
        drawingItem = nil; drawingPanel = nil
        drawTwoClick = false; drawDidDrag = false
        closeDropdown()
        model.canvas.toolCursor = .crosshair
        NSCursor.crosshair.set()
        view.window?.acceptsMouseMovedEvents = true
        drawMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved, .keyDown]) { [weak self] e in
            self?.handleDrawingEvent(e) ?? e
        }
    }

    private func handleDrawingEvent(_ e: NSEvent) -> NSEvent? {
        guard lineDrawing else { return e }
        if e.type == .keyDown {
            if e.keyCode == 53 { cancelLineDrawing() }   // ESC cancels
            return e
        }
        guard isCanvasDrawClick(e) else { hideLineGhost(); return e }   // dock / sidebar / options bar work normally
        NSCursor.crosshair.set()
        let p = model.canvas.convert(e.locationInWindow, from: nil)
        switch e.type {
        case .mouseMoved:
            // Before the first click: preview the first node. After it (two-click mode): preview
            // where the next node will land — but don't render the line until the second click.
            if drawingPanel == nil || drawTwoClick { showLineGhost(atCanvas: snapCanvasPoint(p)) }
            return e
        case .leftMouseDown:
            if drawTwoClick {                         // second click → set the end and render the line
                hideLineGhost()
                drawingPanel?.setEnd(towardCanvas: p)
                finishLineDrawing()
                return nil
            }
            hideLineGhost()
            guard let created = model.createLine(firstNodeCanvas: p) else { cancelLineDrawing(); return nil }
            drawingItem = created.item; drawingPanel = created.panel
            drawDidDrag = false
            drawDownPoint = p
            positionOptionsBar()
            return nil
        case .leftMouseDragged:
            if drawingPanel == nil { return nil }
            if hypot(p.x - drawDownPoint.x, p.y - drawDownPoint.y) > 4 { drawDidDrag = true }
            drawingPanel?.setEnd(towardCanvas: p)
            positionOptionsBar()
            return nil
        case .leftMouseUp:
            // A press-drag-release places both ends at once; a plain click places only the first
            // node and waits for a second click (the line then follows the cursor).
            if drawDidDrag { finishLineDrawing() }
            else if drawingPanel != nil { drawTwoClick = true }
            return nil
        default:
            return e
        }
    }

    /// Snap a canvas point to the grid when snapping is on (matches the connector's own snapping).
    private func snapCanvasPoint(_ p: CGPoint) -> CGPoint {
        let g = model.canvas.snapGrid
        return g > 0 ? CGPoint(x: CanvasView.snap(p.x, to: g), y: CanvasView.snap(p.y, to: g)) : p
    }

    /// A small circle that previews where the first node will land (snapped) before the first click.
    private func showLineGhost(atCanvas p: CGPoint) {
        let ghost: NSView
        if let g = lineGhost { ghost = g } else {
            let g = NSView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
            g.wantsLayer = true
            g.layer?.cornerRadius = 6
            g.layer?.backgroundColor = NSColor.white.cgColor
            g.layer?.borderWidth = 2
            g.layer?.borderColor = NSColor.controlAccentColor.cgColor
            model.canvas.addSubview(g)
            lineGhost = g
            ghost = g
        }
        ghost.isHidden = false
        ghost.frame = NSRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)
    }

    private func hideLineGhost() {
        lineGhost?.removeFromSuperview()
        lineGhost = nil
    }

    /// Only treat clicks on the canvas surface as drawing; let docks / options bar work.
    private func isCanvasDrawClick(_ e: NSEvent) -> Bool {
        guard let hit = e.window?.contentView?.hitTest(e.locationInWindow) else { return false }
        if hit.isDescendant(of: annotateDock) || hit.isDescendant(of: optionsBar) {
            return false
        }
        guard let scroll = model.canvas.enclosingScrollView else { return false }
        return hit.isDescendant(of: scroll)
    }

    /// Release: keep the connector (giving a click-only a default length), then disarm.
    private func finishLineDrawing() {
        disarmLineDrawing()
        guard let item = drawingItem, let panel = drawingPanel else { return }
        if !panel.isPlaced { panel.extendToDefault() }   // a plain click → default-length connector
        model.finalizeLineCreation(item)
        updateOptionsBar()
        drawingItem = nil; drawingPanel = nil
    }

    /// ESC: drop the in-progress connector entirely.
    private func cancelLineDrawing() {
        disarmLineDrawing()
        if let item = drawingItem { model.discardItem(item) }
        drawingItem = nil; drawingPanel = nil
        updateOptionsBar()
    }

    private func disarmLineDrawing() {
        guard lineDrawing else { return }
        lineDrawing = false
        model.isDrawingLine = false
        if let m = drawMonitor { NSEvent.removeMonitor(m); drawMonitor = nil }
        drawTwoClick = false; drawDidDrag = false
        hideLineGhost()
        model.canvas.toolCursor = nil
        view.window?.acceptsMouseMovedEvents = false
        NSCursor.arrow.set()
    }

    /// Zoom the selected window to fit the viewport height ("~").
    func fitSelectedItem() {
        guard let item = model.selectedItem else { return }
        canvasVC.fitItemVertically(item)
    }

    /// Flush the live canvas viewport into the model so the next snapshot is current.
    func captureViewport() {
        canvasVC.captureCurrentViewport()
    }

    private func wireModel() {
        model.onModelChange = { [weak self] in self?.sidebarVC.reload() }
        model.onFocusProject = { [weak self] project in self?.canvasVC.focusProject(project) }
        model.onSelectionChange = { [weak self] in
            guard let self else { return }
            self.sidebarVC.syncSelection(self.model.selection)
            self.updateOptionsBar()
        }
        model.onOnboardingFinished = { }   // (the dock spotlight was removed with the dock rework)
        model.onRequestLineDrawing = { [weak self] in self?.beginLineDrawing() }
        // Current project changed — toolbar label only now (no canvas swap on the shared surface).
        model.onCurrentProjectChange = { [weak self] in
            guard let self else { return }
            self.onProjectChanged?(self.model.currentProject)
        }

        sidebarVC.onSelectProject = { [weak self] project in
            guard let self else { return }
            self.model.selectProject(project)
            self.canvasVC.focusProject(project)
        }
        sidebarVC.onSelectItem = { [weak self] item in
            guard let self else { return }
            self.model.selectItem(item)
            self.canvasVC.fitItemVertically(item)   // center + zoom to fill, like ⌘`
        }
        sidebarVC.onDeleteItem = { [weak self] item in self?.model.removeItem(item) }
        sidebarVC.onDeleteProject = { [weak self] project in self?.model.removeProject(project) }
        sidebarVC.onRenameItem = { [weak self] item, name in self?.model.renameItem(item, to: name) }
        sidebarVC.onRenameProject = { [weak self] project, name in self?.model.renameProject(project, to: name) }
        sidebarVC.onAddItem = { [weak self] kind in self?.model.addItem(kind: kind) }
        sidebarVC.onAddProject = { [weak self] in self?.newProject(nil) }
        sidebarVC.onOpenDocument = { [weak self] in self?.openDocument(nil) }

        canvasVC.onViewportChange = { [weak self] in
            self?.model.onPersistableChange?()
            self?.positionOptionsBar()
        }
    }

    // MARK: - Menu / toolbar actions (reached through the responder chain or directly)

    @objc func newTerminal(_ sender: Any?) { model.addItem(kind: .terminal) }
    @objc func newDocument(_ sender: Any?) { model.addItem(kind: .document) }
    @objc func newBrowser(_ sender: Any?) { model.addItem(kind: .browser) }
    @objc func newGitObserver(_ sender: Any?) { model.addItem(kind: .gitObserver) }
    @objc func newGitGraph(_ sender: Any?) { model.addItem(kind: .gitGraph) }
    @objc func newProjectVelocity(_ sender: Any?) { model.addItem(kind: .projectVelocity) }
    @objc func newClaude(_ sender: Any?) { model.addItem(kind: .assistant) }
    @objc func newSticky(_ sender: Any?) { model.addItem(kind: .sticky) }
    @objc func newFreeText(_ sender: Any?) { model.addItem(kind: .freeText) }
    @objc func newLine(_ sender: Any?) { beginLineDrawing() }
    @objc func replayOnboarding(_ sender: Any?) { model.beginOnboarding() }

    @objc func undo(_ sender: Any?) {
        // While editing text, ⌘Z undoes typing (the focused view's own undo); otherwise app history.
        if let responder = view.window?.firstResponder, AppDelegate.isEditingContent(responder),
           let manager = responder.undoManager, manager.canUndo {
            manager.undo(); return
        }
        model.history.undo()
    }

    @objc func redo(_ sender: Any?) {
        if let responder = view.window?.firstResponder, AppDelegate.isEditingContent(responder),
           let manager = responder.undoManager, manager.canRedo {
            manager.redo(); return
        }
        model.history.redo()
    }

    @objc func newProject(_ sender: Any?) {
        let anchor = canvasVC.freeAnchorNearViewport()
        let project = model.addProject(name: "Project \(model.projects.count + 1)", anchor: anchor)
        model.selectProject(project)
        canvasVC.focusProject(project)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            // Load into the focused document (its active tab); only make a new window if no
            // document is open to receive it.
            if let item = self.model.activeDocumentItem, let leaf = item.activeDocumentLeaf {
                leaf.panel.model.open(url: url)
                leaf.setName(url.lastPathComponent)   // retitle the tab + window
                item.name = url.lastPathComponent     // and the sidebar row
                self.model.onModelChange?()
                self.model.onPersistableChange?()
            } else {
                self.model.addItem(kind: .document, url: url)
            }
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let item = model.activeDocumentItem, let leaf = item.activeDocumentLeaf else { return }
        let doc = leaf.panel
        if doc.model.fileURL == nil {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = leaf.title
            panel.begin { [weak self, weak item] response in
                guard response == .OK, let url = panel.url else { return }
                doc.model.saveAs(url: url)
                leaf.setName(url.lastPathComponent)   // retitles the tab chip + window
                item?.name = url.lastPathComponent    // keep the sidebar row + persisted name in sync
                self?.model.onModelChange?()
                self?.model.onPersistableChange?()
            }
        } else {
            doc.save()
        }
    }

    @objc func fitWindowToScreen(_ sender: Any?) { fitSelectedItem() }

    @objc func zoomIn(_ sender: Any?) { canvasVC.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { canvasVC.zoomOut() }
    @objc func zoomReset(_ sender: Any?) { canvasVC.zoomReset() }
}

/// The flat custom top bar: a solid #141414 strip with a 1px #383838 bottom border. Dragging an
/// empty part of the bar moves the window (button subviews still receive their own clicks).
final class TopBar: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255, alpha: 1).setFill()
        bounds.fill()
        NSColor(srgbRed: 0x38 / 255, green: 0x38 / 255, blue: 0x38 / 255, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()   // bottom seam (non-flipped: y=0)
    }
}
