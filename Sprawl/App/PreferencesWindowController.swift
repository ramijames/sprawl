import AppKit

/// The app's Preferences window — a standard macOS preferences UI: a toolbar of tabs across the top
/// (General / Account) with a tidy, grid-aligned form in each pane.
final class PreferencesWindowController: NSWindowController {
    convenience init() {
        let tabs = PreferencesTabController()
        let window = NSWindow(contentViewController: tabs)
        window.title = "Preferences"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }

    /// Show (or focus) the window, refreshing its values first.
    func present() {
        (window?.contentViewController as? PreferencesTabController)?.refreshAll()
        showWindow(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Hosts the preference panes as toolbar tabs (the system "preferences" chrome).
final class PreferencesTabController: NSTabViewController {
    private let general = GeneralPrefsViewController()
    private let account = AccountPrefsViewController()

    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .toolbar
        view.appearance = NSAppearance(named: .darkAqua)
        addPane(general, label: "General", symbol: "gearshape")
        addPane(account, label: "Account", symbol: "key.fill")
    }

    private func addPane(_ vc: NSViewController, label: String, symbol: String) {
        let item = NSTabViewItem(viewController: vc)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        addTabViewItem(item)
    }

    func refreshAll() {
        general.refresh()
        account.refresh()
    }
}

// MARK: - Panes

/// Shared helpers for building tidy, right-aligned label/control forms.
private enum PrefsForm {
    static func grid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.columnSpacing = 10
        grid.rowSpacing = 14
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        return grid
    }

    static func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 13)
        return l
    }

    static func hint(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 360
        return l
    }

    /// Pin `content` inside a sized container with standard preference margins.
    static func pane(_ content: NSView, size: NSSize) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            content.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -24),
        ])
        container.setFrameSize(size)
        return container
    }
}

/// General — undo history limit.
private final class GeneralPrefsViewController: NSViewController {
    private let stepper = NSStepper()
    private let valueField = NSTextField(labelWithString: "100")

    override func loadView() {
        stepper.minValue = 10
        stepper.maxValue = 1000
        stepper.increment = 10
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepperChanged)

        valueField.alignment = .right
        valueField.font = .systemFont(ofSize: 13, weight: .medium)
        valueField.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let controls = NSStackView(views: [valueField, stepper])
        controls.orientation = .horizontal
        controls.spacing = 6

        let grid = PrefsForm.grid([[PrefsForm.label("Maximum undo steps:"), controls]])
        let hint = PrefsForm.hint("How many actions ⌘Z can undo. Older steps are discarded as you work.")

        let stack = NSStackView(views: [grid, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12

        view = PrefsForm.pane(stack, size: NSSize(width: 480, height: 150))
        preferredContentSize = NSSize(width: 480, height: 150)
    }

    func refresh() {
        let limit = UserDefaults.standard.integer(forKey: "SprawlUndoLimit")
        let value = limit > 0 ? limit : 100
        stepper.integerValue = value
        valueField.stringValue = "\(value)"
    }

    @objc private func stepperChanged() {
        valueField.stringValue = "\(stepper.integerValue)"
        UserDefaults.standard.set(stepper.integerValue, forKey: "SprawlUndoLimit")
    }
}

/// Account — the Anthropic (Claude) connection + API key.
private final class AccountPrefsViewController: NSViewController {
    private let statusLabel = NSTextField(labelWithString: "")
    private let keyField = NSSecureTextField()
    private let hint = PrefsForm.hint("")

    override func loadView() {
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)

        keyField.placeholderString = "sk-ant-…"
        keyField.font = .systemFont(ofSize: 13)
        keyField.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let save = NSButton(title: "Save", target: self, action: #selector(saveKey))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeKey))
        remove.bezelStyle = .rounded
        let buttons = NSStackView(views: [save, remove])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let grid = PrefsForm.grid([
            [PrefsForm.label("Anthropic (Claude):"), statusLabel],
            [PrefsForm.label("API Key:"), keyField],
            [NSGridCell.emptyContentView, buttons],
        ])

        let stack = NSStackView(views: [grid, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14

        view = PrefsForm.pane(stack, size: NSSize(width: 480, height: 210))
        preferredContentSize = NSSize(width: 480, height: 210)
    }

    func refresh() {
        let connected = APIKeyStore.hasKey
        statusLabel.stringValue = connected ? "Connected" : "Not connected"
        statusLabel.textColor = connected ? .systemGreen : .secondaryLabelColor
        hint.stringValue = connected
            ? "A key is stored in your Keychain."
            : "No key stored — Claude can't run without one. Paste your key above and click Save."
        keyField.stringValue = ""
    }

    @objc private func saveKey() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        APIKeyStore.save(key)
        refresh()
    }

    @objc private func removeKey() {
        APIKeyStore.clear()
        refresh()
    }
}
