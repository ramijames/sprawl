import AppKit

/// A floating, dock-styled options toolbar that appears above the selected annotation (sticky / free
/// text). Shows a color swatch (opens a 4×4 pastel grid), and for free text a font + size dropdown,
/// then a delete button. Configured per selection by `MainSplitViewController`.
final class OptionsBar: NSView {
    var onColor: ((Int) -> Void)?
    var onFont: ((String) -> Void)?
    var onSize: ((CGFloat) -> Void)?
    var onRepo: (() -> Void)?
    var onThickness: ((CGFloat) -> Void)?
    var onCurved: ((Bool) -> Void)?
    var onArrowStart: ((Bool) -> Void)?
    var onArrowEnd: ((Bool) -> Void)?
    var onOpen: (() -> Void)?
    var onSave: (() -> Void)?
    var onWrap: (() -> Void)?
    var onName: ((String) -> Void)?
    var onLayout: ((Int) -> Void)?   // 0 = freeform, 1 = grid, 2 = columns
    var onDelete: (() -> Void)?

    private let nameField = NSTextField()
    private let layoutSegment = NSSegmentedControl(labels: ["Freeform", "Grid", "Columns"],
                                                   trackingMode: .selectOne, target: nil, action: nil)
    /// Which palette the color swatch + grid use (pastels for annotations/lines, the 16 project
    /// colors for a project).
    private var colorPalette: [NSColor] = Palette.pastels
    private let openButton = NSButton()
    private let saveButton = NSButton()
    private let wrapButton = NSButton()
    private let repoButton = NSButton()
    private let colorButton = NSButton()
    private let swatchLayer = CALayer()
    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let thicknessPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let curveButton = NSButton()
    private let arrowStartButton = NSButton()
    private let arrowEndButton = NSButton()
    private let divider = NSView()
    private let trash = NSButton()
    private var popover: NSPopover?

    static let fonts = ["System", "Helvetica", "Helvetica Neue", "Arial", "Avenir Next",
                        "Georgia", "Times New Roman", "Menlo", "Courier New", "Verdana"]
    static let sizes = [12, 14, 18, 24, 32, 48, 64, 96]
    static let thicknesses = [1, 2, 3, 4, 6, 8]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = Palette.dockFill.cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = Palette.dockBorder.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        layer?.masksToBounds = false

        configureIcon(openButton, symbol: "folder", tip: "Open File (⌘O)", action: #selector(openClicked))
        configureIcon(saveButton, symbol: "square.and.arrow.down", tip: "Save (⌘S)", action: #selector(saveClicked))
        wrapButton.isBordered = false
        wrapButton.bezelStyle = .regularSquare
        wrapButton.imagePosition = .imageOnly
        let wrapIcon = LucideIcon.image(LucideIcon.textWrap, size: 16, color: .white)
        wrapIcon.isTemplate = true
        wrapButton.image = wrapIcon
        wrapButton.contentTintColor = Palette.dockIcon
        wrapButton.toolTip = "Word Wrap"
        wrapButton.target = self
        wrapButton.action = #selector(wrapClicked)
        wrapButton.wantsLayer = true
        wrapButton.layer?.cornerRadius = 5
        wrapButton.translatesAutoresizingMaskIntoConstraints = false
        wrapButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        wrapButton.heightAnchor.constraint(equalToConstant: 24).isActive = true

        repoButton.isBordered = false
        repoButton.bezelStyle = .regularSquare
        repoButton.imagePosition = .imageOnly
        repoButton.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Choose repository")
        repoButton.contentTintColor = Palette.dockIcon
        repoButton.toolTip = "Choose repository to monitor"
        repoButton.target = self
        repoButton.action = #selector(repoClicked)
        repoButton.translatesAutoresizingMaskIntoConstraints = false
        repoButton.widthAnchor.constraint(equalToConstant: 24).isActive = true

        colorButton.isBordered = false
        colorButton.bezelStyle = .regularSquare
        colorButton.imagePosition = .imageOnly
        colorButton.title = ""
        colorButton.wantsLayer = true
        colorButton.target = self
        colorButton.action = #selector(colorClicked)
        colorButton.translatesAutoresizingMaskIntoConstraints = false
        colorButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        colorButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        swatchLayer.frame = CGRect(x: 3, y: 3, width: 18, height: 18)
        swatchLayer.cornerRadius = 9
        swatchLayer.borderColor = NSColor(white: 1, alpha: 0.35).cgColor
        swatchLayer.borderWidth = 1
        colorButton.layer?.addSublayer(swatchLayer)

        fontPopup.addItems(withTitles: Self.fonts)
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged)
        fontPopup.controlSize = .small

        sizePopup.addItems(withTitles: Self.sizes.map(String.init))
        sizePopup.target = self
        sizePopup.action = #selector(sizeChanged)
        sizePopup.controlSize = .small

        thicknessPopup.addItems(withTitles: Self.thicknesses.map { "\($0) pt" })
        thicknessPopup.target = self
        thicknessPopup.action = #selector(thicknessChanged)
        thicknessPopup.controlSize = .small

        configureToggle(curveButton, symbol: "point.topleft.down.curvedto.point.bottomright.up",
                        fallback: "scribble", tip: "Curved line", action: #selector(curveToggled))
        configureToggle(arrowStartButton, symbol: "arrow.left",
                        fallback: "chevron.left", tip: "Arrowhead at start", action: #selector(arrowStartToggled))
        configureToggle(arrowEndButton, symbol: "arrow.right",
                        fallback: "chevron.right", tip: "Arrowhead at end", action: #selector(arrowEndToggled))

        nameField.font = .systemFont(ofSize: 13)
        nameField.textColor = .white
        nameField.drawsBackground = false
        nameField.isBordered = false
        nameField.isBezeled = false
        nameField.focusRingType = .none
        nameField.usesSingleLineMode = true
        nameField.placeholderString = "Project name"
        nameField.target = self
        nameField.action = #selector(nameCommitted)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.widthAnchor.constraint(equalToConstant: 150).isActive = true

        layoutSegment.target = self
        layoutSegment.action = #selector(layoutChanged)
        layoutSegment.controlSize = .small
        layoutSegment.segmentDistribution = .fillEqually

        divider.wantsLayer = true
        divider.layer?.backgroundColor = Palette.dockBorder.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 22).isActive = true

        trash.isBordered = false
        trash.bezelStyle = .regularSquare
        trash.imagePosition = .imageOnly
        trash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
        trash.contentTintColor = Palette.dockIcon
        trash.target = self
        trash.action = #selector(deleteClicked)
        trash.translatesAutoresizingMaskIntoConstraints = false
        trash.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let stack = NSStackView(views: [openButton, saveButton, wrapButton,
                                        repoButton, nameField, colorButton, layoutSegment,
                                        fontPopup, sizePopup,
                                        thicknessPopup, curveButton, arrowStartButton, arrowEndButton,
                                        divider, trash])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    /// A borderless momentary SF-symbol button (open / save), 24pt wide.
    private func configureIcon(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.contentTintColor = Palette.dockIcon
        button.toolTip = tip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
    }

    /// A borderless image toggle button (curve / arrowheads), 24pt wide, with an SF-symbol fallback.
    /// Shows an accent-tinted rounded background while toggled on.
    private func configureToggle(_ button: NSButton, symbol: String, fallback: String, tip: String, action: Selector) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: tip)
        button.contentTintColor = Palette.dockIcon
        button.toolTip = tip
        button.setButtonType(.pushOnPushOff)
        button.target = self
        button.action = action
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    /// Reflect a toggle's on/off state with an accent background + brighter icon.
    private func updateToggle(_ button: NSButton) {
        let on = button.state == .on
        button.layer?.backgroundColor = on ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        button.contentTintColor = on ? .white : Palette.dockIcon
    }

    /// Document controls: open, save, and a word-wrap toggle (tinted to show its state).
    func configureDocument(wrapOn: Bool) {
        openButton.isHidden = false
        saveButton.isHidden = false
        wrapButton.isHidden = false
        setDocWrap(wrapOn)
        repoButton.isHidden = true
        colorButton.isHidden = true
        fontPopup.isHidden = true
        sizePopup.isHidden = true
        hideLineControls()
        hideProjectControls()
        trash.isHidden = false
    }

    func setDocWrap(_ on: Bool) {
        // Same toggled-on style as the line arrow toggles: accent background + white glyph.
        wrapButton.layer?.backgroundColor = on ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        wrapButton.contentTintColor = on ? .white : Palette.dockIcon
    }

    private func hideDocControls() {
        openButton.isHidden = true
        saveButton.isHidden = true
        wrapButton.isHidden = true
    }

    /// Annotation controls: a color swatch, plus font/size dropdowns for free text.
    func configure(showsFont: Bool, colorIndex: Int, fontName: String?, fontSize: CGFloat?) {
        hideDocControls()
        hideProjectControls()
        trash.isHidden = false
        colorPalette = Palette.pastels
        repoButton.isHidden = true
        colorButton.isHidden = false
        swatchLayer.backgroundColor = Palette.pastels[colorIndex % Palette.pastels.count].cgColor
        fontPopup.isHidden = !showsFont
        sizePopup.isHidden = !showsFont
        hideLineControls()
        if showsFont {
            if let fontName, let i = Self.fonts.firstIndex(of: fontName) { fontPopup.selectItem(at: i) }
            if let fontSize, let i = Self.sizes.firstIndex(of: Int(fontSize)) { sizePopup.selectItem(at: i) }
        }
    }

    /// Repo-tool controls (Git Observer / Graph / Project Velocity): a repository picker.
    func configureRepo() {
        hideDocControls()
        hideProjectControls()
        trash.isHidden = false
        repoButton.isHidden = false
        colorButton.isHidden = true
        fontPopup.isHidden = true
        sizePopup.isHidden = true
        hideLineControls()
    }

    /// Line controls: color swatch, thickness, and start/end arrowhead toggles. (Curvature is set
    /// per-node while drawing with the pen tool, so there's no global curve toggle.)
    func configureLine(colorIndex: Int, thickness: CGFloat, arrowStart: Bool, arrowEnd: Bool) {
        hideDocControls()
        hideProjectControls()
        trash.isHidden = false
        colorPalette = Palette.pastels
        repoButton.isHidden = true
        colorButton.isHidden = false
        swatchLayer.backgroundColor = Palette.pastels[colorIndex % Palette.pastels.count].cgColor
        fontPopup.isHidden = true
        sizePopup.isHidden = true
        thicknessPopup.isHidden = false
        curveButton.isHidden = true
        arrowStartButton.isHidden = false
        arrowEndButton.isHidden = false
        if let i = Self.thicknesses.firstIndex(of: Int(thickness.rounded())) { thicknessPopup.selectItem(at: i) }
        arrowStartButton.state = arrowStart ? .on : .off
        arrowEndButton.state = arrowEnd ? .on : .off
        updateToggle(arrowStartButton)
        updateToggle(arrowEndButton)
    }

    private func hideLineControls() {
        thicknessPopup.isHidden = true
        curveButton.isHidden = true
        arrowStartButton.isHidden = true
        arrowEndButton.isHidden = true
    }

    private func hideProjectControls() {
        nameField.isHidden = true
        layoutSegment.isHidden = true
    }

    /// Project controls: a name field, a color swatch (16 project colors), and a Freeform/Grid/Columns
    /// tiling selector. No delete (removing a whole project isn't an options-bar action).
    func configureProject(name: String, colorIndex: Int?, layoutIndex: Int) {
        hideDocControls()
        repoButton.isHidden = true
        fontPopup.isHidden = true
        sizePopup.isHidden = true
        hideLineControls()
        trash.isHidden = true
        nameField.isHidden = false
        nameField.stringValue = name
        layoutSegment.isHidden = false
        layoutSegment.selectedSegment = layoutIndex
        colorPalette = Palette.projectColors
        colorButton.isHidden = false
        let swatch: NSColor
        if let ci = colorIndex, Palette.projectColors.indices.contains(ci) {
            swatch = Palette.projectColors[ci]
        } else {
            swatch = NSColor(srgbRed: 0.42, green: 0.42, blue: 0.48, alpha: 1)
        }
        swatchLayer.backgroundColor = swatch.cgColor
    }

    @objc private func colorClicked() {
        let palette = colorPalette
        let grid = ColorGridView(colors: palette) { [weak self] index in
            self?.swatchLayer.backgroundColor = palette[index].cgColor
            self?.onColor?(index)
            self?.popover?.close()
        }
        let vc = NSViewController()
        vc.view = grid
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        pop.appearance = NSAppearance(named: .darkAqua)
        pop.show(relativeTo: colorButton.bounds, of: colorButton, preferredEdge: .maxY)
        popover = pop
    }

    @objc private func nameCommitted() { onName?(nameField.stringValue) }
    @objc private func layoutChanged() { onLayout?(layoutSegment.selectedSegment) }
    @objc private func openClicked() { onOpen?() }
    @objc private func saveClicked() { onSave?() }
    @objc private func wrapClicked() { onWrap?() }
    @objc private func repoClicked() { onRepo?() }
    @objc private func fontChanged() { onFont?(fontPopup.titleOfSelectedItem ?? "System") }
    @objc private func sizeChanged() { if let s = Int(sizePopup.titleOfSelectedItem ?? "") { onSize?(CGFloat(s)) } }
    @objc private func thicknessChanged() { onThickness?(CGFloat(Self.thicknesses[thicknessPopup.indexOfSelectedItem])) }
    @objc private func curveToggled() { updateToggle(curveButton); onCurved?(curveButton.state == .on) }
    @objc private func arrowStartToggled() { updateToggle(arrowStartButton); onArrowStart?(arrowStartButton.state == .on) }
    @objc private func arrowEndToggled() { updateToggle(arrowEndButton); onArrowEnd?(arrowEndButton.state == .on) }
    @objc private func deleteClicked() { onDelete?() }
}

/// A 4×4 grid of color swatches shown in the options bar's color popover.
private final class ColorGridView: NSView {
    private let onPick: (Int) -> Void

    init(colors: [NSColor], onPick: @escaping (Int) -> Void) {
        self.onPick = onPick
        let cols = 4
        let cell: CGFloat = 26, pad: CGFloat = 8, swatch: CGFloat = 18
        let rows = (colors.count + cols - 1) / cols
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: pad * 2 + CGFloat(cols) * cell - (cell - swatch),
                                 height: pad * 2 + CGFloat(rows) * cell - (cell - swatch)))
        for (i, color) in colors.enumerated() {
            let button = NSButton()
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.title = ""
            button.wantsLayer = true
            button.layer?.backgroundColor = color.cgColor
            button.layer?.cornerRadius = swatch / 2
            button.tag = i
            button.target = self
            button.action = #selector(pick(_:))
            button.frame = NSRect(x: pad + CGFloat(i % cols) * cell,
                                  y: pad + CGFloat(i / cols) * cell, width: swatch, height: swatch)
            addSubview(button)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var isFlipped: Bool { true }   // grid fills top-to-bottom

    @objc private func pick(_ sender: NSButton) { onPick(sender.tag) }
}
