import AppKit

/// The app's Preferences window: connected accounts, undo-history limit, and the Claude API key.
final class PreferencesWindowController: NSWindowController {
    private let accountsStack = NSStackView()
    private let undoStepper = NSStepper()
    private let undoValue = NSTextField(labelWithString: "")
    private let keyField = NSSecureTextField()
    private let keyStatus = NSTextField(labelWithString: "")

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Preferences"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildUI()
    }

    /// Show (or focus) the window, refreshing its values first.
    func present() {
        refresh()
        showWindow(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let root = NSStackView(views: [
            makeBox("Connected Accounts", accountsContent()),
            makeBox("Undo History", undoContent()),
            makeBox("Claude API Key", keyContent()),
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.distribution = .fill
        root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])
    }

    private func makeBox(_ title: String, _ inner: NSView) -> NSBox {
        let box = NSBox()
        box.title = title
        box.titlePosition = .atTop
        box.translatesAutoresizingMaskIntoConstraints = false
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.contentView = inner
        return box
    }

    private func accountsContent() -> NSView {
        accountsStack.orientation = .vertical
        accountsStack.alignment = .leading
        accountsStack.spacing = 8
        accountsStack.translatesAutoresizingMaskIntoConstraints = false
        accountsStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 410).isActive = true
        return accountsStack
    }

    private func undoContent() -> NSView {
        let label = NSTextField(labelWithString: "Maximum undo steps:")
        undoStepper.minValue = 10
        undoStepper.maxValue = 1000
        undoStepper.increment = 10
        undoStepper.valueWraps = false
        undoStepper.target = self
        undoStepper.action = #selector(undoStepperChanged)
        undoValue.font = .systemFont(ofSize: 13, weight: .medium)
        undoValue.alignment = .right
        undoValue.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let row = NSStackView(views: [label, undoValue, undoStepper])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(greaterThanOrEqualToConstant: 410).isActive = true
        return row
    }

    private func keyContent() -> NSView {
        keyField.placeholderString = "sk-ant-…"
        keyField.translatesAutoresizingMaskIntoConstraints = false
        let save = NSButton(title: "Save", target: self, action: #selector(saveKey))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeKey))
        remove.bezelStyle = .rounded
        keyStatus.font = .systemFont(ofSize: 11)
        keyStatus.textColor = .secondaryLabelColor

        let buttons = NSStackView(views: [save, remove])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [keyField, buttons, keyStatus])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        keyField.widthAnchor.constraint(equalToConstant: 410).isActive = true
        return stack
    }

    // MARK: - Values

    private func refresh() {
        let limit = UserDefaults.standard.integer(forKey: "SprawlUndoLimit")
        let value = limit > 0 ? limit : 100
        undoStepper.integerValue = value
        undoValue.stringValue = "\(value)"

        keyStatus.stringValue = APIKeyStore.hasKey
            ? "A key is stored in your Keychain."
            : "No key stored — Claude can't run without one."
        rebuildAccounts()
    }

    private func rebuildAccounts() {
        accountsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        accountsStack.addArrangedSubview(accountRow("Anthropic (Claude)",
            status: APIKeyStore.hasKey ? "Connected" : "Not connected",
            connected: APIKeyStore.hasKey))
        accountsStack.addArrangedSubview(accountRow("Browser", status: "Per-window sign-in", connected: nil))
    }

    private func accountRow(_ name: String, status: String, connected: Bool?) -> NSView {
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13)
        let statusLabel = NSTextField(labelWithString: status)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = connected == true ? .systemGreen : .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [nameLabel, spacer, statusLabel])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 410).isActive = true
        return row
    }

    // MARK: - Actions

    @objc private func undoStepperChanged() {
        let v = undoStepper.integerValue
        undoValue.stringValue = "\(v)"
        UserDefaults.standard.set(v, forKey: "SprawlUndoLimit")
    }

    @objc private func saveKey() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        APIKeyStore.save(key)
        keyField.stringValue = ""
        refresh()
    }

    @objc private func removeKey() {
        APIKeyStore.clear()
        keyField.stringValue = ""
        refresh()
    }
}
