import AppKit

/// A floating, rounded toolbar pinned to the bottom-center of the canvas. A standalone Project
/// button plus grouped "folders" (Apps / Git / Analytics) whose icons open a flyout menu of the
/// windows they create in the focused project. Uses Lucide icons. Sizes itself to its content.
final class FloatingDock: NSView {
    var onNewProject: (() -> Void)?
    var onNewTerminal: (() -> Void)?
    var onNewDocument: (() -> Void)?
    var onNewBrowser: (() -> Void)?
    var onNewGitObserver: (() -> Void)?
    var onNewGitGraph: (() -> Void)?
    var onNewProjectVelocity: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = Palette.dockFill.cgColor
        layer?.cornerRadius = 18
        layer?.borderWidth = 1
        layer?.borderColor = Palette.dockBorder.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        layer?.masksToBounds = false

        let projectButton = DockButton(icon: LucideIcon.folderPlus, tooltip: "New Project") { [weak self] in self?.onNewProject?() }

        let appsButton = makeFolderButton(icon: LucideIcon.layoutGrid, tooltip: "Apps") { [weak self] menu in
            guard let self else { return }
            menu.addItem(self.folderItem("New Terminal", LucideIcon.squareTerminal) { self.onNewTerminal?() })
            menu.addItem(self.folderItem("New Document", LucideIcon.fileText) { self.onNewDocument?() })
            menu.addItem(self.folderItem("New Browser", LucideIcon.globe) { self.onNewBrowser?() })
        }
        let gitButton = makeFolderButton(icon: LucideIcon.gitBranch, tooltip: "Git") { [weak self] menu in
            guard let self else { return }
            menu.addItem(self.folderItem("New Git Observer", LucideIcon.gitCommit) { self.onNewGitObserver?() })
            menu.addItem(self.folderItem("New Git Graph", LucideIcon.gitGraph) { self.onNewGitGraph?() })
        }
        let analyticsButton = makeFolderButton(icon: LucideIcon.chartColumn, tooltip: "Analytics") { [weak self] menu in
            guard let self else { return }
            menu.addItem(self.folderItem("New Project Velocity", LucideIcon.gauge) { self.onNewProjectVelocity?() })
        }

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Palette.dockBorder.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let stack = NSStackView(views: [projectButton, divider, appsButton, gitButton, analyticsButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    /// A DockButton that, when clicked, builds a fresh dark menu (via `populate`) and pops it up
    /// above itself. The dock sits at the screen bottom, so NSMenu auto-flips and opens upward.
    private func makeFolderButton(icon: [LucideIcon.Shape], tooltip: String,
                                  populate: @escaping (NSMenu) -> Void) -> DockButton {
        let holder = MenuHolder(populate: populate)
        let button = DockButton(icon: icon, tooltip: tooltip, caret: true) { [weak self] in
            self?.popFolderMenu(holder)
        }
        holder.button = button
        return button
    }

    private func popFolderMenu(_ holder: MenuHolder) {
        guard let button = holder.button, let window = button.window else { return }
        let menu = NSMenu()
        menu.appearance = NSAppearance(named: .darkAqua)
        menu.autoenablesItems = false
        holder.populate(menu)
        // Place the menu in SCREEN coordinates so it sits fully *above* the dock (which lives at the
        // bottom of the screen). Menus grow downward from their top-left, so we put the top-left a
        // full menu-height above the button's top edge → the menu's bottom lands just above it.
        let menuHeight = menu.size.height > 0 ? menu.size.height : CGFloat(menu.items.count) * 24 + 12
        let buttonTopInWindow = button.convert(NSPoint(x: 0, y: button.bounds.height), to: nil)
        let buttonTopOnScreen = window.convertPoint(toScreen: buttonTopInWindow)
        let topLeft = NSPoint(x: buttonTopOnScreen.x, y: buttonTopOnScreen.y + menuHeight + 6)
        menu.popUp(positioning: nil, at: topLeft, in: nil)   // in: nil → `at` is screen coordinates
    }

    /// A dark menu item carrying a Lucide icon and a click closure.
    private func folderItem(_ title: String, _ icon: [LucideIcon.Shape],
                            _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
        let target = MenuAction(action)
        item.target = target
        item.representedObject = target          // retain the target for the item's lifetime
        item.image = LucideIcon.image(icon, size: 15, color: Palette.dockIcon)
        return item
    }
}

/// Holds a folder button + its menu-populating closure (the button is created after the closure).
private final class MenuHolder {
    weak var button: DockButton?
    let populate: (NSMenu) -> Void
    init(populate: @escaping (NSMenu) -> Void) { self.populate = populate }
}

/// Bridges a plain closure to an `@objc` menu-item action.
private final class MenuAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action; super.init() }
    @objc func fire() { action() }
}

/// A square icon button with a rounded hover highlight, for the floating dock.
final class DockButton: NSButton {
    private let onClick: () -> Void
    private var trackingArea: NSTrackingArea?

    init(icon: [LucideIcon.Shape], tooltip: String, caret: Bool = false, action: @escaping () -> Void) {
        onClick = action
        let width: CGFloat = caret ? 52 : 38   // folder buttons are wider to fit the disclosure caret
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 38))
        wantsLayer = true
        layer?.cornerRadius = 9
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        image = caret ? DockButton.iconWithCaret(icon) : LucideIcon.image(icon, size: 22, color: Palette.dockIcon)
        toolTip = tooltip
        target = self
        self.action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 38).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Compose a Lucide icon with a small down-caret to its right (marks a button that opens a menu).
    private static func iconWithCaret(_ icon: [LucideIcon.Shape]) -> NSImage {
        let iconSize: CGFloat = 22, caretSize: CGFloat = 9, gap: CGFloat = 3
        let size = NSSize(width: iconSize + gap + caretSize, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()
        LucideIcon.image(icon, size: iconSize, color: Palette.dockIcon)
            .draw(in: NSRect(x: 0, y: (size.height - iconSize) / 2, width: iconSize, height: iconSize))
        LucideIcon.image(LucideIcon.chevronDown, size: caretSize, color: Palette.dockIcon)
            .draw(in: NSRect(x: iconSize + gap, y: (size.height - caretSize) / 2, width: caretSize, height: caretSize))
        image.unlockFocus()
        return image
    }

    @objc private func clicked() { onClick() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = Palette.dockHover.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}
