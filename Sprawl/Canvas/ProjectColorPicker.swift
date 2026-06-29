import AppKit

/// A 4×4 grid of project color swatches plus a "No color" option, shown in a popover from the
/// tab's color dot.
final class ProjectColorPicker: NSViewController {
    private let current: Int?
    private let onPick: (Int?) -> Void
    private weak var popover: NSPopover?

    init(current: Int?, popover: NSPopover, onPick: @escaping (Int?) -> Void) {
        self.current = current
        self.popover = popover
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let swatch: CGFloat = 28, gap: CGFloat = 10, pad: CGFloat = 14, cols = 4
        let count = min(16, Palette.projectColors.count)
        let rows = (count + cols - 1) / cols
        let gridW = CGFloat(cols) * swatch + CGFloat(cols - 1) * gap
        let gridH = CGFloat(rows) * swatch + CGFloat(rows - 1) * gap
        let footerH: CGFloat = 22
        let w = gridW + 2 * pad
        let h = pad + gridH + 10 + footerH + pad

        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        for i in 0..<count {
            let r = i / cols, c = i % cols
            let x = pad + CGFloat(c) * (swatch + gap)
            let y = h - pad - swatch - CGFloat(r) * (swatch + gap)   // lay out top-to-bottom
            let button = SwatchButton(frame: NSRect(x: x, y: y, width: swatch, height: swatch))
            button.color = Palette.projectColors[i]
            button.isCurrent = (i == current)
            button.tag = i
            button.target = self
            button.action = #selector(pick(_:))
            root.addSubview(button)
        }

        let none = NSButton(frame: NSRect(x: pad, y: pad, width: gridW, height: footerH))
        none.title = "No color"
        none.isBordered = false
        none.font = .systemFont(ofSize: 12)
        none.contentTintColor = Palette.sidebarText
        none.alignment = .center
        none.target = self
        none.action = #selector(pickNone)
        root.addSubview(none)

        view = root
    }

    @objc private func pick(_ sender: NSButton) { onPick(sender.tag); popover?.close() }
    @objc private func pickNone() { onPick(nil); popover?.close() }
}

/// A circular color swatch button with a selection ring for the current color.
private final class SwatchButton: NSButton {
    var color: NSColor = .gray
    var isCurrent = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).fill()
        if isCurrent {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            NSColor.white.setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}
