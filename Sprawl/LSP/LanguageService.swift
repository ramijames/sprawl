import Foundation

/// Drives one language server for a repository: starts it, performs the LSP handshake, keeps open
/// documents in sync, and exposes completion / hover / definition. Language-agnostic — the server
/// command is chosen by `descriptor(forExtension:)` (Swift via sourcekit-lsp; JS/TS via
/// typescript-language-server). One instance per server "family" (see `serverKey`).
final class LanguageService {
    struct Completion { let label: String; let detail: String?; let insertText: String; let kind: Int }
    struct Diagnostic { let line, character, endLine, endChar: Int; let severity: Int; let message: String }
    struct Definition { let url: URL; let line: Int; let character: Int }
    struct TextEdit { let startLine, startChar, endLine, endChar: Int; let newText: String }

    let root: URL
    let serverKey: String
    private let command: String
    private let arguments: [String]
    private let client = LSPClient()
    private(set) var started = false
    private var versions: [String: Int] = [:]

    /// Diagnostics pushed by the server for a file (delivered on the main queue).
    var onDiagnostics: ((_ url: URL, _ diagnostics: [Diagnostic]) -> Void)?

    init(root: URL, serverKey: String, command: String, arguments: [String]) {
        self.root = root
        self.serverKey = serverKey
        self.command = command
        self.arguments = arguments
    }

    /// The server "family" + executable for a file extension, or nil if unsupported / not installed.
    static func descriptor(forExtension ext: String) -> (serverKey: String, command: String, arguments: [String])? {
        switch ext.lowercased() {
        case "swift":
            return ("swift", "/usr/bin/xcrun", ["sourcekit-lsp"])
        case "ts", "tsx", "js", "jsx", "mjs", "cjs":
            guard let bin = resolve("typescript-language-server") else { return nil }
            return ("typescript", bin, ["--stdio"])
        default:
            return nil
        }
    }

    /// The LSP `languageId` for a document of this extension.
    static func languageId(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "swift": return "swift"
        case "ts": return "typescript"
        case "tsx": return "typescriptreact"
        case "jsx": return "javascriptreact"
        case "js", "mjs", "cjs": return "javascript"
        default: return "plaintext"
        }
    }

    /// Resolve an executable on the user's *login* PATH (so nvm / Homebrew / npm-global are found —
    /// an app launched from Finder has a minimal PATH). Cached.
    private static var resolveCache: [String: String?] = [:]
    private static func resolve(_ name: String) -> String? {
        if let cached = resolveCache[name] { return cached }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = Pipe()
        var path: String?
        do {
            try shell.run()
            shell.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if shell.terminationStatus == 0, !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) {
                path = out
            }
        } catch { path = nil }
        resolveCache[name] = path
        return path
    }

    func start() async {
        guard !started else { return }
        client.onNotification = { [weak self] method, params in self?.handle(method, params) }
        do {
            try client.start(command: command, arguments: arguments, currentDirectory: root)
        } catch {
            return
        }
        let params: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "rootUri": Self.uri(root),
            "capabilities": [
                "textDocument": [
                    "completion": ["completionItem": ["snippetSupport": false]],
                    "hover": ["contentFormat": ["markdown", "plaintext"]],
                    "definition": [:],
                    "publishDiagnostics": [:],
                ],
            ],
            "workspaceFolders": [["uri": Self.uri(root), "name": root.lastPathComponent]],
        ]
        _ = try? await client.request("initialize", params)
        client.notify("initialized", [:])
        started = true
    }

    func stop() { client.stop() }

    // MARK: - Document sync

    func didOpen(_ url: URL, text: String) {
        versions[url.path] = 1
        client.notify("textDocument/didOpen", ["textDocument": [
            "uri": Self.uri(url), "languageId": Self.languageId(forExtension: url.pathExtension),
            "version": 1, "text": text]])
    }

    func didChange(_ url: URL, text: String) {
        let version = (versions[url.path] ?? 1) + 1
        versions[url.path] = version
        client.notify("textDocument/didChange", [
            "textDocument": ["uri": Self.uri(url), "version": version],
            "contentChanges": [["text": text]]])   // full-document sync
    }

    func didClose(_ url: URL) {
        client.notify("textDocument/didClose", ["textDocument": ["uri": Self.uri(url)]])
    }

    // MARK: - Requests (line/character are 0-based LSP positions)

    func completions(_ url: URL, line: Int, character: Int) async -> [Completion] {
        let result = try? await client.request("textDocument/completion", [
            "textDocument": ["uri": Self.uri(url)], "position": ["line": line, "character": character]])
        let raw = (result as? [String: Any])?["items"] as? [[String: Any]] ?? (result as? [[String: Any]]) ?? []
        return raw.map {
            let label = $0["label"] as? String ?? ""
            let insert = ($0["insertText"] as? String) ?? (($0["textEdit"] as? [String: Any])?["newText"] as? String) ?? label
            return Completion(label: label, detail: $0["detail"] as? String, insertText: insert,
                              kind: $0["kind"] as? Int ?? 0)
        }
    }

    func hover(_ url: URL, line: Int, character: Int) async -> String? {
        let result = try? await client.request("textDocument/hover", [
            "textDocument": ["uri": Self.uri(url)], "position": ["line": line, "character": character]])
        guard let contents = (result as? [String: Any])?["contents"] else { return nil }
        if let s = contents as? String { return s }
        if let dict = contents as? [String: Any] { return dict["value"] as? String }
        if let arr = contents as? [Any] {
            return arr.compactMap { ($0 as? String) ?? ($0 as? [String: Any])?["value"] as? String }.joined(separator: "\n")
        }
        return nil
    }

    func definition(_ url: URL, line: Int, character: Int) async -> Definition? {
        let result = try? await client.request("textDocument/definition", [
            "textDocument": ["uri": Self.uri(url)], "position": ["line": line, "character": character]])
        let location = (result as? [[String: Any]])?.first ?? (result as? [String: Any])
        guard let location,
              let uri = (location["uri"] as? String) ?? (location["targetUri"] as? String),
              let range = (location["range"] as? [String: Any]) ?? (location["targetSelectionRange"] as? [String: Any]),
              let start = range["start"] as? [String: Any],
              let target = Self.url(fromURI: uri) else { return nil }
        return Definition(url: target, line: start["line"] as? Int ?? 0, character: start["character"] as? Int ?? 0)
    }

    /// The active signature label at a position (for signature help), or nil.
    func signatureHelp(_ url: URL, line: Int, character: Int) async -> String? {
        let result = try? await client.request("textDocument/signatureHelp", [
            "textDocument": ["uri": Self.uri(url)], "position": ["line": line, "character": character]])
        guard let dict = result as? [String: Any],
              let sigs = dict["signatures"] as? [[String: Any]], !sigs.isEmpty else { return nil }
        let active = min(dict["activeSignature"] as? Int ?? 0, sigs.count - 1)
        return sigs[active]["label"] as? String
    }

    /// A rename across the workspace: the edits per file (empty if unsupported / no symbol).
    func rename(_ url: URL, line: Int, character: Int, newName: String) async -> [URL: [TextEdit]] {
        let result = try? await client.request("textDocument/rename", [
            "textDocument": ["uri": Self.uri(url)], "position": ["line": line, "character": character],
            "newName": newName])
        guard let dict = result as? [String: Any] else { return [:] }
        var map: [URL: [TextEdit]] = [:]
        if let changes = dict["changes"] as? [String: [[String: Any]]] {
            for (uri, edits) in changes where Self.url(fromURI: uri) != nil {
                map[Self.url(fromURI: uri)!] = edits.compactMap(Self.parseEdit)
            }
        } else if let docChanges = dict["documentChanges"] as? [[String: Any]] {
            for dc in docChanges {
                guard let td = dc["textDocument"] as? [String: Any], let uri = td["uri"] as? String,
                      let target = Self.url(fromURI: uri), let edits = dc["edits"] as? [[String: Any]] else { continue }
                map[target] = edits.compactMap(Self.parseEdit)
            }
        }
        return map
    }

    func formatting(_ url: URL) async -> [TextEdit] {
        let result = try? await client.request("textDocument/formatting", [
            "textDocument": ["uri": Self.uri(url)],
            "options": ["tabSize": 4, "insertSpaces": true]])
        return (result as? [[String: Any]])?.compactMap(Self.parseEdit) ?? []
    }

    private static func parseEdit(_ d: [String: Any]) -> TextEdit? {
        guard let range = d["range"] as? [String: Any],
              let start = range["start"] as? [String: Any], let end = range["end"] as? [String: Any],
              let newText = d["newText"] as? String else { return nil }
        return TextEdit(startLine: start["line"] as? Int ?? 0, startChar: start["character"] as? Int ?? 0,
                        endLine: end["line"] as? Int ?? 0, endChar: end["character"] as? Int ?? 0, newText: newText)
    }

    // MARK: - Notifications

    private func handle(_ method: String, _ params: [String: Any]) {
        guard method == "textDocument/publishDiagnostics",
              let uri = params["uri"] as? String, let url = Self.url(fromURI: uri) else { return }
        let raw = params["diagnostics"] as? [[String: Any]] ?? []
        let diagnostics = raw.compactMap { d -> Diagnostic? in
            guard let range = d["range"] as? [String: Any], let start = range["start"] as? [String: Any] else { return nil }
            let end = range["end"] as? [String: Any] ?? start
            return Diagnostic(line: start["line"] as? Int ?? 0, character: start["character"] as? Int ?? 0,
                              endLine: end["line"] as? Int ?? 0, endChar: end["character"] as? Int ?? 0,
                              severity: d["severity"] as? Int ?? 1, message: d["message"] as? String ?? "")
        }
        onDiagnostics?(url, diagnostics)
    }

    // MARK: - URI helpers

    private static func uri(_ url: URL) -> String { url.absoluteURL.standardizedFileURL.absoluteString }
    private static func url(fromURI uri: String) -> URL? { URL(string: uri) }
}
