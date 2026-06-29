import AppKit

/// A floating, rounded toolbar pinned to the bottom-center of the canvas. Buttons create a new
/// project, or new windows (terminal / document / browser) in the focused project. Uses Lucide
/// icons. Sizes itself to its content.
final class FloatingDock: NSView {
    var onNewProject: (() -> Void)?
    var onNewTerminal: (() -> Void)?
    var onNewDocument: (() -> Void)?
    var onNewBrowser: (() -> Void)?

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
        let terminalButton = DockButton(icon: LucideIcon.squareTerminal, tooltip: "New Terminal") { [weak self] in self?.onNewTerminal?() }
        let documentButton = DockButton(icon: LucideIcon.fileText, tooltip: "New Document") { [weak self] in self?.onNewDocument?() }
        let browserButton = DockButton(icon: LucideIcon.globe, tooltip: "New Browser") { [weak self] in self?.onNewBrowser?() }

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Palette.dockBorder.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let stack = NSStackView(views: [projectButton, divider, terminalButton, documentButton, browserButton])
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
}

/// A square icon button with a rounded hover highlight, for the floating dock.
final class DockButton: NSButton {
    private let onClick: () -> Void
    private var trackingArea: NSTrackingArea?

    init(icon: [LucideIcon.Shape], tooltip: String, action: @escaping () -> Void) {
        onClick = action
        super.init(frame: NSRect(x: 0, y: 0, width: 38, height: 38))
        wantsLayer = true
        layer?.cornerRadius = 9
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        image = LucideIcon.image(icon, size: 22, color: Palette.dockIcon)
        toolTip = tooltip
        target = self
        self.action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 38).isActive = true
        heightAnchor.constraint(equalToConstant: 38).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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
