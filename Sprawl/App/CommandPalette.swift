import AppKit

/// One entry in the command palette: a title, a category subtitle, and the action to run.
struct PaletteItem {
    let title: String
    let subtitle: String
    let run: () -> Void
}

/// A Spotlight-style ⌘K palette: a centered field over a results list with fuzzy filtering. Arrow
/// keys move the selection, Return runs it, Esc (or clicking away) dismisses.
final class CommandPalette: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private final class Panel: NSPanel { override var canBecomeKey: Bool { true } }

    private var panel: Panel?
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var resignObserver: NSObjectProtocol?

    private var all: [PaletteItem] = []
    private var filtered: [PaletteItem] = []

    private static let width: CGFloat = 560
    private static let height: CGFloat = 392

    func show(_ items: [PaletteItem], over parent: NSWindow) {
        all = items
        let panel = self.panel ?? buildPanel()
        let frame = parent.frame
        let x = frame.minX + (frame.width - Self.width) / 2
        let y = frame.minY + frame.height - Self.height - 140   // upper third
        panel.setFrame(NSRect(x: x, y: y, width: Self.width, height: Self.height), display: true)
        parent.addChildWindow(panel, ordered: .above)
        field.stringValue = ""
        applyFilter("")
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            self?.close()
        }
    }

    private func buildPanel() -> Panel {
        let p = Panel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                      styleMask: [.borderless], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.appearance = NSAppearance(named: .darkAqua)
        p.isFloatingPanel = true

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(srgbRed: 0x1c / 255, green: 0x1c / 255, blue: 0x1c / 255, alpha: 1).cgColor
        content.layer?.cornerRadius = 12
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor(srgbRed: 0x38 / 255, green: 0x38 / 255, blue: 0x38 / 255, alpha: 1).cgColor
        content.layer?.masksToBounds = true
        p.contentView = content

        field.placeholderString = "Type a command or project…"
        field.font = .systemFont(ofSize: 18, weight: .regular)
        field.textColor = .white
        field.drawsBackground = false
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(srgbRed: 0x38 / 255, green: 0x38 / 255, blue: 0x38 / 255, alpha: 1).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cmd"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 40
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(runSelected)
        table.focusRingType = .none
        table.selectionHighlightStyle = .regular
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(field)
        content.addSubview(divider)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            divider.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 14),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel = p
        return p
    }

    private func close() {
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func applyFilter(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            filtered = all
        } else {
            filtered = all.filter { Self.fuzzy(q, $0.title.lowercased()) || $0.subtitle.lowercased().contains(q) }
        }
        table.reloadData()
        if !filtered.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    /// Subsequence match: every character of `needle` appears in `hay` in order.
    private static func fuzzy(_ needle: String, _ hay: String) -> Bool {
        var i = needle.startIndex
        for ch in hay where i < needle.endIndex && ch == needle[i] { i = needle.index(after: i) }
        return i == needle.endIndex
    }

    @objc private func runSelected() {
        let row = table.selectedRow
        guard filtered.indices.contains(row) else { return }
        let item = filtered[row]
        close()
        item.run()
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let next = max(0, min(filtered.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) { applyFilter(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): runSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = filtered[row]
        let id = NSUserInterfaceItemIdentifier("PaletteCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView(); c.identifier = id
            let title = NSTextField(labelWithString: ""); title.translatesAutoresizingMaskIntoConstraints = false
            title.font = .systemFont(ofSize: 13); title.tag = 1
            let sub = NSTextField(labelWithString: ""); sub.translatesAutoresizingMaskIntoConstraints = false
            sub.font = .systemFont(ofSize: 11); sub.textColor = .secondaryLabelColor
            sub.alignment = .right; sub.tag = 2
            sub.setContentHuggingPriority(.required, for: .horizontal)
            c.addSubview(title); c.addSubview(sub)
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 16),
                title.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                sub.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -16),
                sub.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                sub.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            ])
            return c
        }()
        (cell.viewWithTag(1) as? NSTextField)?.stringValue = item.title
        (cell.viewWithTag(2) as? NSTextField)?.stringValue = item.subtitle
        return cell
    }
}
