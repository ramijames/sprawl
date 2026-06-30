import AppKit

/// Free text: a backgroundless annotation floating on the canvas — bright pastel text, no chrome,
/// no close button, and a frame that hugs the text. Single-click selects/drags it; double-click
/// edits. Color, font, and size come from the floating options bar.
final class FreeTextPanel: NSObject, NSTextViewDelegate {
    private let textView = AnnotationTextView()
    private weak var hostWindow: WindowView?

    private(set) var colorIndex: Int
    private(set) var fontSize: CGFloat
    private(set) var fontName: String
    var text: String { textView.string }
    var onChange: (() -> Void)?

    static var pastels: [NSColor] { Palette.pastels }
    static let defaultFont = "System"

    init(text: String, colorIndex: Int, fontSize: CGFloat, fontName: String = FreeTextPanel.defaultFont) {
        let count = FreeTextPanel.pastels.count
        self.colorIndex = ((colorIndex % count) + count) % count
        self.fontSize = fontSize
        self.fontName = fontName
        super.init()
        build()
        textView.string = text
        applyFont()
        applyColor()
    }

    func attach(to window: WindowView) {
        hostWindow = window
        window.makeChromeless()
        window.setContent(textView)
        window.onActivate = { [weak self] in self?.beginEditing() }
        window.onDeselected = { [weak self] in self?.endEditing() }
        sizeToFit()
    }
    func focus() {
        // Defer so the panel is in the window hierarchy before it grabs first responder.
        DispatchQueue.main.async { [weak self] in self?.beginEditing() }
    }

    func setColor(_ index: Int) {
        let count = Self.pastels.count
        colorIndex = ((index % count) + count) % count
        applyColor(); onChange?()
    }
    func setFontSize(_ size: CGFloat) { fontSize = max(8, size); applyFont(); sizeToFit(); onChange?() }
    func setFontName(_ name: String) { fontName = name; applyFont(); sizeToFit(); onChange?() }

    static func font(named name: String, size: CGFloat) -> NSFont {
        if name == "System" || name.isEmpty { return .systemFont(ofSize: size, weight: .semibold) }
        return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: .semibold)
    }

    private func beginEditing() {
        textView.editing = true
        textView.isEditable = true
        textView.isSelectable = true
        hostWindow?.window?.makeFirstResponder(textView)
    }

    func textDidEndEditing(_ notification: Notification) {
        textView.editing = false
        textView.isEditable = false
        textView.isSelectable = false
    }

    /// Stop editing (called when the element is deselected) so you can't type into it unselected.
    func endEditing() {
        guard textView.editing else { return }
        textView.editing = false
        textView.isEditable = false
        textView.isSelectable = false
        if hostWindow?.window?.firstResponder === textView {
            hostWindow?.window?.makeFirstResponder(hostWindow)
        }
    }

    func textDidChange(_ notification: Notification) { sizeToFit(); onChange?() }

    private func build() {
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 6, height: 4)
        textView.isHorizontallyResizable = false   // the host window is sized to the text instead
        textView.isVerticallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
    }

    /// Resize the host window to hug the text (anchored at its top-left).
    private func sizeToFit() {
        guard let window = hostWindow,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let inset = textView.textContainerInset
        let width = max(80, ceil(used.width) + inset.width * 2 + 4)
        let height = max(30, ceil(used.height) + inset.height * 2 + 2)
        window.setFrameSize(NSSize(width: width, height: height))
    }

    private func applyFont() {
        let font = Self.font(named: fontName, size: fontSize)
        textView.font = font
        if let storage = textView.textStorage {
            storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
        }
    }

    private func applyColor() {
        let color = Self.pastels[colorIndex]
        textView.textColor = color
        textView.insertionPointColor = color
        if let storage = textView.textStorage {
            storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: storage.length))
        }
    }
}

/// Passes clicks through to the host window unless it's actively being edited — so single-click
/// selects/drags the annotation and double-click (which the window turns into `beginEditing`) edits.
/// Shared by free text (used directly) and stickies (wrapped in an `AnnotationScrollView`).
final class AnnotationTextView: NSTextView {
    var editing = false
    override func hitTest(_ point: NSPoint) -> NSView? { editing ? super.hitTest(point) : nil }
}

/// A scroll view that, like `AnnotationTextView`, only captures clicks while editing — so a sticky's
/// whole panel drags on a single click and edits on double-click.
final class AnnotationScrollView: NSScrollView {
    var editing = false
    override func hitTest(_ point: NSPoint) -> NSView? { editing ? super.hitTest(point) : nil }
}
