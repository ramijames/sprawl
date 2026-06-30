import AppKit

/// A first-class Claude assistant panel. Streams chat from the Anthropic Messages API, offers a
/// model picker, and — its spatial twist — auto-inherits the git repo of the project card it was
/// created in, so it answers with that repo's branch/status/recent-commit context.
final class ClaudePanel: NSObject, NSTextViewDelegate {
    let containerView = NSView()
    private let modelPicker = NSPopUpButton()
    private let repoLabel = NSTextField(labelWithString: "")
    private let keyButton = NSButton()
    private let transcriptView = NSTextView()
    private let transcriptScroll = NSScrollView()
    private let inputView = NSTextView()
    private let inputScroll = NSScrollView()
    private let sendButton = NSButton()

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

        // Transcript (read-only, streamed into).
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false
        transcriptScroll.drawsBackground = false
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.scrollerStyle = .overlay
        transcriptScroll.autohidesScrollers = true
        transcriptView.isEditable = false
        transcriptView.isRichText = true
        transcriptView.drawsBackground = false
        transcriptView.textContainerInset = NSSize(width: 10, height: 10)
        transcriptView.isVerticallyResizable = true
        transcriptView.isHorizontallyResizable = false
        transcriptView.autoresizingMask = [.width]
        transcriptView.textContainer?.widthTracksTextView = true
        transcriptScroll.documentView = transcriptView

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
        sendButton.keyEquivalent = "\r"
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(bar)
        containerView.addSubview(transcriptScroll)
        containerView.addSubview(inputScroll)
        containerView.addSubview(sendButton)

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

            inputScroll.topAnchor.constraint(equalTo: transcriptScroll.bottomAnchor, constant: 6),
            inputScroll.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 10),
            inputScroll.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -10),
            inputScroll.heightAnchor.constraint(equalToConstant: 56),
            sendButton.leadingAnchor.constraint(equalTo: inputScroll.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -10),
            sendButton.bottomAnchor.constraint(equalTo: inputScroll.bottomAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 64),
        ])
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
        appendBlock(role: "You", color: Palette.sidebarText)
        appendBody(text)
        messages.append(ClaudeMessage(role: "user", text: text))

        appendBlock(role: selectedModel.displayName, color: Self.accent)
        let assistantStart = transcriptView.textStorage?.length ?? 0
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
                    self.appendBody(delta)
                }
            } catch {
                self.appendBody("\n[\(error.localizedDescription)]")
            }
            if !reply.isEmpty { self.messages.append(ClaudeMessage(role: "assistant", text: reply)) }
            _ = assistantStart
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
        appendBody("Ask Claude about this project. ", color: .secondaryLabelColor)
        if repoPath == nil {
            appendBody("(Tip: create this panel inside a project that has a Git widget to auto-load repo context.)\n",
                       color: .secondaryLabelColor)
        } else {
            appendBody("Repo context is loaded.\n", color: .secondaryLabelColor)
        }
    }

    private func appendBlock(role: String, color: NSColor) {
        let header = NSAttributedString(string: "\n\(role)\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: color,
        ])
        transcriptView.textStorage?.append(header)
        scrollToBottom()
    }

    private func appendBody(_ text: String, color: NSColor = NSColor(white: 0.92, alpha: 1)) {
        let body = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: color,
        ])
        transcriptView.textStorage?.append(body)
        scrollToBottom()
    }

    private func scrollToBottom() {
        transcriptView.scrollToEndOfDocument(nil)
    }
}
