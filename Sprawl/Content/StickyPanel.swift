import AppKit

/// A sticky note: a solid bright-pastel, resizable panel with dark same-hue text and no close button
/// — the whole panel drags on a single click, double-click edits, and you can't type unless it's
/// being edited. Color comes from the floating options bar. Hosted in a chrome-less WindowView.
final class StickyPanel: NSObject, NSTextViewDelegate {
    private let glass = GlassView()
    private let tint = NSView()
    private let textView = AnnotationTextView()
    private let scroll = AnnotationScrollView()
    private weak var hostWindow: WindowView?

    private(set) var colorIndex: Int
    var text: String { textView.string }
    var onChange: (() -> Void)?

    static var pastels: [NSColor] { Palette.pastels }

    init(text: String, colorIndex: Int) {
        let count = StickyPanel.pastels.count
        self.colorIndex = ((colorIndex % count) + count) % count
        super.init()
        build()
        textView.string = text
        applyColor()
    }

    func attach(to window: WindowView) {
        hostWindow = window
        window.makeChromeless(resizable: true, cornerRadius: 16)
        window.setGlassBackground(glass)       // solid pastel background
        window.setContent(scroll)              // editor over the glass
        window.onActivate = { [weak self] in self?.beginEditing() }
        window.onDeselected = { [weak self] in self?.endEditing() }
    }
    func focus() { DispatchQueue.main.async { [weak self] in self?.beginEditing() } }

    func setColor(_ index: Int) {
        let count = Self.pastels.count
        colorIndex = ((index % count) + count) % count
        applyColor()
        onChange?()
    }

    private func beginEditing() {
        textView.editing = true; scroll.editing = true
        textView.isEditable = true; textView.isSelectable = true
        hostWindow?.window?.makeFirstResponder(textView)
    }

    func textDidEndEditing(_ notification: Notification) {
        textView.editing = false; scroll.editing = false
        textView.isEditable = false; textView.isSelectable = false
    }

    /// Stop editing (called when the element is deselected) so you can't type into it unselected.
    func endEditing() {
        guard textView.editing else { return }
        textView.editing = false; scroll.editing = false
        textView.isEditable = false; textView.isSelectable = false
        if hostWindow?.window?.firstResponder === textView {
            hostWindow?.window?.makeFirstResponder(hostWindow)
        }
    }

    func textDidChange(_ notification: Notification) { onChange?() }

    private func build() {
        tint.wantsLayer = true
        tint.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(tint)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            tint.topAnchor.constraint(equalTo: glass.topAnchor),
            tint.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])

        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = false
        textView.allowsUndo = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = textView
    }

    private func applyColor() {
        let pastel = Self.pastels[colorIndex]
        tint.layer?.backgroundColor = pastel.cgColor
        let dark = pastel.blended(withFraction: 0.7, of: .black) ?? .black
        textView.textColor = dark
        textView.insertionPointColor = dark
        if let storage = textView.textStorage {
            storage.addAttribute(.foregroundColor, value: dark, range: NSRange(location: 0, length: storage.length))
        }
    }
}

/// Visual-only background: passes clicks through so the window handles drag/resize and the editor
/// (above it, when editing) handles text.
final class GlassView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
