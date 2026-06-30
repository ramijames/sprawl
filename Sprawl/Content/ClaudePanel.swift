import AppKit

/// A first-class Claude assistant panel. Streams chat from the Anthropic Messages API, offers a
/// model picker, and — its spatial twist — auto-inherits the git repo of the project card it was
/// created in, so it answers with that repo's branch/status/recent-commit context.
final class ClaudePanel: NSObject, NSTextViewDelegate {
    let containerView = NSView()
    private let modelPicker = NSPopUpButton()
    private let repoLabel = NSTextField(labelWithString: "")
    private let keyButton = NSButton()
    private let transcriptStack = FlippedStackView()
    private let transcriptScroll = NSScrollView()
    private weak var currentAssistantRow: ChatRow?
    private let inputView = NSTextView()
    private let inputScroll = NSScrollView()
    private let sendButton = NSButton()
    private let suggestionsStack = NSStackView()

    private(set) var repoPath: String?
    private var repoContext = ""
    private var messages: [ClaudeMessage] = []
    private var streamTask: Task<Void, Never>?
    private var isStreaming = false

    var onRepoChange: (() -> Void)?

    init(repoPath: String?) {
        super.init()
        buildUI()
        if let repoPath, !repoPath.isEmpty {
            self.repoPath = repoPath
            loadRepoContext(repoPath)
        }
        updateRepoLabel()
        updateKeyButton()
        updateSuggestions()   // now that repoPath is known, use repo-aware prompts
        showWelcome()
    }

    deinit { streamTask?.cancel() }

    func attach(to window: WindowView) { window.setContent(containerView) }
    func focus() { containerView.window?.makeFirstResponder(inputView) }

    private var selectedModel: ClaudeModel {
        ClaudeModel.allCases.indices.contains(modelPicker.indexOfSelectedItem)
            ? ClaudeModel.allCases[modelPicker.indexOfSelectedItem] : .sonnet
    }

    // MARK: - UI

    private func buildUI() {
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = Palette.panelBody.cgColor

        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false

        modelPicker.addItems(withTitles: ClaudeModel.allCases.map { $0.displayName })
        modelPicker.selectItem(at: 0)   // Sonnet
        modelPicker.controlSize = .small
        modelPicker.bezelStyle = .rounded
        modelPicker.translatesAutoresizingMaskIntoConstraints = false

        repoLabel.font = .systemFont(ofSize: 11)
        repoLabel.textColor = .secondaryLabelColor
        repoLabel.lineBreakMode = .byTruncatingMiddle
        repoLabel.translatesAutoresizingMaskIntoConstraints = false

        keyButton.title = "Set API Key…"
        keyButton.bezelStyle = .rounded
        keyButton.controlSize = .small
        keyButton.target = self
        keyButton.action = #selector(promptForKey)
        keyButton.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(modelPicker)
        bar.addSubview(repoLabel)
        bar.addSubview(keyButton)

        // Transcript: a vertical stack of chat bubbles, scrolled top-down.
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false
        transcriptScroll.drawsBackground = false
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.hasHorizontalScroller = false
        transcriptScroll.scrollerStyle = .overlay
        transcriptScroll.autohidesScrollers = true
        transcriptStack.orientation = .vertical
        transcriptStack.alignment = .leading
        transcriptStack.spacing = 10
        transcriptStack.translatesAutoresizingMaskIntoConstraints = false
        transcriptScroll.documentView = transcriptStack
        NSLayoutConstraint.activate([
            transcriptStack.topAnchor.constraint(equalTo: transcriptScroll.contentView.topAnchor, constant: 14),
            transcriptStack.leadingAnchor.constraint(equalTo: transcriptScroll.contentView.leadingAnchor, constant: 14),
            transcriptStack.trailingAnchor.constraint(equalTo: transcriptScroll.contentView.trailingAnchor, constant: -14),
        ])

        // Input (multiline; Enter sends, Shift+Enter newline).
        inputScroll.translatesAutoresizingMaskIntoConstraints = false
        inputScroll.drawsBackground = true
        inputScroll.backgroundColor = Palette.editorBackground
        inputScroll.borderType = .noBorder
        inputScroll.hasVerticalScroller = true
        inputScroll.scrollerStyle = .overlay
        inputScroll.autohidesScrollers = true
        inputScroll.wantsLayer = true
        inputScroll.layer?.cornerRadius = 8
        inputScroll.layer?.masksToBounds = true
        inputView.delegate = self
        inputView.font = .systemFont(ofSize: 13)
        inputView.textColor = Palette.sidebarText
        inputView.drawsBackground = false
        inputView.textContainerInset = NSSize(width: 6, height: 6)
        inputView.isVerticallyResizable = true
        inputView.isHorizontallyResizable = false
        inputView.autoresizingMask = [.width]
        inputView.textContainer?.widthTracksTextView = true
        inputScroll.documentView = inputView

        sendButton.title = "Send"
        sendButton.bezelStyle = .rounded
        sendButton.controlSize = .small
        sendButton.keyEquivalent = "\r"
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        // Project-aware starter prompts, shown above the input until the first message.
        suggestionsStack.orientation = .horizontal
        suggestionsStack.spacing = 6
        suggestionsStack.alignment = .centerY
        suggestionsStack.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(bar)
        containerView.addSubview(transcriptScroll)
        containerView.addSubview(suggestionsStack)
        containerView.addSubview(inputScroll)
        containerView.addSubview(sendButton)   // added last → floats on top, inside the input box

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: containerView.topAnchor),
            bar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 36),
            modelPicker.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            modelPicker.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            repoLabel.leadingAnchor.constraint(equalTo: modelPicker.trailingAnchor, constant: 10),
            repoLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            repoLabel.trailingAnchor.constraint(lessThanOrEqualTo: keyButton.leadingAnchor, constant: -8),
            keyButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            keyButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            transcriptScroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            transcriptScroll.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            transcriptScroll.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            transcriptScroll.bottomAnchor.constraint(equalTo: suggestionsStack.topAnchor, constant: -4),

            suggestionsStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            suggestionsStack.trailingAnchor.constraint(lessThanOrEqualTo: containerView.trailingAnchor, constant: -12),
            suggestionsStack.bottomAnchor.constraint(equalTo: inputScroll.topAnchor, constant: -8),

            inputScroll.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 10),
            inputScroll.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -10),
            inputScroll.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -10),
            inputScroll.heightAnchor.constraint(equalToConstant: 64),
            // Send nested inside the input box, bottom-right.
            sendButton.trailingAnchor.constraint(equalTo: inputScroll.trailingAnchor, constant: -8),
            sendButton.bottomAnchor.constraint(equalTo: inputScroll.bottomAnchor, constant: -8),
            sendButton.widthAnchor.constraint(equalToConstant: 60),
        ])
        updateSuggestions()
    }

    // MARK: - Suggestions

    private func updateSuggestions() {
        suggestionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let prompts: [String] = repoPath != nil
            ? ["Summarize this repo", "What changed recently?", "What should I work on?", "Explain the architecture"]
            : ["What can you help with?", "Explain a concept", "Review some code", "Draft a plan"]
        for prompt in prompts {
            let chip = NSButton(title: prompt, target: self, action: #selector(suggestionTapped(_:)))
            chip.bezelStyle = .rounded
            chip.controlSize = .small
            chip.font = .systemFont(ofSize: 11)
            suggestionsStack.addArrangedSubview(chip)
        }
    }

    @objc private func suggestionTapped(_ sender: NSButton) {
        guard !isStreaming else { return }
        inputView.string = sender.title
        send()
    }

    // MARK: - Sending

    @objc private func sendTapped() { send() }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Enter sends; Shift/Option+Enter inserts a newline (the default for those selectors).
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            send()
            return true
        }
        return false
    }

    private func send() {
        guard !isStreaming else { return }
        let text = inputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard APIKeyStore.hasKey else { promptForKey(); return }

        inputView.string = ""
        suggestionsStack.isHidden = true   // starter prompts disappear once the conversation begins
        addRow(ChatRow(isUser: true, text: text, accent: Self.accent))
        messages.append(ClaudeMessage(role: "user", text: text))

        let assistantRow = ChatRow(isUser: false, text: "", accent: Self.accent)
        currentAssistantRow = assistantRow
        addRow(assistantRow)
        isStreaming = true
        sendButton.isEnabled = false

        let system = systemPrompt()
        let model = selectedModel
        let history = messages
        streamTask = Task { @MainActor in
            var reply = ""
            do {
                for try await delta in ClaudeClient.stream(system: system, messages: history, model: model) {
                    reply += delta
                    self.currentAssistantRow?.append(delta)
                    self.scrollToBottom()
                }
            } catch {
                self.currentAssistantRow?.append("\n[\(error.localizedDescription)]")
            }
            if reply.isEmpty { self.currentAssistantRow?.append("…") }
            else { self.messages.append(ClaudeMessage(role: "assistant", text: reply)) }
            self.isStreaming = false
            self.sendButton.isEnabled = true
        }
    }

    private func systemPrompt() -> String {
        var prompt = """
        You are Claude, embedded as an assistant panel inside Sprawl — a spatial-canvas macOS \
        developer environment. Help the user with their software project. Be concise and practical, \
        and use Markdown.
        """
        if !repoContext.isEmpty { prompt += "\n\n" + repoContext }
        return prompt
    }

    // MARK: - Repo context

    private func loadRepoContext(_ path: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let branch = Self.git(path, ["rev-parse", "--abbrev-ref", "HEAD"])
            let log = Self.git(path, ["log", "--oneline", "-10"])
            let status = Self.git(path, ["status", "-s"])
            let context = """
            The user is working in the git repository at \(path) (branch \(branch.isEmpty ? "?" : branch)).
            Recent commits:
            \(log.isEmpty ? "(none)" : log)
            Working tree status:
            \(status.isEmpty ? "(clean)" : status)
            """
            DispatchQueue.main.async {
                self?.repoContext = context
                self?.updateRepoLabel()
            }
        }
    }

    private static func git(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func updateRepoLabel() {
        if let repoPath {
            repoLabel.stringValue = "◇ " + (repoPath as NSString).lastPathComponent
            repoLabel.toolTip = repoPath
        } else {
            repoLabel.stringValue = "No repo context"
            repoLabel.toolTip = nil
        }
    }

    // MARK: - API key

    private func updateKeyButton() { keyButton.isHidden = APIKeyStore.hasKey }

    @objc private func promptForKey() {
        let alert = NSAlert()
        alert.messageText = "Anthropic API Key"
        alert.informativeText = "Paste your Anthropic API key. It's stored in your macOS Keychain, not in the workspace file."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-…"
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { APIKeyStore.save(key) }
            updateKeyButton()
        }
    }

    // MARK: - Transcript rendering

    private static let accent = NSColor(srgbRed: 0x9E / 255, green: 0x63 / 255, blue: 0xE0 / 255, alpha: 1)

    private func showWelcome() {
        let tip = repoPath == nil
            ? "Ask Claude about this project. (Tip: create this panel inside a project with a Git widget to auto-load repo context.)"
            : "Ask Claude about this project. Repo context is loaded."
        let label = NSTextField(wrappingLabelWithString: tip)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addRow(label)
    }

    private func addRow(_ view: NSView) {
        transcriptStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: transcriptStack.widthAnchor).isActive = true
        scrollToBottom()
    }

    private func scrollToBottom() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.transcriptStack.layoutSubtreeIfNeeded()
            let maxY = max(0, self.transcriptStack.bounds.height)
            self.transcriptStack.scrollToVisible(NSRect(x: 0, y: maxY - 1, width: 1, height: 1))
        }
    }
}

/// A vertical stack that lays its content out top-down (so it reads correctly as a scroll's
/// document view).
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// One chat bubble row: a rounded bubble pinned right (user, accent) or left (assistant, subtle),
/// holding a wrapping, selectable label.
final class ChatRow: NSView {
    private let bubble = NSView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let hpad: CGFloat = 12

    init(isUser: Bool, text: String, accent: NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 13
        bubble.layer?.backgroundColor = (isUser ? accent : NSColor(white: 1, alpha: 0.07)).cgColor
        bubble.translatesAutoresizingMaskIntoConstraints = false
        // Claude's replies are Markdown → render them monospaced; user messages stay proportional.
        label.font = isUser ? .systemFont(ofSize: 13) : .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = isUser ? .white : NSColor(white: 0.92, alpha: 1)
        label.isSelectable = true
        label.stringValue = text
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubble)
        bubble.addSubview(label)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: topAnchor),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -9),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: hpad),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -hpad),
        ])
        if isUser {
            // User messages hug their content, right-aligned, up to 85% of the width.
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
            bubble.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.85).isActive = true
        } else {
            // Claude's responses fill 85% of the width, left-aligned.
            bubble.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            bubble.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.85).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func append(_ s: String) { label.stringValue += s }

    override func layout() {
        super.layout()
        // Wrap at 85% of the row width (a stable value) rather than the bubble's own width — deriving
        // it from the bubble creates a feedback loop that collapses short messages into a narrow
        // column. Short text stays one line; long text grows to 85% then wraps. Guard the assignment
        // (setting it re-triggers layout) so it doesn't loop.
        let w = max(40, bounds.width * 0.85 - hpad * 2)
        if abs(label.preferredMaxLayoutWidth - w) > 0.5 {
            label.preferredMaxLayoutWidth = w
        }
    }
}
