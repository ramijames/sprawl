import AppKit

/// One tool in a dock group: an icon + label and the action to arm when picked.
struct DockTool {
    let icon: [LucideIcon.Shape]
    let tooltip: String
    let onSelect: () -> Void
}

/// A floating, rounded toolbar pinned to the bottom-center of the canvas: a standalone Project
/// button plus discrete groups (Ideate / Annotate / Review / Create / Manage). Clicking a group
/// opens a custom sub-dock pill above it (not a macOS menu); picking a tool arms it for placement.
final class FloatingDock: NSView {
    var onNewProject: (() -> Void)?
    var onNewTerminal: (() -> Void)?
    var onNewDocument: (() -> Void)?
    var onNewBrowser: (() -> Void)?
    var onNewGitObserver: (() -> Void)?
    var onNewGitGraph: (() -> Void)?
    var onNewProjectVelocity: (() -> Void)?
    var onNewDiff: (() -> Void)?
    var onNewCodeEditor: (() -> Void)?
    var onNewClaude: (() -> Void)?
    var onNewSticky: (() -> Void)?
    var onNewFreeText: (() -> Void)?
    var onNewLine: (() -> Void)?

    /// Show/toggle a sub-dock of `tools` above `anchor` (the clicked group button). Empty tools just
    /// dismiss any open sub-dock (used by the not-yet-populated Ideate / Manage groups).
    var onToggleSubDock: ((_ tools: [DockTool], _ anchor: NSView) -> Void)?

    private var groupHolders: [GroupHolder] = []
    private weak var annotateButton: DockButton?

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

        let projectButton = DockButton(icon: LucideIcon.folderPlus, tooltip: "New Project", label: "Project") { [weak self] in self?.onNewProject?() }

        let ideate = makeGroupButton(icon: LucideIcon.sparkles, tooltip: "Ideate") { [] }
        let annotate = makeGroupButton(icon: LucideIcon.stickyNote, tooltip: "Annotate") { [weak self] in
            guard let self else { return [] }
            return [DockTool(icon: LucideIcon.stickyNote, tooltip: "Sticky") { self.onNewSticky?() },
                    DockTool(icon: LucideIcon.type, tooltip: "Text") { self.onNewFreeText?() },
                    DockTool(icon: LucideIcon.spline, tooltip: "Arrow") { self.onNewLine?() }]
        }
        annotateButton = annotate
        let review = makeGroupButton(icon: LucideIcon.chartColumn, tooltip: "Review") { [weak self] in
            guard let self else { return [] }
            return [DockTool(icon: LucideIcon.diff, tooltip: "Diff") { self.onNewDiff?() },
                    DockTool(icon: LucideIcon.gauge, tooltip: "Velocity") { self.onNewProjectVelocity?() },
                    DockTool(icon: LucideIcon.gitCommit, tooltip: "Observer") { self.onNewGitObserver?() },
                    DockTool(icon: LucideIcon.gitGraph, tooltip: "Graph") { self.onNewGitGraph?() }]
        }
        let create = makeGroupButton(icon: LucideIcon.layoutGrid, tooltip: "Create") { [weak self] in
            guard let self else { return [] }
            return [DockTool(icon: LucideIcon.squareTerminal, tooltip: "Terminal") { self.onNewTerminal?() },
                    DockTool(icon: LucideIcon.fileText, tooltip: "Document") { self.onNewDocument?() },
                    DockTool(icon: LucideIcon.code, tooltip: "Code") { self.onNewCodeEditor?() },
                    DockTool(icon: LucideIcon.globe, tooltip: "Browser") { self.onNewBrowser?() },
                    DockTool(icon: LucideIcon.sparkles, tooltip: "Claude") { self.onNewClaude?() }]
        }
        let manage = makeGroupButton(icon: LucideIcon.gitBranch, tooltip: "Manage") { [] }

        let stack = NSStackView(views: [projectButton, makeDivider(), ideate, annotate, review, create, manage])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
        ])
    }

    /// Highlight the Annotate group (used at the end of onboarding to point at the tools).
    func highlightApps() { annotateButton?.setHighlighted(true) }

    private func makeDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Palette.dockBorder.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return divider
    }

    private func makeGroupButton(icon: [LucideIcon.Shape], tooltip: String,
                                 tools: @escaping () -> [DockTool]) -> DockButton {
        let holder = GroupHolder(tools: tools)
        let button = DockButton(icon: icon, tooltip: tooltip) { [weak self, weak holder] in
            guard let self, let holder, let btn = holder.button else { return }
            self.annotateButton?.setHighlighted(false)
            self.onToggleSubDock?(holder.tools(), btn)
        }
        holder.button = button
        groupHolders.append(holder)
        return button
    }
}

/// Retains a group button + its tool-list closure (the button is created after the closure).
private final class GroupHolder {
    weak var button: DockButton?
    let tools: () -> [DockTool]
    init(tools: @escaping () -> [DockTool]) { self.tools = tools }
}

/// A small floating pill of tool buttons shown above a dock group. Picking a tool runs its action
/// and dismisses (via `onPick`).
final class SubDock: NSView {
    init(tools: [DockTool], onPick: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = Palette.dockFill.cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = Palette.dockBorder.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        layer?.masksToBounds = false

        let buttons = tools.map { tool in
            DockButton(icon: tool.icon, tooltip: tool.tooltip) { tool.onSelect(); onPick() }
        }
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// One row of a top-bar group dropdown: a left icon, a small gap, then the tool's name. Highlights
/// on hover; runs its action on click.
final class DropdownRow: NSButton {
    private let onClick: () -> Void
    private var trackingArea: NSTrackingArea?

    init(icon: [LucideIcon.Shape], label: String, action: @escaping () -> Void) {
        onClick = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        isBordered = false
        bezelStyle = .regularSquare
        image = LucideIcon.image(icon, size: 18, color: Palette.dockIcon)
        imagePosition = .imageLeft
        imageHugsTitle = true
        alignment = .left
        contentTintColor = Palette.dockIcon
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        attributedTitle = NSAttributedString(string: "  " + label, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: Palette.dockIcon,
            .paragraphStyle: paragraph,
        ])
        target = self
        self.action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 32).isActive = true
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

    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = Palette.dockHover.cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor.clear.cgColor }
}

/// A square icon button with a rounded hover highlight, for the floating dock.
final class DockButton: NSButton {
    private let onClick: () -> Void
    private var trackingArea: NSTrackingArea?
    private var isActive = false

    init(icon: [LucideIcon.Shape], tooltip: String, label: String? = nil,
         caret: Bool = false, compact: Bool = false,
         compactIcon: CGFloat = 22, compactSize: CGFloat = 38, action: @escaping () -> Void) {
        onClick = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        isBordered = false
        bezelStyle = .regularSquare
        toolTip = tooltip
        target = self
        self.action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        if compact {
            // Small icon-only button (the right-edge Annotate dock; the group drawer uses a larger glyph).
            image = LucideIcon.image(icon, size: compactIcon, color: Palette.dockIcon)
            imagePosition = .imageOnly
            widthAnchor.constraint(equalToConstant: compactSize).isActive = true
            heightAnchor.constraint(equalToConstant: compactSize).isActive = true
            return
        }
        image = DockButton.paddedIcon(icon, bottomPad: 7)   // transparent strip = gap above the caption
        imagePosition = .imageAbove   // icon on top, small caption below
        imageHugsTitle = true
        let caption = NSMutableParagraphStyle()
        caption.alignment = .center
        attributedTitle = NSAttributedString(string: label ?? tooltip, attributes: [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: Palette.dockIcon.withAlphaComponent(0.35),
            .paragraphStyle: caption,
        ])
        widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        heightAnchor.constraint(equalToConstant: 54).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A Lucide icon with transparent padding below it, so `.imageAbove` leaves a gap before the caption.
    private static func paddedIcon(_ icon: [LucideIcon.Shape], bottomPad: CGFloat) -> NSImage {
        let s: CGFloat = 22
        let image = NSImage(size: NSSize(width: s, height: s + bottomPad))
        image.lockFocus()
        LucideIcon.image(icon, size: s, color: Palette.dockIcon)
            .draw(in: NSRect(x: 0, y: bottomPad, width: s, height: s))   // glyph at the top, gap below
        image.unlockFocus()
        return image
    }

    @objc private func clicked() { onClick() }

    /// Draw a white rounded outline around the button (an onboarding spotlight).
    func setHighlighted(_ on: Bool) {
        layer?.borderWidth = on ? 2 : 0
        layer?.borderColor = NSColor.white.cgColor
    }

    /// Keep a lighter background to mark the button as the active tool (e.g. line drawing armed).
    func setActive(_ on: Bool) {
        isActive = on
        layer?.backgroundColor = on ? Palette.dockHover.cgColor : NSColor.clear.cgColor
    }

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
        layer?.backgroundColor = isActive ? Palette.dockHover.cgColor : NSColor.clear.cgColor
    }
}
