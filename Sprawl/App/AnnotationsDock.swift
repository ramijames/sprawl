import AppKit

/// A second floating dock pill (sits beside the main dock with a small gap) holding annotation
/// tools — sticky notes and free text. Shares the dock's rounded dark pill styling.
final class AnnotationsDock: NSView {
    var onNewSticky: (() -> Void)?
    var onNewFreeText: (() -> Void)?
    var onNewLine: (() -> Void)?

    private var lineButton: DockButton?
    /// Highlight the Line button while the connector tool is armed.
    func setLineToolActive(_ on: Bool) { lineButton?.setActive(on) }

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

        let sticky = DockButton(icon: LucideIcon.stickyNote, tooltip: "Sticky Pad") { [weak self] in self?.onNewSticky?() }
        let text = DockButton(icon: LucideIcon.type, tooltip: "Free Text") { [weak self] in self?.onNewFreeText?() }
        let line = DockButton(icon: LucideIcon.spline, tooltip: "Line") { [weak self] in self?.onNewLine?() }
        lineButton = line

        let stack = NSStackView(views: [sticky, text, line])
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
