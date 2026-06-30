# Claude × Sprawl — Integration Spec

Build-ready spec for integrating Claude into Sprawl. Generated from a multi-lens design pass and a per-feature spec fan-out. **Framing:** Claude is a *spatial citizen of the canvas*, not a chat sidebar — output rendered as panels/connectors, context assembled by dragging panels together, the canvas usable as Claude's output medium.

> Status note: the **Claude Panel MVP is already built** (`Sprawl/AI/ClaudeClient.swift`, `Sprawl/AI/APIKeyStore.swift`, `Sprawl/Content/ClaudePanel.swift`) as a minimal subset of the Foundation below (streaming chat, model picker, Keychain key, repo-aware system prompt). The Foundation spec here is the fuller target the Phase 2/3 features build on (tool-use loop, thinking/effort params, the CanvasTools seam, a richer transcript view).

## Roadmap & index

| Feature | Phase | Status |
|---|---|---|
| Claude Panel (project-scoped) | Phase 1 | ✅ MVP shipped (minimal subset of the foundation) |
| Terminal Fix Card | Phase 1 | Planned |
| Commit Messages / Release Notes / Git Narration | Phase 1 | Planned |
| Context Wires | Phase 2 | Planned |
| Editor ⌘K Inline Edit | Phase 2 | Planned |
| Workspace Conductor | Phase 2 | Planned |
| Sprawl as an MCP Server | Phase 3 | Planned |
| Cross-project Stale/WIP Radar | Phase 3 | Planned |
| Spatial Recall (⌘K) | Phase 3 | Planned |
| Lasso-to-Ask (Vision) | Phase 3 | Planned |

---

# Sprawl × Claude — FOUNDATION Spec

Shared infrastructure every Claude feature in Sprawl reuses. Build this layer first; Phase 2/3 features (assistant panel, inline completions, agent tools) all sit on top. Native macOS 14 / Swift 5 / AppKit, no third-party SDK — Anthropic ships no official Swift SDK, so we hit the REST Messages API over `URLSession` directly.

All new files go under `Sprawl/Claude/`. **Adding source files requires `xcodegen generate`** (the `.xcodeproj` is gitignored, generated from `project.yml`). See §5 for the build step.

```
Sprawl/Claude/
  ClaudeClient.swift        // §1 networking + SSE + retry + tool loop
  ClaudeTypes.swift         // §1 request/response/SSE model types
  ClaudeModel.swift         // §3 model registry
  ClaudeAuth.swift          // §2 Keychain + key resolution
  ClaudeSettings.swift      // §2 onboarding/settings affordance (paste key)
  CanvasTools.swift         // §6 tool-layer seam (design only)
  StreamingTranscriptView.swift  // §7 reusable NSTextView renderer
```

---

## 1. `ClaudeClient` — networking layer

### 1a. Model types (`ClaudeTypes.swift`)

Wire types are `Codable` and use the API's snake_case via explicit `CodingKeys` (keeps Swift call sites camelCase). Everything is value types except the streamed accumulator.

```swift
import Foundation

// MARK: Request

struct ClaudeRequest: Encodable {
    var model: String                       // ClaudeModel.id
    var maxTokens: Int
    var system: [SystemBlock]?              // array form so we can attach cache_control
    var messages: [Message]
    var tools: [ToolDefinition]?
    var toolChoice: ToolChoice?
    var thinking: Thinking?                 // {type:"adaptive"} on 4.6+; nil = off
    var outputConfig: OutputConfig?         // effort lives here, NOT top-level
    var stream: Bool = true

    enum CodingKeys: String, CodingKey {
        case model, system, messages, tools, thinking, stream
        case maxTokens = "max_tokens"
        case toolChoice = "tool_choice"
        case outputConfig = "output_config"
    }
}

struct SystemBlock: Encodable {            // text block w/ optional cache breakpoint (§4)
    var type = "text"
    var text: String
    var cacheControl: CacheControl?
    enum CodingKeys: String, CodingKey { case type, text; case cacheControl = "cache_control" }
}

struct CacheControl: Encodable {           // {"type":"ephemeral"} or {...,"ttl":"1h"}
    var type = "ephemeral"
    var ttl: String?                        // "5m" (default, omit) or "1h"
}

struct Thinking: Encodable {
    var type: String = "adaptive"           // 4.6/4.7/4.8: "adaptive" only; budget_tokens is REMOVED (400)
    var display: String? = "summarized"     // default on 4.8 is "omitted" (empty text) — opt in to stream reasoning
}

struct OutputConfig: Encodable {
    var effort: String?                     // "low" | "medium" | "high" | "max" (xhigh on 4.7/4.8)
}

struct ToolChoice: Encodable {
    var type: String                        // "auto" | "any" | "tool" | "none"
    var name: String?                       // when type == "tool"
    var disableParallelToolUse: Bool?
    enum CodingKeys: String, CodingKey { case type, name; case disableParallelToolUse = "disable_parallel_tool_use" }
}

// MARK: Messages & content blocks

struct Message: Codable {
    var role: String                        // "user" | "assistant" (system goes top-level)
    var content: [ContentBlock]
    init(role: String, text: String) { self.role = role; self.content = [.text(text)] }
    init(role: String, content: [ContentBlock]) { self.role = role; self.content = content }
}

enum ContentBlock: Codable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: String, isError: Bool)
    // thinking blocks are echoed back verbatim on multi-turn; carried opaque:
    case thinking(thinking: String, signature: String)
    case raw(JSONValue)                     // forward-compat fallback for unknown block types
    // Codable impl switches on "type": text|tool_use|tool_result|thinking. Unknown -> .raw
}

// MARK: Tools (definitions consumed by the tool loop, §1d / §6)

struct ToolDefinition: Encodable {
    var name: String
    var description: String
    var inputSchema: JSONValue              // JSON Schema object
    enum CodingKeys: String, CodingKey { case name, description; case inputSchema = "input_schema" }
}

// MARK: Non-streaming response (for tool-loop assembly & Batches later)

struct ClaudeMessageResponse: Decodable {
    var id: String
    var model: String
    var role: String
    var content: [ContentBlock]
    var stopReason: String?                 // "end_turn"|"max_tokens"|"tool_use"|"pause_turn"|"refusal"
    var stopDetails: StopDetails?           // non-null ONLY when stopReason == "refusal"
    var usage: Usage
    enum CodingKeys: String, CodingKey { case id, model, role, content, usage
        case stopReason = "stop_reason"; case stopDetails = "stop_details" }
}

struct StopDetails: Decodable { var type: String; var category: String?; var explanation: String? }

struct Usage: Decodable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationInputTokens: Int?
    var cacheReadInputTokens: Int?
    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"; case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }
}

/// Minimal recursive JSON value so we can carry arbitrary tool input/schema without codegen.
indirect enum JSONValue: Codable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])
}
```

### 1b. Streaming delta — the public surface

The whole client funnels SSE into one ordered `AsyncStream<ClaudeDelta>`. Features consume this; they never parse SSE themselves.

```swift
enum ClaudeDelta: Sendable {
    case messageStart(id: String, model: String)
    case textDelta(String)                  // append to transcript
    case thinkingDelta(String)              // append to a thinking region (dimmed)
    case toolUseStart(index: Int, id: String, name: String)
    case toolInputDelta(index: Int, partialJSON: String)   // input_json_delta — accumulate per index
    case toolUseStop(index: Int)
    case messageDelta(stopReason: String?, usage: Usage?)   // final usage arrives here
    case messageStop
    case usage(Usage)                       // convenience: surfaced again at stop for cost UI
    // errors are NOT a case — they throw out of the stream (see Failure type below)
}
```

SSE events handled (each `event:`/`data:` pair): `message_start`, `content_block_start` (text / thinking / tool_use), `content_block_delta` (`text_delta`, `thinking_delta`, `input_json_delta`), `content_block_stop`, `message_delta`, `message_stop`, `error`, `ping` (ignored). Unknown event names are ignored (forward-compat).

### 1c. `ClaudeClient` API

```swift
actor ClaudeClient {
    static let shared = ClaudeClient()

    private let session: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let anthropicVersion = "2023-06-01"

    init(session: URLSession = .shared) { self.session = session }

    /// Streaming entry point. Throws ClaudeError before yielding if there's no key / bad request.
    /// Cancellation: cancel the consuming Task; the underlying URLSession.bytes task is cancelled
    /// in the AsyncStream's onTermination handler.
    func stream(_ request: ClaudeRequest) -> AsyncThrowingStream<ClaudeDelta, Error>

    /// Non-streaming convenience used by the tool loop (§1d) and any caller that just wants the
    /// final assembled message. Internally drains stream() and reduces deltas into a response.
    func send(_ request: ClaudeRequest) async throws -> ClaudeMessageResponse
}
```

Implementation notes:
- Build `URLRequest`: `httpMethod = "POST"`, headers `x-api-key` (from §2), `anthropic-version`, `content-type: application/json`. Body = `JSONEncoder().encode(request)` with `stream = true`.
- Use `for try await line in session.bytes(for:req).0.lines` to read SSE line-by-line. Parse `event:` then `data:`; on blank line dispatch. Decode each `data:` JSON into the matching delta.
- **Refusal handling:** on `message_delta` with `stopReason == "refusal"`, discard any partial text and throw `ClaudeError.refused(StopDetails)`. Features show the refusal explanation rather than a half-message.
- The `AsyncThrowingStream` `onTermination` cancels the `URLSession` data task — this is how consumer cancellation propagates.

```swift
enum ClaudeError: Error {
    case noAPIKey                           // §2: route to settings/onboarding
    case http(status: Int, type: String?, message: String?)   // decoded API error body
    case refused(StopDetails)
    case rateLimited(retryAfter: TimeInterval?)
    case transport(Error)
    case decoding(Error)
}
```

### 1d. Retry / backoff

Wrap the request attempt. Retry on **429** and **5xx (incl. 529 overloaded)** and transport errors; never retry 4xx (400/401/403/404). Honor `retry-after` (seconds) header when present; otherwise exponential backoff with jitter.

```swift
private func withRetry<T>(max attempts: Int = 4,
                          base: TimeInterval = 1.0,
                          maxDelay: TimeInterval = 30,
                          _ op: () async throws -> T) async throws -> T {
    var attempt = 0
    while true {
        do { return try await op() }
        catch let e as ClaudeError {
            attempt += 1
            guard attempt < attempts, e.isRetryable else { throw e }
            let delay = e.retryAfter ?? min(maxDelay, base * pow(2, Double(attempt - 1)))
                        + Double.random(in: 0...0.5)
            try await Task.sleep(nanoseconds: UInt64(delay * 1e9))
        }
    }
}
```

For streaming, retry only applies to establishing the connection / first byte. Once tokens have streamed, a mid-stream drop surfaces as `ClaudeError.transport` to the consumer (don't silently re-issue a billed request).

### 1e. Tool-use loop scaffold (defined now, unused in MVP)

```swift
/// Drives: assistant emits tool_use blocks -> app runs tools -> resends tool_result -> repeat
/// until stop_reason != "tool_use". MVP passes tools: nil so this never iterates; Phase 2 wires
/// CanvasTools (§6) as the runner.
protocol ClaudeToolRunner {
    var definitions: [ToolDefinition] { get }
    /// Execute one tool_use block on the main actor (app actions touch AppKit), return its result.
    func run(name: String, input: JSONValue) async -> (content: String, isError: Bool)
}

extension ClaudeClient {
    func runToolLoop(_ request: ClaudeRequest,
                     runner: ClaudeToolRunner,
                     maxTurns: Int = 8,
                     onText: @escaping (String) -> Void) async throws -> ClaudeMessageResponse {
        var req = request
        req.tools = runner.definitions
        for _ in 0..<maxTurns {
            let resp = try await send(req)            // collect full message
            // forward text blocks to onText for live UI...
            let toolUses = resp.content.compactMap { /* .toolUse */ }
            if resp.stopReason != "tool_use" || toolUses.isEmpty { return resp }
            // append assistant turn (full content, incl. tool_use), then a user turn of tool_results
            var results: [ContentBlock] = []
            for tu in toolUses {
                let (content, isError) = await runner.run(name: tu.name, input: tu.input)
                results.append(.toolResult(toolUseID: tu.id, content: content, isError: isError))
            }
            req.messages.append(Message(role: "assistant", content: resp.content))
            req.messages.append(Message(role: "user", content: results))   // ALL results in ONE user msg
        }
        throw ClaudeError.http(status: 0, type: "tool_loop", message: "exceeded maxTurns")
    }
}
```

---

## 2. Auth — Keychain + onboarding (`ClaudeAuth.swift`, `ClaudeSettings.swift`)

Store `ANTHROPIC_API_KEY` in the macOS Keychain (`kSecClassGenericPassword`). Never in `UserDefaults`/`workspace.json`.

```swift
enum ClaudeAuth {
    private static let service = "com.sprawl.anthropic"
    private static let account = "ANTHROPIC_API_KEY"

    static func apiKey() -> String? {
        // 1. Environment override (dev convenience): ProcessInfo ANTHROPIC_API_KEY
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
        // 2. Keychain
        return readKeychain()
    }

    static func setAPIKey(_ key: String) throws   // SecItemAdd / SecItemUpdate
    static func clearAPIKey() throws              // SecItemDelete
    static var hasKey: Bool { apiKey() != nil }

    private static func readKeychain() -> String? { /* SecItemCopyMatching */ }
}
```

`ClaudeClient` calls `ClaudeAuth.apiKey()` at request-build time. If nil → throw `ClaudeError.noAPIKey` **before** any network call.

**Onboarding affordance** (`ClaudeSettings.swift`): a minimal `NSViewController` with a secure text field + Save/Clear, presented as a sheet or popover. Wired into the existing menu in `AppDelegate.setupMenu()` — add a "Settings…" item (⌘,) to the app menu (after line 160, alongside Quit) routing to `MainSplitViewController.showClaudeSettings(_:)`. Any feature that catches `ClaudeError.noAPIKey` calls the same presenter, so a key-less user is funneled to paste a key in context rather than silently failing. No key + no feature invoked = no behavior change (Sprawl works exactly as today).

---

## 3. Model registry (`ClaudeModel.swift`)

```swift
enum ClaudeModel: String, CaseIterable {
    case opus  = "claude-opus-4-8"          // most capable
    case sonnet = "claude-sonnet-4-6"        // balanced (interactive default)
    case haiku  = "claude-haiku-4-5"         // fast/cheap

    var id: String { rawValue }
    var displayName: String {
        switch self { case .opus: "Claude Opus 4.8"; case .sonnet: "Claude Sonnet 4.6"; case .haiku: "Claude Haiku 4.5" }
    }
    /// USD per million tokens (input, output).
    var pricing: (input: Double, output: Double) {
        switch self { case .opus: (5, 25); case .sonnet: (3, 15); case .haiku: (1, 5) }
    }
    /// Effort is supported on opus & sonnet; NOT on haiku (would 400). "max" is opus/sonnet only.
    var supportsEffort: Bool { self != .haiku }
    /// All three support adaptive thinking; only set thinking when the task benefits.
    var supportsThinking: Bool { true }
}

/// Per-task defaults — features pick a model by intent, not by hardcoding a string.
enum ClaudeTask {
    case interactive    // chat/assistant panel, completions -> Sonnet
    case bulk           // labeling, classification, batch tagging -> Haiku
    case hard           // deep refactor reasoning, agent planning -> Opus

    var model: ClaudeModel {
        switch self { case .interactive: .sonnet; case .bulk: .haiku; case .hard: .opus }
    }
    /// Where thinking/effort apply: hard mode turns both on; interactive uses light thinking;
    /// bulk uses neither (Haiku has no effort, and labeling doesn't need reasoning).
    var thinking: Thinking? {
        switch self { case .hard: Thinking(type: "adaptive", display: "summarized")
                      case .interactive: Thinking(type: "adaptive", display: "summarized")
                      case .bulk: nil }
    }
    var effort: String? {
        switch self { case .hard: "high"; case .interactive: "medium"; case .bulk: nil }
    }
}
```

Cost UI reads `usage` from the final `messageDelta` and multiplies by `model.pricing`.

---

## 4. Prompt-caching strategy

The Messages API caches by **exact prefix match** (render order `tools → system → messages`); any byte change before a `cache_control` breakpoint invalidates everything after it. Min cacheable prefix on Opus is 4096 tokens, Sonnet 2048, Haiku 4096 — shorter prefixes silently won't cache.

Sprawl's reusable, stable context is **repo and file content** — exactly what we resend across turns. Strategy:

- **Breakpoint 1 — frozen system prompt + tools.** Put the Sprawl assistant persona + tool definitions first, with `cacheControl` on the last `SystemBlock`. Never interpolate volatile data (current time, project UUIDs, selection) into it.
- **Breakpoint 2 — repo/file prefix.** When a feature feeds a repo tree or a file's full text (e.g. "explain this document", git context), emit it as an early user content block with a `cache_control` breakpoint at its end. Re-asking about the same file reuses it at ~0.1× cost.
- **Volatile content goes last**, after the final breakpoint: the user's actual question, current selection, timestamps.
- Max 4 breakpoints/request. Verify with `usage.cacheReadInputTokens > 0` across repeated same-file requests; if zero, audit for a silent invalidator (a `Date()` or UUID landing in the prefix, non-deterministic JSON key order in a serialized repo tree → always sort).

Because panels persist a `workingDirectory`/file path in `ItemState`, the natural cache key is "(model, file path, file bytes)" — stable across a session, so document/git features get cache reads for free once the prefix is stable.

---

## 5. The `assistant` `WorkItem.Kind` wiring

Adding a kind touches **every** switch. `gitObserver` is the exact template — copy it line for line. Anchors below are current line numbers.

**1. `Sprawl/Model/AppModel.swift`**
- `WorkItem.Kind` enum — add `case assistant` after line **12** (`case projectVelocity`).
- `symbolName` switch — add `case .assistant: return "sparkles"` in the block at lines **13–22**.
- Stored panel ref on `WorkItem` — add `var assistant: AssistantPanel?` after line **38** (mirrors `var gitObserver: GitObserverPanel?` at line 34).
- `addItem` name base switch — add `case .assistant: base = "Assistant"` in lines **267–274** (gitObserver is line 271).
- `installItem` build switch — add an `.assistant` case after line **457**, mirroring `.gitObserver` (lines **430–438**): construct `AssistantPanel`, `panel.attach(to: window)`, wire `onTitleChange`, wire any persistable callback to `self.onPersistableChange?()`, set `item.assistant = panel`.
- `snapshot` `kindState` switch — add `case .assistant: kindState = .assistant` in lines **539–547** (gitObserver line 545). If the assistant persists a repo/file path, also extend the `workingDirectory:` expression at line **554**.
- `restore` mapping switch — add a `case .assistant:` in lines **583–603** mirroring `.gitObserver` (lines **592–594**): `kind = .assistant; contentURL = item.workingDirectory.map { URL(fileURLWithPath: $0) }`.

**2. `Sprawl/Persistence/WorkspaceState.swift`**
- `ItemState.Kind` enum — line **64**: add `assistant` to the case list.

**3. `Sprawl/App/FloatingDock.swift`**
- Add `var onNewAssistant: (() -> Void)?` after line **13**.
- Add a folder menu item — in one of the folder closures (lines **39–53**) or a new "AI" folder button: `menu.addItem(self.folderItem("New Assistant", LucideIcon.sparkles) { self.onNewAssistant?() })`.

**4. `Sprawl/App/MainSplitViewController.swift`**
- `installDock()` — add `dock.onNewAssistant = { [weak self] in self?.newItemFromDock(.assistant) }` after line **66**.
- `@objc` action — add `@objc func newAssistant(_ sender: Any?) { model.addItem(kind: .assistant) }` after line **121**.

**5. `Sprawl/App/AppDelegate.swift`**
- File menu — add an item in `setupMenu()` after line **183** (after New Project Velocity), key equivalent `"7"`, action `#selector(MainSplitViewController.newAssistant(_:))`.

**6. `Sprawl/Canvas/CanvasView.swift`**
- Context menu — add `menu.addItem(withTitle: "New Assistant", action: #selector(contextNewAssistant), keyEquivalent: "")` after line **327**.
- Add `@objc private func contextNewAssistant() { createContextItem(.assistant) }` after line **342**.

**7. The panel itself** — new `Sprawl/Claude/AssistantPanel.swift`, following the `GitObserverPanel` shape (`Sprawl/Content/GitObserverPanel.swift`): `let containerView = NSView()`, `init(repoPath:/contextURL:)`, `func attach(to window: WindowView) { window.setContent(containerView) }`, `var onTitleChange: ((String) -> Void)?`, and (if it persists a path) `var onRepoChange: (() -> Void)?`. It hosts a `StreamingTranscriptView` (§7) + an input field, and calls `ClaudeClient.shared.stream(...)`.

**8. `xcodegen generate`** — `AssistantPanel.swift` and all of `Sprawl/Claude/*.swift` are new files. After adding them, run from the repo root:
```
xcodegen generate
xcodebuild -project Sprawl.xcodeproj -scheme Sprawl -configuration Debug build
```
Quit the running app before building so the post-build re-sign/mirror to `./build/Sprawl.app` succeeds.

`addWindow` signature (used by `installItem`): `func addWindow(title: String, frame: NSRect? = nil, size: NSSize = SharedCanvasLayout.defaultPanelSize) -> WindowView` (`CanvasView.swift:565`).

---

## 6. The Tool Layer seam (`CanvasTools.swift`) — design only

Goal: map Claude tool-use blocks to the **existing user code path** so agent writes get the same undo/persist/selection behavior as a human action. Nothing here is built in MVP; the seam is defined so Phase 2/3 drop in.

```swift
/// One concrete ClaudeToolRunner (§1e) backed by AppModel + CanvasViewController.
/// Every tool routes through the SAME methods the dock/menu/context-menu already call, so an
/// agent edit persists (AppModel.onPersistableChange) and selects/animates like a user edit.
@MainActor
final class CanvasTools: ClaudeToolRunner {
    private let model: AppModel
    private weak var canvasVC: CanvasViewController?
    init(model: AppModel, canvasVC: CanvasViewController?) { self.model = model; self.canvasVC = canvasVC }

    var definitions: [ToolDefinition] { Self.schema }   // static JSON-schema tool defs

    func run(name: String, input: JSONValue) async -> (content: String, isError: Bool) {
        switch name {
        case "spawn_panel":   // -> model.addItem(kind:in:at:)  (same path as dock/context menu)
        case "move_panel":    // -> WorkItem.window?.frame; triggers onGeometryChange -> persist
        case "resize_panel":  // -> WorkItem.window?.setFrameSize (clamped to WindowView.minSize)
        case "open_file":     // -> model.addItem(kind:.document,url:) OR existing doc leaf.open(url:)
        case "run_git":       // -> reuse GitObserverPanel.runGitLog-style Process shell-out
        case "read_panel":    // -> read a panel's text (DocumentLeaf text / terminal buffer) back to Claude
        default: return ("unknown tool \(name)", true)
        }
        // ... each case ends by calling model.onPersistableChange?() if it mutated state.
    }
}
```

Design constraints:
- **Single code path.** Tools call `AppModel.addItem`, `removeItem`, panel `window.frame` setters — never bespoke logic. That guarantees autosave (`onPersistableChange` → debounced `WorkspaceStore.save`) and selection visuals fire identically to user actions, so "agent did X" is undoable/persisted with zero extra plumbing.
- **Main-actor.** All tool execution is `@MainActor` (AppKit mutation); the tool loop (§1e) awaits it from the client actor.
- **Identity.** Tools address panels by `WorkItem.id` (UUID); inputs reference panels Claude has seen via `read_panel`/`spawn_panel` return values.
- **Safety.** Mutating tools (`spawn`/`move`/`resize`/`open_file`) are reversible by design (undo = persisted prior state). `run_git` stays read-only in the seam (log/status/diff) — no commit/push from the agent until a confirmation gate exists.

---

## 7. `StreamingTranscriptView` (`StreamingTranscriptView.swift`)

NSTextView-based reusable renderer for streaming markdown-ish text. The assistant panel and any future streaming feature embed it.

```swift
/// Append-only streaming transcript. Owns an NSScrollView+NSTextView; renders incremental
/// text/thinking deltas with light markdown styling and auto-scrolls to the tail.
final class StreamingTranscriptView: NSView {
    private let textView = NSTextView()
    private let scrollView = NSScrollView()

    /// Begin a new assistant turn (inserts a turn separator / role label).
    func beginTurn(role: String)

    /// Append a streamed text delta (main thread). Styled as body text.
    func appendText(_ delta: String)

    /// Append a streamed thinking delta — rendered dimmed/italic in a collapsible region.
    func appendThinking(_ delta: String)

    /// Mark the current turn complete (finalize markdown pass: bold/italic/`code`/```fences```/lists).
    func endTurn(usage: Usage?)

    /// Convenience: drive directly from the client stream.
    @MainActor
    func consume(_ stream: AsyncThrowingStream<ClaudeDelta, Error>) async {
        beginTurn(role: "assistant")
        do {
            for try await delta in stream {
                switch delta {
                case .textDelta(let t):     appendText(t)
                case .thinkingDelta(let t): appendThinking(t)
                case .messageDelta(_, let u): if let u { lastUsage = u }
                case .messageStop:          endTurn(usage: lastUsage)
                default: break
                }
            }
        } catch let ClaudeError.refused(d) {
            appendText("\n[Refused: \(d.explanation ?? d.category ?? "policy")]")
        } catch ClaudeError.noAPIKey {
            // host panel catches & presents §2 settings; surface a hint inline too
            appendText("\n[No API key — open Settings to add one.]")
        } catch { appendText("\n[Error: \(error.localizedDescription)]") }
    }
    private var lastUsage: Usage?
}
```

Rendering: configure `textView` non-editable, `isRichText = true`, dark theme from `Palette.swift` (matches panels). Incremental deltas append to the text storage during streaming (cheap, plain); a final styling pass on `endTurn` applies markdown attributes (`**bold**`, `*italic*`, `` `code` ``, fenced blocks → monospaced background, `- ` lists). Auto-scroll: after each append, scroll to `NSMaxRange` only if the user was already at the bottom (don't yank scroll if they scrolled up to read). Lives inside a `WindowView` content area via the panel's `setContent` (same hosting contract as every other panel).

---

### Cross-references
- Panel hosting contract: `WindowView.setContent(_:)` — `Sprawl/Windows/WindowView.swift:135`.
- Panel template to mirror: `Sprawl/Content/GitObserverPanel.swift` (init / `attach(to:)` / `onTitleChange` / Process shell-out at `runGitLog` line 254).
- Persistence trigger after any model mutation: `AppModel.onPersistableChange` → `AppDelegate.scheduleSave()` (`Sprawl/App/AppDelegate.swift:42,60`).
- All new files require `xcodegen generate` before building (see §5 step 8).


---

# Features


## Claude Panel (project-scoped)

_Phase 1 · ✅ MVP shipped (minimal subset of the foundation)_

# Feature Spec — Claude Panel (project-scoped), MVP

## Summary
A first-class assistant panel (`WorkItem.Kind.assistant`) that lives on the canvas like any other panel and streams a Claude chat conversation. It auto-inherits the git context of the project card it sits in — repo path, current branch, `git status`, and recent `git log` — so the user can ask questions about *this* project without manually pasting context. Pure streaming chat with a model picker; no tool-use, no file edits (Phase 2+).

## Phase
**Phase 1** (the MVP). It is the first feature built directly on the FOUNDATION layer and the reference implementation of the `.assistant` kind. Phase 2 (inline completions / `read_panel`) and Phase 3 (agent tool-use via `CanvasTools`, §6) layer on top of this same panel.

## Depends on
- FOUNDATION §1 `ClaudeClient` / `ClaudeTypes` — streaming via `ClaudeClient.shared.stream(_:)`. Tool loop (§1e) and `CanvasTools` (§6) are **not** used here.
- FOUNDATION §2 `ClaudeAuth` / `ClaudeSettings` — key resolution; panel catches `ClaudeError.noAPIKey` and routes to `MainSplitViewController.showClaudeSettings(_:)`.
- FOUNDATION §3 `ClaudeModel` / `ClaudeTask` — model registry + `.interactive` default and the picker's option list.
- FOUNDATION §4 — caching strategy (applied lightly; see Claude usage).
- FOUNDATION §5 — the `.assistant` kind wiring (every switch). This feature *is* that wiring plus the panel.
- FOUNDATION §7 `StreamingTranscriptView` — the transcript renderer the panel embeds.
- Existing pattern to mirror for git shell-out: `Sprawl/Content/GitObserverPanel.swift` (`runGitLog`, `/usr/bin/git` `Process`).

No dependency on other Phase-2/3 features.

## UX & interaction
Where it lives: a normal `WindowView` panel on the shared `CanvasView`, created inside a project the same way every other panel is. Symbol: `sparkles` (LucideIcon).

1. User creates one via any existing path: FloatingDock folder menu ("New Assistant"), the project folder right-click context menu ("New Assistant"), or File menu (⌘7) — all per FOUNDATION §5. The panel spawns inside the current/clicked project via `AppModel.addItem(kind:.assistant, in:project, at:)`.
2. On creation the panel **resolves the project's repo** (see Data) and shows a one-line context header at the top: `repo-name · branch · N changes` (e.g. `Sprawl · main · 3 changes`). If no repo can be derived, the header shows a "Choose repo folder…" button that opens an `NSOpenPanel` (same affordance as `GitObserverPanel.chooseRepo`).
3. Body: a `StreamingTranscriptView` (§7) fills the panel; a single-line (auto-growing) `NSTextField`/`NSTextView` input sits at the bottom with a Send button (⌘↩ to send, ↩ newline-or-send configurable — decision: ↩ sends, ⇧↩ newline). A small model-picker `NSPopUpButton` and a cost label sit in the footer next to Send.
4. User types a question and sends. The panel builds the request (persona system block + freshly-gathered repo context block + full conversation history + the new user turn) and calls `ClaudeClient.shared.stream(_:)`. Tokens stream into the transcript live; thinking deltas render dimmed (Sonnet/Opus). A "Stop" affordance cancels the consuming `Task` (which tears down the URLSession task via the stream's `onTermination`).
5. On `messageStop`, the footer cost label updates from `usage × ClaudeModel.pricing`. The repo-context header refreshes (re-runs git) so subsequent turns see current branch/status.
6. Switching the model picker mid-conversation applies to the *next* turn only; history is preserved.
7. No key present → first send surfaces an inline `[No API key — open Settings…]` line **and** the panel calls the §2 settings presenter so the user can paste a key in context, then retry.

## Files & touchpoints
New files (all under `Sprawl/Claude/`, require `xcodegen generate` per FOUNDATION §5 step 8):
- `Sprawl/Claude/AssistantPanel.swift` — the panel. Shape mirrors `GitObserverPanel`: `let containerView = NSView()`, `init(repoPath: String?)`, `func attach(to window: WindowView) { window.setContent(containerView) }`, `var onTitleChange: ((String) -> Void)?`, `var onRepoChange: (() -> Void)?` (persist trigger), `private(set) var repoPath: String?`, `var selectedModel: ClaudeModel`. Hosts the §7 `StreamingTranscriptView` + input + model picker + cost label. Owns the in-memory `[Message]` history and the active streaming `Task`. Builds `ClaudeRequest` and consumes `ClaudeClient.shared.stream`.
- `Sprawl/Claude/GitContext.swift` — small read-only helper that shells out to `/usr/bin/git -C <path> …` exactly like `GitObserverPanel.runGitLog` (`Process`, `executableURL = /usr/bin/git`). Static funcs: `repoRoot(at:)` (`rev-parse --show-toplevel`), `branch(at:)` (`rev-parse --abbrev-ref HEAD`), `status(at:)` (`status -sb`/`--porcelain`), `recentLog(at:limit:)` (`log --oneline -n`). Returns a `struct ProjectGitContext { repoRoot, branch, statusLines, recentCommits }`. Forward-reusable by the Phase-2 `run_git` tool (§6) — keep it read-only.

Wiring touchpoints — follow FOUNDATION §5 verbatim (gitObserver is the line-for-line template); confirmed against current source:
- `Sprawl/Model/AppModel.swift` — `WorkItem.Kind` enum + `symbolName` (`"sparkles"`); stored ref `var assistant: AssistantPanel?`; `addItem` name-base switch (lines 267–274, add `case .assistant: base = "Assistant"`); **`installItem` build switch** — add `.assistant` case after line 457 mirroring `.gitObserver` (430–438): construct `AssistantPanel(repoPath:)`, `attach(to:)`, wire `onTitleChange`, wire `onRepoChange → self.onPersistableChange?()`, set `item.assistant = panel`; `snapshot` `kindState` (539–547) + extend the `workingDirectory:` expression at line 554 to include `item.assistant?.repoPath`; `restore` mapping (583–603) `contentURL = item.workingDirectory.map { URL(fileURLWithPath: $0) }`.
- **Repo derivation (the feature's novel logic)** — in `installItem`'s `.assistant` case, when `contentURL == nil` (fresh create, not restore), resolve the repo from the *owning* project's siblings via a new private helper `repoPathForNewAssistant(in project: Project) -> String?` that returns the first non-nil of: any sibling `gitObserver?.repoPath` / `gitGraph?.repoPath` / `projectVelocity?.repoPath`, else a sibling terminal's `currentDirectory`, each normalized through `GitContext.repoRoot(at:)`. Pass that into `AssistantPanel(repoPath:)`. (There is **no** project-level repo path today — see Risks.)
- `Sprawl/Persistence/WorkspaceState.swift:64` — add `assistant` to `ItemState.Kind`. (Optional model persistence: see Data.)
- `Sprawl/App/FloatingDock.swift` — `var onNewAssistant` + folder menu item (`LucideIcon.sparkles`), per §5.
- `Sprawl/App/MainSplitViewController.swift` — `installDock()` wiring + `@objc func newAssistant(_:)`, per §5.
- `Sprawl/App/AppDelegate.swift` — File-menu item (⌘7) → `#selector(MainSplitViewController.newAssistant(_:))`, per §5.
- `Sprawl/Canvas/CanvasView.swift` — context-menu item "New Assistant" + `@objc contextNewAssistant` → `createContextItem(.assistant)`, per §5.

Reuses (do not redefine): `ClaudeClient`, `ClaudeTypes`, `ClaudeModel`/`ClaudeTask`, `ClaudeAuth`/`ClaudeSettings`, `StreamingTranscriptView` from FOUNDATION.

## Data & persistence
- `ItemState.Kind` gains `assistant` (`WorkspaceState.swift:64`).
- **Repo path reuses the existing `ItemState.workingDirectory` plumbing** — snapshot writes `item.assistant?.repoPath` (extend `AppModel.swift:554`), restore feeds it back as `contentURL`/`AssistantPanel(repoPath:)`. No new field needed for the repo.
- **Model selection:** add one optional backward-compatible field `var assistantModel: String?` to `ItemState` (stores `ClaudeModel.id`), set in `snapshot`, read in `restore`. Absent → default `ClaudeTask.interactive.model` (Sonnet). (Optional but cheap; keeps the picker sticky across relaunch.)
- **Transcript is NOT persisted in MVP** — conversation history is in-memory per session and lost on relaunch. (Decision: persisting chat logs is Phase-2 scope; avoids bloating `workspace.json` and the privacy question. See Risks.) The API key is never persisted here (Keychain via §2).

## Claude usage
- **Model:** default `ClaudeTask.interactive` → **Sonnet 4.6** (balanced, low-latency interactive chat). Picker exposes all of `ClaudeModel.allCases` (Opus 4.8 for hard reasoning, Haiku 4.5 for fast/cheap). Thinking/effort from `ClaudeTask`: Opus/Sonnet use `Thinking(type:"adaptive", display:"summarized")` + effort `medium`; Haiku uses neither (would 400 on effort, per §3 `supportsEffort`).
- **Prompt sketch:**
  - System block 1 (frozen, `cacheControl: ephemeral`): Sprawl assistant persona — "You are Sprawl's coding assistant, embedded in a spatial-canvas macOS dev environment. You answer questions about the user's project and code. Be concise and concrete; prefer the project's actual files/branches over generic advice. You cannot edit files or run commands yet." No volatile data interpolated (keeps the cache prefix stable per §4).
  - System block 2 (refreshed every turn, **not** cached): the live repo context —
    ```
    Current project: <repo-name> (<repoRoot path>)
    Branch: <branch>
    git status -sb:
    <status lines>
    Recent commits (git log --oneline -n 20):
    <log lines>
    ```
  - Messages: full prior conversation (`role:user`/`assistant`) replayed each turn + the new user turn (verbatim question). Streamed with `stream:true`.
- **Tools:** none. `request.tools = nil`; the tool loop (§1e) and `CanvasTools` (§6) are untouched.
- **Caching:** breakpoint on system block 1 only. The repo-context block is small (typically < the Sonnet 2048-token min prefix) and volatile, so it is deliberately *not* a cache breakpoint — matches §4 guidance (don't put changing/short content behind a breakpoint). Verify `usage.cacheReadInputTokens > 0` on the persona prefix across turns.
- **Vision:** none in MVP.

## Effort
**M.** Rough breakdown:
- AssistantPanel UI (transcript embed, input + send/stop, model picker, cost + context header): ~1 day. Most rendering is reused from §7.
- `GitContext.swift` + repo derivation helper in `installItem`: ~0.5 day (mirror `runGitLog`).
- Request assembly (system blocks, history, model/effort/thinking from `ClaudeTask`) + stream consumption/cancellation + error→Settings funnel: ~0.5 day.
- §5 switch wiring across 6 files + `xcodegen generate` + build: ~0.5 day.
- Persistence (Kind + workingDirectory reuse + `assistantModel`) and restore round-trip: ~0.5 day.

## Risks / open questions
- **No project-level repo path exists.** `Project` is just name/anchor/color/items (`AppModel.swift:55`). MVP derives the repo from sibling panels; an assistant in a project with *no* git-aware sibling and no terminal has no context until the user picks a folder. Open question: should `Project` gain a first-class `folderURL` (a larger refactor touching `ProjectState`/restore) so all project-scoped features share one repo source? Recommend deferring, but flag it — this feature is the first to want it.
- **Repo context staleness / size.** Re-running git each turn keeps branch/status current but adds latency and, for large/dirty repos, can blow up the status/log block. Cap `log -n 20` and truncate `status` to N lines; note that big diffs are out of scope (no `git diff` in MVP).
- **Transcript not persisted** — relaunch loses the conversation. Acceptable for MVP? If not, it's a new `WorkspaceState` array (size/privacy tradeoff) — push to Phase 2.
- **Cancellation correctness** — ensure the Stop button cancels the consuming `Task` so the stream's `onTermination` cancels the URLSession task; don't re-issue billed requests on mid-stream drop (per §1d).
- **Concurrency** — `ClaudeClient` is an `actor`; the panel must hop to `@MainActor` for all `StreamingTranscriptView`/AppKit mutation while consuming the `AsyncThrowingStream`.
- **Cost label accuracy** — usage arrives on `messageDelta`; multiply by `ClaudeModel.pricing` for the *currently selected* model, accounting for cache reads.

## Acceptance criteria
- [ ] `WorkItem.Kind.assistant` exists and every switch compiles (AppModel enum/symbol/ref/addItem-name/installItem/snapshot/restore; `WorkspaceState.ItemState.Kind`).
- [ ] A "New Assistant" panel can be created from the FloatingDock, the canvas context menu, and File ▸ New Assistant (⌘7), and lands inside the intended project.
- [ ] On creation in a project that contains a git-aware sibling (gitObserver/gitGraph/projectVelocity) or a terminal with a cwd, the panel's header shows the correct repo name, branch, and change count; with none, it shows a working "Choose repo folder…" picker.
- [ ] Sending a message streams a Claude response token-by-token into the transcript; Opus/Sonnet thinking renders dimmed.
- [ ] The response demonstrably reflects project context (e.g. asking "what branch am I on?" or "summarize my recent commits" returns the real branch/log).
- [ ] The model picker lists Opus 4.8 / Sonnet 4.6 / Haiku 4.5, defaults to Sonnet, and changing it affects the next turn; Haiku requests send no effort/thinking and do not 400.
- [ ] Stop cancels an in-flight stream cleanly (no further tokens, no crash, no duplicate billed request).
- [ ] With no API key, the first send funnels the user to the §2 Settings sheet and an inline hint; after pasting a key, retry succeeds.
- [ ] Footer cost label updates from real `usage` after each turn.
- [ ] Repo path persists across relaunch via `ItemState.workingDirectory`; selected model persists via `assistantModel`; the restored panel re-derives live git context.
- [ ] `usage.cacheReadInputTokens > 0` on the persona system prefix across repeated turns in one session.
- [ ] `xcodegen generate` + Debug build succeed and the rebuilt `build/Sprawl.app` launches with the panel functional; with no assistant created, app behavior is unchanged from today.

Relevant paths: `/Users/ramijames/_CODE/Sprawl/Sprawl/Claude/AssistantPanel.swift` (new), `/Users/ramijames/_CODE/Sprawl/Sprawl/Claude/GitContext.swift` (new), `/Users/ramijames/_CODE/Sprawl/Sprawl/Model/AppModel.swift`, `/Users/ramijames/_CODE/Sprawl/Sprawl/Persistence/WorkspaceState.swift`, `/Users/ramijames/_CODE/Sprawl/Sprawl/Content/GitObserverPanel.swift` (template), `/Users/ramijames/_CODE/Sprawl/Sprawl/App/FloatingDock.swift`, `/Users/ramijames/_CODE/Sprawl/Sprawl/App/MainSplitViewController.swift`, `/Users/ramijames/_CODE/Sprawl/Sprawl/App/AppDelegate.swift`, `/Users/ramijames/_CODE/Sprawl/Sprawl/Canvas/CanvasView.swift`.


---

## Terminal Fix Card

_Phase 1 · Planned_

Confirmed all the load-bearing APIs. Here is the spec.

---

# Feature: Terminal Fix Card

## Summary
When a command run in a Sprawl terminal exits non-zero, a small card appears tethered by a connector line to that terminal panel, proposing a corrected command with a one-line rationale. The user clicks **Run** to execute the fix directly in that same PTY (or **Dismiss**), turning a failed command into a one-click recovery without leaving the canvas or copy-pasting. This is the first place Claude visibly touches the terminal, and it reuses the FOUNDATION client wholesale.

## Phase
**Phase 1.** It depends only on the FOUNDATION networking/auth layer (no agent tool-loop, no `assistant` panel kind). It does, however, require a one-time terminal-instrumentation change (shell integration + OSC handler) that is itself net-new plumbing — see Risks.

## Depends on
- **FOUNDATION §1** `ClaudeClient.shared.send(_:)` (non-streaming; we want one structured answer, not a stream), `ClaudeRequest`, `ToolDefinition`, `ToolChoice`, `JSONValue`, `ClaudeMessageResponse`.
- **FOUNDATION §2** `ClaudeAuth.apiKey` / `ClaudeError.noAPIKey` → route a key-less user to `MainSplitViewController.showClaudeSettings(_:)` instead of failing silently.
- **FOUNDATION §3** `ClaudeModel` / `ClaudeTask` for model selection.
- **Not** dependent on FOUNDATION §5 (`assistant` kind), §6 (`CanvasTools` agent layer), or §7 (`StreamingTranscriptView`). The card is bespoke, transient UI and runs the command by calling SwiftTerm directly, **not** through the agent tool seam.
- Note: a partial client already exists at `Sprawl/AI/ClaudeClient.swift` + `Sprawl/AI/APIKeyStore.swift`; this feature targets the FOUNDATION API surface (`Sprawl/Claude/`). If the two haven't been consolidated yet, that consolidation is a prerequisite, not part of this feature.

## UX & interaction
1. User runs a command in any terminal panel (a `TerminalLeaf` inside a `.terminal` `WorkItem`).
2. Command exits non-zero. Detected via shell integration (below). Exit code 0, 130 (Ctrl-C / SIGINT), and 148 (SIGTSTP) are **ignored** — those aren't "fixable errors," they're user intent.
3. A `TerminalFixCard` (a lightweight custom `NSView`, ~280×variable, NOT a `WindowView`) fades in on the canvas, positioned just to the right of (or below, if no room) the terminal's `WindowView` frame. A connector line is drawn from the terminal panel's nearest edge to the card. While Claude is thinking the card shows a "Looking at that error…" shimmer with a cancel (×).
4. Claude returns a corrected command + one-line reason. The card renders: the proposed command in a monospaced pill, the reason in body text, and two buttons: **Run** (primary) and **Dismiss**.
5. **Run** → the exact corrected string is sent into that PTY (`terminalView.send(txt: corrected + "\n")`), the card dismisses, and the user watches it execute in place. **Dismiss** (or Esc, or clicking the terminal, or running any new command) removes the card.
6. The card tracks its terminal: it repositions and the connector redraws whenever the terminal panel is moved/resized/zoomed, because `CanvasView` already calls `needsDisplay` on every `WindowView.onGeometryChange`. Closing the terminal removes its card. Only one card per terminal at a time (a new failure replaces the old card).

## Files & touchpoints
**Exit-code + command + output capture (the feasibility core):**
- `Sprawl/Content/TerminalPanel.swift` — three additions:
  - In `startShell(in:)` (lines 37–61): inject **shell integration**. Write a Sprawl integration script (embedded as a Swift string constant; written once to `~/Library/Application Support/Sprawl/shell-integration/`) and point the shell at it without clobbering the user's rc: for zsh set `ZDOTDIR` to a temp dir whose `.zshrc` sources the user's real `~/.zshrc` then our script; for bash launch with `--rcfile`. Gate on the detected `shellName`; if the shell is unsupported, skip instrumentation (feature simply never fires).
  - After `startProcess`, register OSC handlers on the live terminal: `terminalView.getTerminal().registerOscHandler(code: 133) { … }` and `registerOscHandler(code: 633) { … }` (both confirmed: `Terminal.registerOscHandler(code:handler:)`). The integration emits the iTerm2/VS Code **semantic-prompt** sequences: `OSC 633;E;<cmdline> ST` at `preexec` (the command text), `OSC 133;C ST` at command-output start, `OSC 133;D;<exit> ST` at command finish. The handler accumulates `(command, startRow)` and on `D` reads the exit code.
  - **Output capture:** on `133;C` record `getCursorLocation().y` + `buffer.yBase` as a scroll-invariant start row; on `133;D` read rows `[startRow, endRow)` via `getScrollInvariantLine(row:)` → `BufferLine.translateToString(trimRight: true)` (both confirmed), join, and cap to the last ~50 lines / ~4 KB.
  - Expose `var onCommandFinished: ((_ command: String, _ exitCode: Int32, _ output: String) -> Void)?` and `func runCommand(_ s: String) { terminalView.send(txt: s + "\n") }`.
- `Sprawl/Content/TabbedContainer.swift` — `TerminalLeaf` (lines 149–173): forward `panel.onCommandFinished` up through a new `var onCommandFinished`, and surface `func runCommand(_:)` passthrough so the owner doesn't reach into `panel`.

**Card + Claude call + canvas tethering:**
- **NEW** `Sprawl/Content/TerminalFixCard.swift` — contains:
  - `TerminalFixCard: NSView` (Palette-themed card chrome: rounded body, command pill, reason label, Run/Dismiss buttons, shimmer/error states).
  - `@MainActor final class TerminalFixCoordinator` — owns the one-card-per-terminal map, builds the `ClaudeRequest`, calls `ClaudeClient.shared.send(_:)`, places/removes the card on the canvas, and on Run calls back into the leaf's `runCommand`. Catches `ClaudeError.noAPIKey` → presents FOUNDATION §2 settings.
- `Sprawl/Canvas/CanvasView.swift` — add `func addFixCard(_ card: TerminalFixCard, tetheredTo window: WindowView)` / `func removeFixCard(_:)` that add the card as a canvas subview and register a `[(weak WindowView, weak TerminalFixCard)]` list; draw the connector line for each live pair inside `draw(_:)` (line 75) alongside the existing folder drawing. No new geometry-observer plumbing needed — the panel's `onGeometryChange` already triggers `CanvasView.needsDisplay`.
- `Sprawl/Model/AppModel.swift` — in `installItem`'s `.terminal` case (lines 380–391): wire `container`/leaf `onCommandFinished` → `fixCoordinator.present(forItem: item, command:, exitCode:, output:)`. Hold one `TerminalFixCoordinator` (constructed with `canvas`). In the `window.onClose` closure (lines 369–377) and `removeItem` (line 200), call `fixCoordinator.dismiss(forItem:)`.

**Build:** new files under `Sprawl/` are picked up by the folder source (`project.yml` `sources: - Sprawl`), so run `xcodegen generate` then the standard `xcodebuild` (quit the running app first). The shell script ships as an embedded Swift string written to disk at runtime — this sidesteps XcodeGen resource-bundling ambiguity for `.zsh`/`.bash` files entirely.

## Data & persistence
**No `WorkspaceState` changes.** The fix card is ephemeral, in-the-moment UI; a proposed fix has no meaning after the session moves on, and nothing about it should survive a relaunch. The shell-integration script path lives under Application Support but is regenerated on demand, not part of `workspace.json`. (`ItemState.workingDirectory` for terminals is unaffected.)

## Claude usage
- **Model:** Sonnet (`claude-sonnet-4-6`, via `ClaudeTask.interactive.model`). Command correction is short-context reasoning where Sonnet is reliably better than Haiku at shell semantics, while still snappy. Override the task's thinking to **`nil`** and `outputConfig.effort = "low"` for latency — this is a single quick suggestion, not deep reasoning. (If field latency disappoints, Haiku is the documented fallback for obvious typo-class fixes.)
- **Shape — forced structured output via a Claude tool** (a `ToolDefinition`, distinct from FOUNDATION §6's agent layer). Define one tool `propose_fix` with `inputSchema`: `{ corrected_command: string, explanation: string (≤140 chars), confidence: "high"|"low" }`, and set `toolChoice = ToolChoice(type: "tool", name: "propose_fix")`. We read the single `toolUse` block's `JSONValue` input rather than parsing prose — no markdown/code-fence stripping, no streaming UI needed. `maxTokens` ~512.
- **System prompt (frozen):** "You fix failed shell commands. You are given the user's shell, OS (macOS), working directory, the exact failed command, its exit code, and its terminal output. Propose the single most likely corrected command to run next. Prefer minimal edits. Never propose destructive commands (rm -rf, dd, mkfs, git push --force, :(){...}) — if the only fix is destructive or you're unsure, return confidence:"low" and a safe diagnostic instead. Output only via the propose_fix tool."
- **User message:** `shell=zsh, cwd=<currentDirectory>, exit=<code>` + the failed command + the captured output (last ~50 lines).
- **Caching:** none in Phase 1. The stable prefix (system + tool def) is well under Sonnet's 2048-token minimum cacheable size, so a breakpoint wouldn't cache; the volatile per-error payload dominates anyway. (Revisit if a persona/repo-context prefix grows past the threshold.)
- **Vision:** none — terminal output is captured as text.
- **Safety gate:** the destructive-command guard is enforced both in the prompt and with a client-side denylist regex on `corrected_command` before the card offers **Run**; a flagged or `confidence:"low"` result renders as a read-only suggestion (copyable, no one-click Run).

## Effort
**M** (~3–4 focused days).
- Shell integration + OSC handler + output capture in `TerminalPanel` — **~1.5 days** (the genuinely fiddly part: rc injection without clobbering user config, getting `133;D`/`633;E` parsing and scroll-invariant row math right across zsh/bash).
- `TerminalFixCard` view + coordinator + Claude `propose_fix` call/parse — **~1 day**.
- Canvas tethering (connector draw + add/remove + reposition on geometry change) — **~0.5 day**.
- Wiring through `TerminalLeaf`/`TabbedContainer`/`AppModel`, denylist gate, key-less routing, polish — **~0.5–1 day**.

## Risks / open questions
- **Shell-integration injection is the main risk.** `LocalProcessTerminalView.startProcess` (called in `startShell`) inherits cwd and takes `environment`/`execName` but **not** custom argv beyond `execName`; bash `--rcfile` needs args. Confirm we can pass `args:` (the SwiftTerm API accepts `args:`, currently called with `[]`). For zsh the robust path is `ZDOTDIR` → temp dir with a `.zshrc` that `source`s the user's real rc then ours. Decisive default: support **zsh and bash**; other shells (fish, nushell) silently get no fix card.
- **Non-clobbering:** must source the user's existing rc first so prompts/aliases/`precmd` chains survive. Standard VS Code/iTerm2 approach; the edge cases (users who already define `precmd`/`preexec` or set `ZDOTDIR` themselves) need a guard.
- **Output capture fidelity:** scroll-invariant rows (`getScrollInvariantLine` + `yBase`) survive scrollback, but TUI programs / alternate-screen apps (vim, less) and programs with mouse mode produce noisy buffers; capping to the post-`133;C` region and last ~50 lines mitigates. Multi-line / heredoc / pipeline commands: rely on `633;E` carrying the full command line rather than buffer-scraping it.
- **Connector geometry in flipped coords:** `CanvasView` is flipped; the card subview and connector math must use canvas (superview) space like `WindowView` drag math does.
- **Latency vs. annoyance:** firing on every non-zero exit could be noisy in a loop of failing commands. Decision: one card per terminal, replaced on each new failure, auto-dismissed when a new command starts; consider a small debounce. Open: should there be a per-terminal "stop offering fixes" toggle? (Defer to Phase 2.)
- **Privacy/cost:** every failed command ships its output to the API. Acceptable given the user pasted a key, but the destructive-denylist and a future "don't send" affordance matter; out of scope for Phase 1 beyond honoring `ClaudeError.noAPIKey`.

## Acceptance criteria
- [ ] In a freshly spawned terminal, running a failing command (e.g. `git stauts`) makes a fix card appear tethered to that terminal within ~2s; running `git status` (exit 0) shows no card.
- [ ] Exit codes are detected per-command via OSC `133;D` (not via SwiftTerm's whole-process `processTerminated`), verified for both zsh and bash.
- [ ] The user's existing prompt, aliases, and any pre-existing `precmd`/`PROMPT_COMMAND` still work after instrumentation (no clobber).
- [ ] Exit codes 0, 130, 148 produce no card.
- [ ] Clicking **Run** executes the corrected command in the **same** PTY (same cwd/env/session), and the card dismisses.
- [ ] The card and its connector reposition correctly when the terminal panel is dragged, resized, and when the canvas is zoomed/panned.
- [ ] Closing the terminal, clicking it, pressing Esc, or starting a new command dismisses the card; only one card exists per terminal.
- [ ] Claude is called via FOUNDATION `ClaudeClient.shared.send` with `toolChoice` forcing `propose_fix`; the corrected command is read from the tool input, never from free-text parsing.
- [ ] A destructive proposed command (rm -rf, git push --force, etc.) or `confidence:"low"` renders as a non-runnable suggestion (no one-click Run).
- [ ] With no API key set, the first failure routes the user to the §2 settings sheet rather than failing silently or crashing.
- [ ] No `workspace.json` schema change; relaunching after a fix card was shown restores the workspace identically with no card.
- [ ] `xcodegen generate` + Debug build succeed and mirror to `./build/Sprawl.app`.

Key source anchors: `Sprawl/Content/TerminalPanel.swift` (startShell 37–61, `getTerminal()` use 143, `send(txt:)` use 159), `Sprawl/Content/TabbedContainer.swift` (`TerminalLeaf` 149–173), `Sprawl/Model/AppModel.swift` (`installItem` `.terminal` 380–391, `window.onClose` 369–377, `removeItem` 200), `Sprawl/Canvas/CanvasView.swift` (`draw` 75, `addWindow` 565). SwiftTerm APIs confirmed in checkout: `registerOscHandler` (Terminal.swift:958), `getScrollInvariantLine` (717/729), `BufferLine.translateToString` (293), `getCursorLocation` (4898).


---

## Commit Messages / Release Notes / Git Narration

_Phase 1 · Planned_

# Feature: Commit Messages / Release Notes / Git Narration

## Summary
Adds three Claude-powered git affordances that ride on Sprawl's existing git panels: (1) generate a Conventional-Commits message from the staged diff, (2) generate release notes / CHANGELOG markdown for a commit range and drop them into a Document panel, and (3) plain-English explanations of a commit, merge, or branch anchored to a node in Git Graph / a row in Git Observer. User value: turns the read-only git panels into a writing assistant for the tedious-but-required parts of shipping, without leaving the canvas or touching the command line.

## Phase
**Phase 1.** Pure generation (prompt → text). No agent tool loop, no canvas mutation tools, no vision — it reuses git plumbing and the FOUNDATION client only. Cheap and batchable, so it's the natural first Claude feature to ship.

## Depends on
- FOUNDATION §1 `ClaudeClient` (`stream`/`send`) + `ClaudeTypes` — networking, SSE, retry.
- FOUNDATION §2 `ClaudeAuth` / `ClaudeSettings` — key resolution; catch `ClaudeError.noAPIKey` → present settings.
- FOUNDATION §3 `ClaudeModel` / `ClaudeTask` — model selection + `usage`-based cost.
- FOUNDATION §7 `StreamingTranscriptView` — for the streamed branch/merge explanation popover.
- Existing git plumbing: `GitObserverPanel.runGitLog` (`Sprawl/Content/GitObserverPanel.swift:254`) and `GitGraphPanel.runGitLog` (`Sprawl/Content/GitGraphPanel.swift:183`) — the `/usr/bin/git` Process shell-out pattern is copied for the new git reads.
- Document panel creation path (`AppModel.addItem(kind:.document…)`, `DocumentLeaf(fileURL:initialText:name:)` at `Sprawl/Content/TabbedContainer.swift:176`).
- Does **not** depend on FOUNDATION §5 (`assistant` kind) or §6 (CanvasTools) — those are Phase 2/3.

## UX & interaction

**A. Commit message (Git Observer & Git Graph toolbar).**
1. User has a repo selected in the panel (existing `repoPath`). A new toolbar button "Commit message" (LucideIcon `git-commit`) is enabled only when `git diff --staged` is non-empty.
2. Click → button shows a spinner; `GitNarrator` shells `git -C <repo> diff --staged` and calls Claude.
3. Result appears in an `NSPopover` anchored to the button: an **editable** `NSTextView` prefilled with the generated message, plus three buttons — **Copy** (primary, copies to `NSPasteboard`), **Regenerate**, and **Commit…** (secondary, gated). "Commit…" asks for confirmation, then runs `git -C <repo> commit -F -` with the edited text on the user's explicit click (the confirmation gate required by FOUNDATION §6 safety). Default/Esc = just Copy.

**B. Release notes → Document panel.**
1. In Git Graph, right-click a commit node → "Release notes from here…", or a panel toolbar "Release notes" button (defaults to "since last tag").
2. `GitNarrator` resolves the range (most recent tag → `HEAD`, falling back to last 20 commits) and pulls `git log <range> --pretty` + `--stat`. Claude returns dated markdown.
3. The panel calls a new `onOpenDocument` callback → `AppModel.openGeneratedDocument(title:text:fileURL:)` which opens a **Document panel** seeded with the notes. If `<repo>/RELEASES.md` exists it opens that file with the generated entry prepended; otherwise it creates an untitled document the user can save. The document is a normal panel from then on (edit/save/persist via the existing Document path).

**C. Branch / merge explanation (anchored).**
1. Right-click a node in Git Graph (or a row in the Git Observer timeline) → "Explain commit", and for merge nodes additionally "Explain merge" / "Explain branch".
2. An `NSPopover` opens **anchored to that node/row** hosting a `StreamingTranscriptView` (FOUNDATION §7). `GitNarrator` pulls `git show <hash>` (commit), `git show --first-parent <merge>` + `git log <p1>..<p2>` (merge), or `git log <base>..<branch>` (branch) and streams the explanation in. A model picker + live cost (from `usage`) sit in the popover footer.

## Files & touchpoints
- **New `Sprawl/Claude/GitNarrator.swift`** — the shared brain. Static git reads mirroring the existing `runGitLog` Process pattern: `stagedDiff(at:)`, `show(hash:at:)`, `mergeContext(hash:at:)`, `commitRange(from:to:at:)`, `latestTag(at:)`. Three async builders that assemble a `ClaudeRequest` and call `ClaudeClient.shared` (stream for C, `send` for A/B): `commitMessage(diff:)`, `releaseNotes(log:)`, `explain(kind:context:)`. Owns prompts, model choice, and diff truncation. Reuses `ClaudeClient`/`ClaudeModel`/`ClaudeError` — does not redefine them.
- **New `Sprawl/Claude/CommitMessagePopover.swift`** — `NSViewController` (editable `NSTextView` + Copy/Regenerate/Commit). Runs the gated `git commit -F -`.
- **New `Sprawl/Claude/GitExplainPopover.swift`** — `NSViewController` hosting `StreamingTranscriptView`; drives `view.consume(stream)`.
- **`Sprawl/Content/GitObserverPanel.swift`** — add "Commit message" + "Release notes" toolbar buttons (enable/disable on staged-diff presence); add a timeline-row context menu "Explain commit"; add `var onOpenDocument: ((_ title: String, _ text: String, _ fileURL: URL?) -> Void)?`.
- **`Sprawl/Content/GitGraphPanel.swift`** — add per-node context menu ("Explain commit/merge/branch", "Release notes from here"); needs node hit-testing → commit hash (extend `GitGraphContentView`); add the same `onOpenDocument` callback.
- **`Sprawl/Model/AppModel.swift`** — add `func openGeneratedDocument(title:text:fileURL:)` that creates a Document `WorkItem` seeded via `DocumentLeaf(fileURL:initialText:name:)` (the seam already used by `restore` at `AppModel.swift:399`), then fires `onPersistableChange`. In `installItem` (the gitObserver/gitGraph build cases) wire `panel.onOpenDocument = { [weak self] t,x,u in self?.openGeneratedDocument(title:t,text:x,fileURL:u) }` — same place `onRepoChange`/`onTitleChange` are already wired.
- **`xcodegen generate`** then build — the three `Sprawl/Claude/*.swift` files are new (FOUNDATION §5 step 8); quit the running app before building.
- No changes to dock / menus / `WorkItem.Kind` — this rides existing panels, so the multi-switch kind ritual does not apply.

## Data & persistence
**No `WorkspaceState` changes.** Commit-message and explanation popovers are ephemeral. Release notes land in a Document panel that persists through the existing `ItemState.documentText` / `filePath` path — no new fields. The default model preference is stored in `UserDefaults` (not `workspace.json`, per FOUNDATION's "no secrets/volatile in workspace.json" stance). The API key lives in Keychain via `ClaudeAuth`.

## Claude usage
- **Commit message & release notes → Haiku** (`ClaudeTask.bulk`): short, structured, latency-sensitive, batchable; `thinking: nil`, no `effort` (Haiku 400s on effort). Pricing from `ClaudeModel.haiku` (1/5 per Mtok).
- **Branch/merge explanation → Sonnet** (`ClaudeTask.interactive`): reasoning over a real diff/merge benefits from light adaptive thinking (`Thinking(type:"adaptive", display:"summarized")`, `effort:"medium"`). A model picker lets the user bump to Opus for a gnarly merge.
- **Prompt sketch (commit message):**
  - *system (cacheable breakpoint 1):* "You write terse Conventional-Commits messages. Output ONLY the message: a `type(scope): subject` line ≤72 chars, blank line, then bullet body. No prose, no code fences."
  - *user:* the staged diff (truncated, see Risks).
- **Prompt sketch (explain):** *system:* "Explain this git change to a teammate in plain English: what changed, why it likely changed, and risk areas. Be concrete, reference files." *user:* `git show`/range output, placed last (volatile).
- **Caching (FOUNDATION §4):** system prompts are short and the diff is volatile, so caching is marginal for A/B (system prefix is below Haiku's 4096-token min — won't cache; that's fine). For C, put the stable `git show <hash>` output behind cache breakpoint 2 so re-asking about the **same** commit gets cache reads at ~0.1×; verify `usage.cacheReadInputTokens > 0` and keep serialization order deterministic. **No tools, no vision.**

## Effort
**M.** Rough breakdown: `GitNarrator` (git reads + 3 prompt builders + truncation) ~1 day; commit-message popover incl. gated commit ~0.5 day; explain popover wiring `StreamingTranscriptView` ~0.5 day; Git Graph node hit-testing for anchored menus ~0.5 day; `openGeneratedDocument` + RELEASES.md prepend + `installItem` wiring ~0.5 day; polish/error/empty states + `xcodegen`/build ~0.5 day.

## Risks / open questions
- **Diff size / cost / context:** large staged diffs blow context and cost. Mitigation: send `--stat` + per-file hunks truncated to a byte budget (e.g. 60 KB); if over budget, fall back to `--stat` only and note it in the popover. Skip binary files.
- **Commit safety:** the "Commit…" button runs `git commit` — must stay behind an explicit click + confirmation, never auto-fire, and never `push` (matches FOUNDATION §6). Open Q: also offer `--amend`? Default no.
- **Empty/edge states:** no staged changes (disable button), detached HEAD, no repo selected, no tags (range fallback), shallow clones.
- **Release-notes target file:** default `RELEASES.md` (matches this project's convention) but make the filename a small setting; prepend vs append (default prepend dated entry).
- **Hash hit-testing in Git Graph** is the only non-trivial UI bit; if it slips, ship A/B first and gate C behind it.
- **Quality of Conventional-Commits scope** depends on diff context; acceptable for a draft the user edits before committing.

## Acceptance criteria
- [ ] With a repo selected and staged changes, "Commit message" produces an editable Conventional-Commits draft in a popover; **Copy** puts it on the clipboard.
- [ ] "Commit…" runs `git commit -F -` only after an explicit confirmation; nothing commits or pushes automatically.
- [ ] "Commit message" is disabled (with a tooltip) when there are no staged changes.
- [ ] "Release notes" generates dated markdown for the resolved range and opens it in a Document panel; if `RELEASES.md` exists the entry is prepended to that file, else a new untitled doc is created.
- [ ] The generated Document persists across relaunch via the existing document persistence (no `WorkspaceState` schema change).
- [ ] Right-clicking a commit/merge node (Git Graph) or row (Git Observer) opens an anchored popover that **streams** a plain-English explanation via `StreamingTranscriptView`; merge nodes additionally offer "Explain merge/branch".
- [ ] All three flows route `ClaudeError.noAPIKey` to the FOUNDATION §2 settings presenter instead of failing silently.
- [ ] Diffs over the byte budget are truncated/degraded gracefully with a visible note; binary files excluded.
- [ ] Cost (from `usage` × `ClaudeModel.pricing`) is shown after each generation; the explain popover has a working model picker.
- [ ] Re-asking "Explain commit" on the same hash shows `cacheReadInputTokens > 0`.
- [ ] `xcodegen generate` + Debug build succeed and mirror to `./build/Sprawl.app`; no changes to dock/menus/`WorkItem.Kind`.


---

## Context Wires

_Phase 2 · Planned_

Here is the build-ready spec section.

---

# Context Wires

## Summary
Context Wires let you drag a bezier connector from any panel's edge into a Claude (`assistant`) panel, attaching that panel's serializable state — terminal scrollback, editor buffer, browser page text, git data — as **live, revocable** context that is re-read on every request. It turns "what the model can see" into a physical, auditable graph drawn directly on the canvas, instead of an invisible prompt the user has to trust. Each wire can be toggled off or cut without retyping anything.

## Phase
**Phase 2.** Sits on top of the FOUNDATION layer and the Assistant-panel feature; it is the first feature to exercise the `read_panel` tool-layer seam (FOUNDATION §6) as a real context source.

## Depends on
- FOUNDATION §1 `ClaudeClient`/`ClaudeTypes` — `Message`, `ContentBlock.text`, `SystemBlock`, `CacheControl` (the wire payloads become cached user content blocks).
- FOUNDATION §5 — the `assistant` `WorkItem.Kind` and `AssistantPanel.swift` must already exist; wires terminate on an assistant panel and feed its request builder.
- FOUNDATION §6 `CanvasTools.read_panel` — the per-kind state extraction defined here is the same extraction `read_panel` performs; both call one shared `PanelContext` extractor (no duplicate logic).
- FOUNDATION §4 caching — wire payloads are emitted as early, deterministically-ordered user blocks with `cache_control` breakpoints.
- No new third-party deps.

## UX & interaction
Lives entirely on the `CanvasView` surface; the connector is a first-class canvas object like a folder card, not panel chrome.

1. **Affordance.** Hovering any non-assistant `WindowView` reveals a small circular **context port** on its right-edge midpoint (drawn by `WindowView`, gated by a hover flag, same pattern as `drawResizeIndicator()`).
2. **Start the drag.** The user either (a) drags from the port, or (b) Option-drags from anywhere on the panel body/header. Both begin a wire; the port hit-test and the Option modifier are checked in `WindowView.mouseDown` **before** the resize/move branch so they don't trigger a resize. A faint "from here" glow appears on the source.
3. **Rubber-band.** While dragging, a live bezier follows the cursor from the source port to the pointer. `WindowView` forwards the drag points to `CanvasView.updateWireDrag(_:)`; the curve is drawn by a topmost `WireOverlayView` so it renders above all panels. Assistant panels under the cursor highlight a left-edge **inbound port** as a valid drop target; non-assistant panels and empty canvas show a "no-drop" cursor.
4. **Drop.** On `mouseUp`, `CanvasView` hit-tests the `WindowView` under the cursor and resolves it via `model.item(for:)`. If its kind is `.assistant`, a `ContextWire(source → assistant)` is created (enabled). Otherwise the wire snaps away (cancelled). Duplicate source→same-assistant wires are coalesced.
5. **Persistent graph.** Each committed wire draws as a colored bezier (color = source kind's accent) from source right-port to assistant left-port, with a midpoint **pill badge** showing the source's Lucide icon. Wires re-route automatically when either panel moves (they recompute from `window.frame` on each `draw`, which already fires via `onGeometryChange`).
6. **Revoke / toggle.** Clicking a wire's midpoint badge toggles `enabled` (dimmed + dashed when off — context is retained but excluded from the next request). Right-click badge → "Cut Wire" removes it. The assistant panel also renders a **Context** strip of chips (one per inbound wire) with the same enable-toggle and an ✕; cutting from either surface stays in sync.
7. **At request time.** When the user sends a message in the assistant panel, every enabled inbound wire's current source state is gathered fresh and prepended to the request as cached context blocks. A subtle per-wire "pulse" animates during gathering so the user sees which panels were actually read.

## Files & touchpoints
- **New `Sprawl/Claude/ContextWires.swift`** — `ContextWire` (`id`, `sourceItemID`, `targetItemID`, `enabled`), the `PanelContext` extractor, and `ContextProvider` (maps an assistant's enabled wires → `[ContentBlock]`). `PanelContext.snapshot(for: WorkItem) -> ContextSnapshot { title, text, tokenEstimate }` switches on `item.kind`:
  - `.terminal` → new `TerminalPanel.snapshotText(maxLines:)` reading `terminalView.getTerminal()` buffer rows + `currentDirectory` (TerminalPanel.swift:7,16).
  - `.document` → `item.activeDocumentLeaf?.panel.model.text` + `model.fileURL?.path` (DocumentPanel.swift:9,12 — already accessible).
  - `.browser` → new async `BrowserPanel.pageText()` via `webView?.evaluateJavaScript("document.title+'\\n'+document.body.innerText")` + `currentURL` (BrowserPanel.swift:175,183).
  - `.gitObserver` / `.gitGraph` / `.projectVelocity` → `repoPath` + reuse the existing `/usr/bin/git` shell-out (GitObserverPanel.swift:28; `status --short` + recent `log`). Route through `CanvasTools.run_git` so it stays read-only.
- **`Sprawl/Model/AppModel.swift`** — add `private(set) var contextWires: [ContextWire] = []`; methods `addWire`, `removeWire`, `setWireEnabled`, and `wires(into assistantID:)`; each fires `onModelChange?()` + `onPersistableChange?()`. Cascade-remove wires in `removeItem`/`installItem`'s `onClose` and `removeProject` when an endpoint dies. Add a stable-id thread (see Data & persistence).
- **`Sprawl/Canvas/CanvasView.swift`** — own the wire-drag state machine (`beginWireDrag(from:at:)`, `updateWireDrag`, `endWireDrag(at:)`); add `wireOverlay` raised to top in `addWindow`/`bringToFront` (so it stays above panels); draw committed wires + badges; hit-test badges in `mouseDown`; add a "Cut Wire" context-menu branch. Wire endpoints read `model.item(for: window)?.window?.frame`.
- **`Sprawl/Windows/WindowView.swift`** — add a hover-revealed context-port glyph (draw + a `showsContextPort` flag set in `mouseMoved`); in `mouseDown`, detect port-hit or Option-drag and call into the canvas to start a wire instead of resize/move; expose a small `onBeginWire` hook or talk to `superview as? CanvasView`.
- **`Sprawl/Claude/AssistantPanel.swift`** (from FOUNDATION §5) — render the Context chip strip; in its send path call `ContextProvider.blocks(for: assistantItem, in: model)` and prepend them to `ClaudeRequest.messages` before the user turn.
- **`Sprawl/Claude/CanvasTools.swift`** — `read_panel` delegates to `PanelContext.snapshot` (single code path).
- Reuse, do **not** redefine, `ClaudeClient`/`ClaudeTypes`/`ClaudeModel`/`StreamingTranscriptView`.
- New files require `xcodegen generate` then the Debug build (FOUNDATION §5 step 8); quit the running app first.

## Data & persistence
WorkspaceState changes (`Sprawl/Persistence/WorkspaceState.swift`):
- **Stable item identity (prerequisite).** Wires reference `WorkItem.id`, but `ItemState` has no id today and `installItem` mints a fresh UUID on restore, so wires would not reconnect. Add `var id: UUID?` to `ItemState`; thread an optional `id` through `installItem`/`WorkItem.init` (reuse on restore, mint when new); write `item.id` in `snapshot()` (AppModel.swift:548).
- **Wire records.** Add top-level `var wires: [WireState]?` to `WorkspaceState` (canvas-global, since a source and an assistant may live in different projects). `struct WireState: Codable { var source: UUID; var target: UUID; var enabled: Bool }`.
- `snapshot()` bumps `state.version = 5` and serializes `contextWires`; `restore()` rebuilds wires **after** all items exist, dropping any whose endpoints didn't restore (graceful). Older saves have `wires == nil` → no migration needed; the live source content is never persisted (re-read each turn by design — "live").

## Claude usage
- **Model.** Context Wires does **not** pick a model — it feeds context into whatever the assistant panel runs (`ClaudeTask.interactive` → Sonnet 4.6, FOUNDATION §3). Rationale: wiring is a context-assembly concern, orthogonal to model choice.
- **Prompt shape.** Frozen persona/tools stay in the cached system prefix (FOUNDATION §4 breakpoint 1). Each enabled wire becomes one early **user** `ContentBlock.text`, wrapped and labeled so the model can attribute sources, e.g.:
  ```
  <context source="terminal" panel="Terminal 2" cwd="~/_CODE/Sprawl">
  …last 200 lines of scrollback…
  </context>
  ```
  Blocks are emitted in a **deterministic order** (sort by source UUID) so the cached prefix is byte-stable; a `cache_control: {type:"ephemeral"}` breakpoint sits on the last context block (FOUNDATION §4 breakpoint 2). The user's typed message is the volatile final block, after the breakpoint.
- **Tools.** Read-only via `CanvasTools.read_panel`/`run_git` (FOUNDATION §6); no mutating tools triggered by wiring.
- **Caching.** Re-asking with the same wired panels (unchanged content) should report `usage.cacheReadInputTokens > 0`; large editor/scrollback payloads get ~0.1× reads. Truncate each source to a token budget (e.g. terminal/last-200-lines, document/full-but-capped) and note truncation in the wrapper.
- **Vision.** Text-first in v1. A browser screenshot via `WKWebView.takeSnapshot` → image block is a natural extension (open question below).

## Effort
**L.** Breakdown: wire model + add/remove/toggle/cascade in AppModel (S); cross-panel drag interaction — port affordance, rubber-band, overlay-on-top, drop hit-test (M, the trickiest part); committed-wire drawing + badges + re-routing (S–M); `PanelContext` extractor incl. new `TerminalPanel.snapshotText` and async `BrowserPanel.pageText` (M); stable item-id threading + `wires` persistence + restore ordering (M); AssistantPanel context strip + request injection + caching (S–M).

## Risks / open questions
- **Resize-band collision.** The context port sits on the right edge, which is also the resize zone. Mitigation: port/Option checks precede the resize branch and the port is small; needs hover testing to confirm it doesn't make right-edge resize feel stolen.
- **Overlay z-order.** `addWindow`/`bringToFront` reorder subviews; the `WireOverlayView` must be re-raised after each, and must `hitTest → nil` except over badges so panels stay interactive. Alternative (draw wires in `CanvasView.draw()` behind panels) is simpler but occludes endpoints under panels — chosen against for auditability.
- **Async gathering vs. send.** `BrowserPanel.pageText()` and `run_git` are async; the assistant send must `await` all snapshots before building the request (show the per-wire pulse meanwhile). Define a timeout/fallback if a source hangs.
- **Token blowup.** A wired large repo or long scrollback can dominate the window; per-source truncation budgets and a visible token estimate on each chip are required.
- **Stale "live" semantics.** "Live" = re-read at send time, not continuously. Confirm that's the intended contract (vs. snapshot-at-wire-time); spec assumes re-read each turn.
- **Cross-project wires.** Allowed (global `wires`); confirm the UX is desirable or restrict to same-project.
- **Vision/screenshot** for browser/canvas sources — defer to Phase 3?

## Acceptance criteria
- [ ] Hovering a non-assistant panel reveals a context port; dragging it (or Option-dragging the panel) starts a rubber-band bezier that follows the cursor.
- [ ] Dropping on an `assistant` panel creates an enabled wire; dropping elsewhere cancels with no state change.
- [ ] A committed wire draws as a colored bezier from source to assistant, re-routes when either panel moves/resizes, and disappears when either endpoint is closed or its project is deleted.
- [ ] Clicking the wire's midpoint badge toggles enabled (dimmed/dashed when off); right-click → "Cut Wire" removes it; the assistant's Context chip strip mirrors both.
- [ ] Sending a message in the assistant panel injects one labeled, deterministically-ordered context block per enabled wire, reflecting each source's **current** state (edit a document, resend → updated content appears).
- [ ] A disabled wire contributes nothing to the request.
- [ ] Repeating the same request with unchanged sources yields `usage.cacheReadInputTokens > 0`.
- [ ] Each kind extracts correctly: terminal scrollback+cwd, document buffer+path, browser page text+URL, git status+log.
- [ ] Wires survive quit/relaunch (item ids stable; orphaned wires dropped silently); `version` bumped to 5; older saves load with zero wires and no errors.
- [ ] No API key + a wire present = the existing FOUNDATION §2 no-key path (routed to Settings), not a crash.
- [ ] `xcodegen generate` + Debug build succeeds and mirrors to `./build/Sprawl.app`.

**Key files:** `/Users/ramijames/_CODE/Sprawl/Sprawl/Claude/ContextWires.swift` (new), `/Users/ramijames/_CODE/Sprawl/Sprawl/Claude/AssistantPanel.swift` (FOUNDATION), `/Users/ramijames/_CODE/Sprawl/Sprawl/Canvas/CanvasView.swift`, `/Users/ramijames/_CODE/Sprawl/Sprawl/Windows/WindowView.swift`, `/Users/ramijames/_CODE/Sprawl/Sprawl/Model/AppModel.swift`, `/Users/ramijames/_CODE/Sprawl/Sprawl/Persistence/WorkspaceState.swift`, `/Users/ramijames/_CODE/Sprawl/Sprawl/Claude/CanvasTools.swift`, plus extractor accessors in `/Users/ramijames/_CODE/Sprawl/Sprawl/Content/TerminalPanel.swift` and `/Users/ramijames/_CODE/Sprawl/Sprawl/Content/BrowserPanel.swift`.


---

## Editor ⌘K Inline Edit

_Phase 2 · Planned_

# Editor ⌘K Inline Edit — Spec

## Summary
Press ⌘K inside any `.document` panel (CodeEditSourceEditor) to edit, refactor, or explain the current selection with Claude, without leaving the editor. An inline prompt bar takes a natural-language instruction; Claude streams a replacement that is shown as a red/green inline diff with Accept (⌘↩) / Reject (⎋), so an AI edit lands through the exact same text-mutation + autosave path as a human keystroke. "Explain"-style questions answer in a read-only popover and never mutate the file.

## Phase
**Phase 2.** Sits directly on the FOUNDATION layer (`ClaudeClient`, auth, model registry, `StreamingTranscriptView`). It is the first user-facing Claude feature that writes into Sprawl content. Unlike the `assistant` panel (FOUNDATION §5) it adds **no new `WorkItem.Kind`** — it augments the existing document panel.

## Depends on
- FOUNDATION §1 `ClaudeClient.stream(_:)` (SSE → `AsyncThrowingStream<ClaudeDelta>`), §1a wire types including `ToolDefinition`/`ToolChoice`/`JSONValue` and `input_json_delta` streaming.
- FOUNDATION §2 `ClaudeAuth` + `ClaudeSettings` (catch `ClaudeError.noAPIKey` → present settings sheet).
- FOUNDATION §3 `ClaudeModel`/`ClaudeTask` (model selection), §4 prompt caching (file-prefix breakpoint), §7 `StreamingTranscriptView` (reused for the Explain popover).
- Existing editor stack: `DocumentPanel`/`DocumentModel`/`DocumentEditorView` (`Sprawl/Content/DocumentPanel.swift`), `DocumentLeaf` (`Sprawl/Content/TabbedContainer.swift`), and the responder-chain Save/Open routing in `MainSplitViewController`.
- Does **not** depend on the agent tool loop (FOUNDATION §1e) or `CanvasTools` (§6) — this is a single constrained turn.

## UX & interaction
Lives entirely inside the document panel `container` (`DocumentPanel`), no canvas/panel changes elsewhere.

1. User selects a range in the editor (or leaves an empty caret → scope defaults to the current line). Presses **⌘K**.
2. A **prompt bar** slides down directly under the existing 32pt functions bar (`functionsBar`, DocumentPanel.swift:115): single-line `NSTextField` ("Edit, refactor, or ask…"), a compact model menu (Sonnet default / Opus), and Cancel. The selected range is visually highlighted/locked; the editor goes read-only for the duration.
3. User types an instruction and hits ↩ (or clicks Send).
4. **Intent routing** (heuristic on the instruction, overridable): imperative ("rename…", "add error handling", "convert to async") → **edit/refactor**; interrogative ("what does this do?", "why…?", "explain") → **explain**.
5. **Edit/refactor:** Claude streams a structured `replacement` (forced tool, see Claude usage). As it arrives, an **inline diff overlay** (`InlineDiffView`) renders over the editor showing the captured selection as red (deletions) and the proposed text as green (insertions), line-aligned. Footer shows token/cost from final `usage`. Buttons: **Accept (⌘↩)** splices `replacement` into `model.text` at the captured range; **Reject (⎋)** discards and unlocks. A "Regenerate"/edit-instruction affordance re-runs without retyping.
6. **Explain:** no diff, no mutation. Answer streams into a `StreamingTranscriptView` hosted in an `NSPopover` anchored to the prompt bar; dismiss with ⎋.
7. No API key → the `ClaudeError.noAPIKey` catch calls the FOUNDATION §2 settings presenter (via the responder chain to `MainSplitViewController.showClaudeSettings`), then the user can re-press ⌘K. Refusals/errors render inline in the diff footer / popover (no half-applied text).

## Files & touchpoints
- **New `Sprawl/Claude/InlineEditController.swift`** — owns the prompt bar, intent routing, request building, the streaming consume loop, and the accept/reject state machine. Holds a `weak` ref to its `DocumentPanel`. Calls `ClaudeClient.shared.stream(_:)` directly (no tool loop). Strips/validates output; on accept calls back into the panel's replace API.
- **New `Sprawl/Claude/InlineDiffView.swift`** — `NSView` overlay that computes a line-level diff (old selection vs. streamed new text — a small LCS/Myers diff, no dependency) and draws red/green hunks with an accept/reject footer, themed from `Palette.swift` / `EditorTheme.endlessDark`.
- **Edit `Sprawl/Content/DocumentPanel.swift`** (the only file touching CodeEditSourceEditor — keep it that way):
  - Lift the editor selection out of SwiftUI: move `@State private var editorState` (DocumentEditorView, line 53) into `DocumentModel` as `@Published var editorState = SourceEditorState()` and bind `state: $model.editorState`. This lets `DocumentPanel` read `model.editorState.cursorPositions` (each `CursorPosition.range` is the selection `NSRange`, with 1-indexed start/end line/column).
  - Add `var selectedRange: NSRange?` (primary cursor), `var selectedText: String?`, and `func replaceRange(_ range: NSRange, with text: String)` that mutates `model.text` (splice on the `String`), so Accept flows through the existing `model.$text` → `onTextChange` → autosave sink (lines 85–91) with no new persistence plumbing.
  - Add `func beginInlineEdit()` that instantiates/installs the `InlineEditController` prompt bar into `container` and toggles editor read-only.
- **Edit `Sprawl/Model/AppModel.swift`** — no new `Kind`. Reuse `activeDocumentItem` (line 96) and `activeDocumentLeaf` (`DocumentLeaf.panel` → `DocumentPanel`); optionally expose a convenience `activeDocumentPanel`.
- **Edit `Sprawl/App/MainSplitViewController.swift`** — add `@objc func inlineEdit(_ sender: Any?)` mirroring `saveDocument` (line 151): `guard let item = model.activeDocumentItem, let leaf = item.activeDocumentLeaf else { return }; leaf.panel.beginInlineEdit()`. Add `showClaudeSettings(_:)` if not already created by FOUNDATION §2.
- **Edit `Sprawl/App/AppDelegate.swift`** — in the Edit menu (`setupMenu`, lines 213–218) add `"Inline Edit…"` action `#selector(MainSplitViewController.inlineEdit(_:))`, key equivalent `"k"` (⌘K), placed after Select All. (Functions-bar Open/Save already prove the responder-chain pattern, DocumentPanel.swift:119–126.)
- **`xcodegen generate`** required (new files under `Sprawl/Claude/`), then the standard `xcodebuild` per FOUNDATION §5 step 8; quit the running app first.

## Data & persistence
- **No `WorkspaceState`/`ItemState`/`TabState` schema change.** Accepted edits land in `model.text`, which is already serialized via `TabState.documentText` (AppModel snapshot, lines 517–520) and autosaved through `onTextChange`. Reject mutates nothing.
- The transient prompt text, streamed proposal, and diff state are in-memory only (never persisted; not in `workspace.json`).
- Last-used model is a UI preference, not workspace state → store in `UserDefaults` (`"sprawl.inlineEdit.model"`), default `ClaudeTask.interactive.model` (Sonnet 4.6).

## Claude usage
- **Model:** default **Sonnet 4.6** (`ClaudeTask.interactive`) — strong code edits at interactive latency/cost; **Opus 4.8** selectable for hard refactors. Skip Haiku for code edits (no effort param; weaker rewrites). `thinking: adaptive/summarized` + `effort: "medium"` for edits via `OutputConfig`; explain can use `effort: "low"`.
- **Structured output (no fence-stripping):** for edit/refactor, send one tool `propose_edit` with `input_schema {"replacement": string, "summary": string}` and `toolChoice {type:"tool", name:"propose_edit"}`. The `replacement` streams as `input_json_delta` (FOUNDATION §1b `toolInputDelta`) so the diff fills live; parse the accumulated JSON for the final value. This reuses `ToolDefinition`/`ToolChoice`/`JSONValue` from FOUNDATION §1a — it does **not** invoke the agent tool loop (§1e). For explain, no tool: plain text stream into `StreamingTranscriptView`. (Forced tool use disables thinking on the edit path — acceptable.)
- **Prompt sketch:**
  - *System (cached, FOUNDATION §4 breakpoint 1):* "You are a precise code-editing assistant embedded in the Sprawl editor. You are given a file and a selected region. For an edit, call `propose_edit` with the exact replacement text for the selection only — preserve surrounding indentation, no markdown fences, no commentary. For a question, answer concisely in prose." + the tool definition.
  - *User content:* block A (cache breakpoint 2) = language + file path + **full file text** with sentinel markers around the selection (`«SEL»…«/SEL»`); block B (volatile, after the breakpoint) = the selected substring + the user's instruction.
- **Caching:** the full-file block is the stable prefix keyed on `(model, fileURL, file bytes)` (FOUNDATION §4) — repeated ⌘K on the same file reuses it at ~0.1×. Verify `usage.cacheReadInputTokens > 0` on the second invocation; ensure no `Date()`/UUID leaks into blocks A or the system prompt.
- **Cost UI:** footer reads final `usage` from `messageDelta` × `ClaudeModel.pricing`.
- **Vision:** none.

## Effort
**M (~3–5 days).**
- DocumentPanel selection-lift + `replaceRange` + read-only lock + `beginInlineEdit`: **S**
- Prompt bar UI + ⌘K menu/responder wiring (MainSplitViewController/AppDelegate): **S**
- Request building (forced `propose_edit` tool, file+selection blocks, caching), streaming consume incl. `input_json_delta` accumulation: **S**
- `InlineDiffView` (line-diff algorithm + red/green render + accept/reject + range re-resolution): **M** (the hard part)
- Explain popover reusing `StreamingTranscriptView`, error/refusal/no-key surfacing: **S**

## Risks / open questions
- **No public caret geometry.** CodeEditSourceEditor exposes selection as `cursorPositions` (range + line/col) but not a caret rect; a true at-cursor bubble would need to reach the underlying text view. **Decision:** MVP anchors the prompt bar at the top of the editor and the diff as a full-width overlay; at-selection placement is a later enhancement.
- **Stale range on accept.** If `model.text` changed between capture and accept, the `NSRange` is invalid. **Mitigation:** lock the editor read-only during preview, capture both range and exact `selectedText`, and on accept verify the substring still matches at that range (else re-locate by first occurrence, or abort with a message).
- **Binding round-trip / re-highlight.** Programmatic `model.text` mutation must restore a sane cursor and may re-tokenize large files. Splice only the selection; avoid whole-file rewrites where possible.
- **Multi-cursor:** MVP operates on the primary `CursorPosition` only; ignore secondary selections.
- **Intent misclassification** (edit vs explain): provide an explicit mode toggle in the prompt bar so the user can override the heuristic.
- **Empty selection scope:** confirm "current line" is the right default vs. requiring a selection.

## Acceptance criteria
- [ ] ⌘K in a focused document panel opens the inline prompt bar; ⌘K with no document focused is a no-op (menu item disabled via responder chain).
- [ ] With a selection, an imperative instruction streams a `propose_edit` replacement rendered as a red/green inline diff; Accept (⌘↩) replaces exactly the captured range and Reject (⎋) leaves the file byte-identical.
- [ ] Empty caret defaults the scope to the current line and edits it correctly.
- [ ] An interrogative instruction streams a read-only explanation into a popover and never mutates `model.text`.
- [ ] Accepted edits autosave (round-trip through `onTextChange`) and survive relaunch via existing `TabState.documentText` — no new persisted fields, `workspace.json` schema unchanged.
- [ ] Model menu switches between Sonnet 4.6 and Opus 4.8; choice persists across edits via `UserDefaults`.
- [ ] Second ⌘K on the same unchanged file reports `usage.cacheReadInputTokens > 0`.
- [ ] No API key routes to the FOUNDATION §2 settings sheet; refusals and transport errors surface inline without applying partial text.
- [ ] Editor is read-only while a proposal is pending; canceling/rejecting fully restores editability and selection.
- [ ] `xcodegen generate` + Debug build succeed and mirror to `./build/Sprawl.app` with the new `Sprawl/Claude/InlineEditController.swift` and `InlineDiffView.swift`.

Relevant paths: `/Users/ramijames/_CODE/Sprawl/Sprawl/Content/DocumentPanel.swift`, `/Users/ramijames/_CODE/Sprawl/Sprawl/Content/TabbedContainer.swift`, `/Users/ramijames/_CODE/Sprawl/Sprawl/Model/AppModel.swift`, `/Users/ramijames/_CODE/Sprawl/Sprawl/App/MainSplitViewController.swift`, `/Users/ramijames/_CODE/Sprawl/Sprawl/App/AppDelegate.swift`, plus new `/Users/ramijames/_CODE/Sprawl/Sprawl/Claude/InlineEditController.swift` and `/Users/ramijames/_CODE/Sprawl/Sprawl/Claude/InlineDiffView.swift`.


---

## Workspace Conductor

_Phase 2 · Planned_

⌘K is unbound. I have what I need. Here is the spec section.

---

# Workspace Conductor — ⌘K Command Bar

## Summary
A ⌘K command bar where the user types a high-level goal in plain English ("set me up to work on the auth bug") and Claude, driving the existing `CanvasTools` tool layer, spawns and arranges the right panels — a terminal `cd`'d into the repo, the relevant files open, a Git Observer, docs in a browser — laying out a ready-to-work canvas in one shot. The model's tool-use output *is* the canvas layout: panels appear and the viewport pans/zooms to frame them. It turns "what do I open and where" into a single sentence, leaning hard into Claude as the thing that makes Sprawl's spatial canvas assemble itself.

## Phase
**Phase 2.** It is the first real consumer of the Phase-2 tool layer (`CanvasTools`, FOUNDATION §6) and the tool-use loop (FOUNDATION §1e). Ships after FOUNDATION and after `CanvasTools` is wired live (the seam is design-only today).

## Depends on
- FOUNDATION §1 `ClaudeClient` — specifically `runToolLoop(_:runner:maxTurns:onText:)` (§1e) and `send(_:)`.
- FOUNDATION §6 `CanvasTools` — the live `ClaudeToolRunner` backed by `AppModel` + `CanvasViewController`. **This feature requires the seam be built, not just designed.** It also *extends* it with two read-only discovery tools (see Files).
- FOUNDATION §7 `StreamingTranscriptView` — reused as the bar's progress/plan region.
- FOUNDATION §3 `ClaudeModel` / `ClaudeTask` (model selection), §2 `ClaudeAuth` (no-key funnel to Settings), §4 prompt caching.
- Does **not** depend on the `assistant` `WorkItem.Kind` (FOUNDATION §5). The Conductor is a transient overlay, not a persisted panel, so it touches none of the per-kind switches.

## UX & interaction
The bar is a transient floating overlay pinned **top-center** over the canvas (the mirror of the bottom-center `FloatingDock`), styled to match the dock (`FloatingDock` is the visual template).

1. User presses **⌘K** anywhere in the window (or **View ▸ Workspace Conductor…**). The bar fades in, top-center, focused, over the live canvas. A second ⌘K or **Esc** dismisses it.
2. User types a goal and presses **Enter**. The single-line field expands downward into a `StreamingTranscriptView` region showing Claude's streamed plan ("Found `AuthManager.swift`, `LoginView.swift`; opening files, terminal in repo root, git observer…") and a live token/cost readout (from `usage`, FOUNDATION §3).
3. As the tool loop runs, panels **appear on the canvas in real time** — each `spawn_panel`/`open_file`/`move_panel` call routes through `AppModel.addItem`/window frame setters, so they animate and select exactly like user actions. By default everything lands in the **current project**; the goal can ask for a fresh project.
4. When the loop finishes (`stop_reason != "tool_use"`), the bar shows a one-line summary plus **Undo** and **Done**. The canvas auto-pans/zooms to frame the new batch (a new `CanvasViewController.frameItems(_:)` helper, modeled on `focusProject`). **Undo** removes exactly the panels this run created (tracked by `WorkItem.id`), via `AppModel.removeItem`.
5. No API key → the run throws `ClaudeError.noAPIKey`, which the bar catches and routes to `MainSplitViewController.showClaudeSettings(_:)` (FOUNDATION §2), the same funnel every feature uses.
6. Optional entry point: a "Conductor here…" item in the `CanvasView` context menu that pre-seeds the spawn anchor at the click point.

## Files & touchpoints
Reuse FOUNDATION's `ClaudeClient`, `CanvasTools`, and `StreamingTranscriptView` — do not redefine them.

- **NEW `Sprawl/Claude/ConductorBar.swift`** — the overlay command-bar view/controller: secure-styled input field + embedded `StreamingTranscriptView` (§7) + Undo/Done buttons + cost label. Exposes `var onSubmit: ((String) -> Void)?`, `func show()/dismiss()`, `func appendDelta(_:)`. Holds the list of `WorkItem.id`s spawned during the active run for Undo. Pure view; no networking.
- **EXTEND `Sprawl/Claude/CanvasTools.swift`** (FOUNDATION §6) — the Conductor's runner is `CanvasTools` itself. Add two **read-only discovery** cases + their JSON-schema entries (do not fork the runner):
  - `read_workspace` → returns the current project name, its `ItemState.workingDirectory` repo path(s), and existing panels (`id`, `kind`, `frame`) so Claude plans relative to what's already open and avoids collisions.
  - `search_repo` → grep/`git grep` over the repo root via the same `Process` shell-out pattern as `GitObserverPanel.runGitLog` (`Sprawl/Content/GitObserverPanel.swift:254`), capped output, so Claude can locate "auth"-relevant files/paths. Read-only.
  The write path uses the existing seam cases verbatim: `spawn_panel` (→ `AppModel.addItem(kind:in:at:url:)`), `open_file`, `move_panel`, `resize_panel`, `run_git` (read-only: log/status/diff). Each spawn returns the new `WorkItem.id` + frame so Claude can `move_panel`/`resize_panel` it into a deliberate grid.
- **`Sprawl/Canvas/CanvasViewController.swift`** — add `addTopOverlay(_:topInset:)` mirroring `addBottomOverlay` (line 128) to pin the bar; add `frameItems(_ items: [WorkItem])` that unions the windows' frames and pans/zooms to fit (model on `focusProject`, lines 107–122). Reuse `centerOnItem`/`fitItemVertically` as-is.
- **`Sprawl/App/MainSplitViewController.swift`** — add `installConductor()` (build `ConductorBar`, `canvasVC.addTopOverlay(bar)`) called from `viewDidLoad` next to `installDock()` (line 38); add `@objc func showConductor(_ sender: Any?)` (toggle the bar) near the other `@objc` actions (line 116+). Wire `bar.onSubmit` to launch a `Task` that builds the request and calls `ClaudeClient.shared.runToolLoop(req, runner: CanvasTools(model:canvasVC:), onText:)`, streaming text into the bar; `canvasVC` is already a stored property here. On completion call `canvasVC.frameItems(...)`.
- **`Sprawl/App/AppDelegate.swift`** — in `setupMenu()` add a "Workspace Conductor…" item under the **View** menu (or a new top-level "Claude" menu), `keyEquivalent: "k"` (verified free), `action: #selector(MainSplitViewController.showConductor(_:))`. Pairs with the Settings… item from FOUNDATION §2.
- **`Sprawl/Canvas/CanvasView.swift`** — optional context-menu item "Conductor here…" (after the existing "New …" items) that opens the bar with a seeded anchor; reuses `addWindow` (line 565) only indirectly through `addItem`.
- **NEW files require `xcodegen generate`** before building (`ConductorBar.swift`; `CanvasTools.swift` if it doesn't exist yet), then the standard `xcodebuild` (quit the running app first so the re-sign/mirror to `./build/Sprawl.app` succeeds).

## Data & persistence
- **No new persisted panel state.** Because every Conductor write routes through `AppModel.addItem` / window frame setters, the spawned panels are captured by the *existing* snapshot path (`ItemState` in `Sprawl/Persistence/WorkspaceState.swift`) and autosaved via `AppModel.onPersistableChange` (FOUNDATION §6's whole point). A reloaded workspace shows exactly the Conductor's layout.
- **Optional additive field:** `conductorHistory: [String]` on the top-level `WorkspaceState` for ⌘K prompt recall (up/down through recent goals). Additive `Codable` with default `[]`, so old `workspace.json` files decode unchanged. Cap to ~20 entries.
- The active run's spawned `WorkItem.id`s for Undo live **only in `ConductorBar` memory**, not persisted (Undo is a within-session affordance).

## Claude usage
**Model: Opus 4.8 (`ClaudeModel.opus`) via `ClaudeTask.hard`** — turning a vague goal into a concrete multi-panel plan over real repo state is agentic planning + multi-tool reasoning, exactly where Opus + `effort:"high"` + adaptive `thinking` (display `"summarized"`, streamed into the bar) pays off. `ClaudeTask.hard` already encodes that. (A future fast-path could downshift simple goals to Sonnet, but default to Opus for layout quality.)

**Tools:** `CanvasTools.definitions` (FOUNDATION §6) plus the two added discovery tools. **Parallel tool use enabled** (don't set `disableParallelToolUse`) so Claude can `spawn_panel` several panels in one turn — critical for latency, since each turn is a billed round trip. `run_git` stays read-only; no commit/checkout/push from the agent (matches §6's safety constraint).

**System / user prompt sketch:**
- *System (cached, breakpoint 1 — FOUNDATION §4):* "You are the Sprawl Workspace Conductor. The user gives a high-level dev goal; you assemble a working canvas by calling tools to spawn and arrange panels. Available panel kinds: terminal, document, browser, gitObserver, gitGraph, projectVelocity. Discover state with `read_workspace`/`search_repo` before acting. Open the files most relevant to the goal as `document` panels, put a `terminal` cwd'd at the repo root, add a `gitObserver` on the repo, and a `browser` for any docs URL. Arrange panels in a non-overlapping grid using the frames returned by `spawn_panel` + `move_panel`. Be decisive; prefer 3–6 panels. Read-only on git." Tool definitions render before this; `cache_control` on the last system block.
- *Cached, breakpoint 2:* the current project's repo file list / tree from `read_workspace`'s first call (stable across a session → cache reads on repeat goals, FOUNDATION §4).
- *User (volatile, last):* the typed goal + current project name + selection + click anchor if any.

**Caching:** two breakpoints as above; verify `usage.cacheReadInputTokens > 0` on a second goal against the same repo. Keep timestamps/UUIDs out of the cached prefix (serialize the panel/repo listing with sorted keys).

**Vision:** not used in MVP. Layout discovery is deterministic via `read_workspace` (cheaper and exact than screenshotting the canvas). A "look at my current layout" vision pass is a possible later enhancement.

## Effort
**M.** Breakdown:
- `CanvasTools` write-path made live (`spawn_panel`/`move_panel`/`resize_panel`/`open_file`/`run_git`) — counts against the tool-layer task, but the Conductor is its forcing function: **M** on its own.
- `read_workspace` + `search_repo` discovery tools + schemas: **S**.
- `ConductorBar.swift` overlay UI (input + reused `StreamingTranscriptView` + Undo/cost): **M**.
- Menu/keyboard/overlay wiring (`MainSplitViewController`, `AppDelegate`, `addTopOverlay`/`frameItems`): **S**.
- Prompt + caching + parallel-tool tuning + Undo-batch tracking: **S–M**.

## Risks / open questions
- **Latency / cost.** A multi-turn Opus tool loop spawning 5 panels is several seconds and real money. Mitigate with parallel tool use, a turn cap (`maxTurns` ~6), and a visible cost readout. Open: cache a fast Sonnet path for trivial goals?
- **Repo discovery scale.** `search_repo`/file-tree on a huge repo blows context. Cap results, scope `git grep` to tracked files, rely on caching. Open: do we need a lightweight indexed tree vs. live grep each run?
- **Layout collisions / off-canvas placement.** Claude must place a deliberate grid; rely on `read_workspace` returning existing frames + `clampedOrigin` (`AppModel.swift:163`) guarding bounds. Open: provide a higher-level `arrange_grid` tool, or trust spawn+move primitives? (Spec chooses primitives.)
- **Which project.** Default to current project vs. minting a new one named after the goal. Spec: current project by default; goal text can request a new project.
- **Undo granularity.** Tracking spawned ids gives batch Undo, but if the user edits a spawned panel before undoing, removal is still clean (panels are independent). Confirm Undo also reverts any `move_panel` on pre-existing panels — or scope Undo to spawns only (spec: spawns only).
- **Destructive git.** Keep `run_git` read-only until a confirmation gate exists (FOUNDATION §6).
- **`CanvasTools` must exist.** If the tool layer slips, this feature is blocked; the discovery tools assume the seam is real.

## Acceptance criteria
- [ ] ⌘K (and View ▸ Workspace Conductor…) toggles a top-center overlay bar over the canvas; Esc / second ⌘K dismisses it; bar takes key focus on open.
- [ ] Typing a goal + Enter streams Claude's plan text (and summarized thinking) into the bar's `StreamingTranscriptView` with a live token/cost readout.
- [ ] During the run, panels appear on the live canvas via `CanvasTools` (no bespoke spawn path) — they select/animate like user-created panels and trigger autosave.
- [ ] For "set me up to work on the auth bug" in a project whose repo contains auth code, the result includes at minimum: a terminal cwd'd at the repo root, ≥1 relevant file open as a document, and a Git Observer on the repo — arranged without overlapping.
- [ ] On completion the canvas pans/zooms to frame the new batch (`frameItems`).
- [ ] **Undo** removes exactly the panels created by that run and nothing else.
- [ ] Reloading the app (relaunch) restores the Conductor-built layout from `workspace.json` with no extra persistence code beyond the existing `ItemState` path.
- [ ] With no API key, submitting routes to the Claude Settings sheet (no crash, no silent failure).
- [ ] `run_git` performs only read-only operations; no commit/checkout/push is reachable from the Conductor.
- [ ] Second goal against the same repo shows `usage.cacheReadInputTokens > 0` (prefix caching verified).
- [ ] `xcodegen generate` + Debug build succeed with the new files; running app quit before build so the mirror to `./build/Sprawl.app` re-signs cleanly.

---

Grounding notes (real paths verified): overlay pattern `CanvasViewController.addBottomOverlay` at `Sprawl/Canvas/CanvasViewController.swift:128`; spawn path `AppModel.addItem(kind:in:at:url:)` at `Sprawl/Model/AppModel.swift:261`; `installItem`/`spawnFrame`/`clampedOrigin` at `AppModel.swift:354/324/163`; menu wiring `AppDelegate.setupMenu()` `Sprawl/App/AppDelegate.swift:153+` (⌘K confirmed unbound; `1`–`6`,`t`,`w`,`o`,`s`,`q` taken); `MainSplitViewController` actions/`installDock` at `Sprawl/App/MainSplitViewController.swift:59,116`; `addWindow` at `Sprawl/Canvas/CanvasView.swift:565`; git `Process` shell-out template `Sprawl/Content/GitObserverPanel.swift:254`; persistence types in `Sprawl/Persistence/WorkspaceState.swift`. No `Sprawl/Claude/` directory exists yet — all FOUNDATION + this feature's files are net-new.


---

## Sprawl as an MCP Server

_Phase 3 · Planned_

# Sprawl as an MCP Server — Spec

## Summary
Host an in-process **MCP server** inside the running Sprawl app that exposes the `CanvasTools` surface (FOUNDATION §6 — spawn/move/resize panels, open files, read panel contents, read-only git) as MCP tools. This lets **Claude Code running in Sprawl's embedded terminal** (or any MCP client) drive the very canvas it lives in — "open a terminal next to this doc," "tile these three panels," "read what's in the velocity chart" — closing the loop between the agent and its spatial workspace.

## Phase
**Phase 3.** It is the agentic capstone: it requires the `CanvasTools` tool-layer seam (§6) to be *built* (it is design-only in MVP), which itself depends on the Phase-1 FOUNDATION. Ship after the Phase-2 assistant panel has exercised `CanvasTools` end-to-end in-process.

## Depends on
- **FOUNDATION §6 `CanvasTools`** — must be promoted from design to a working `@MainActor ClaudeToolRunner`. This feature is a *transport adapter* in front of it; it adds no new tool logic.
- **FOUNDATION §1a `ToolDefinition` / `JSONValue`** — reused verbatim for MCP `tools/list` schemas and `tools/call` argument decoding. Do **not** redefine.
- **FOUNDATION §1e `ClaudeToolRunner`** — the `definitions` / `run(name:input:)` contract is the entire server-side dispatch surface.
- The existing terminal panel (Claude Code host) and `GitObserverPanel` (panel template, `Sprawl/Content/GitObserverPanel.swift`).
- Independent of `ClaudeClient` (§1c) — the server does **not** call the Claude API; the *client* (Claude Code) is the LLM. No API key required to run the server.

## Transport decision (stdio vs HTTP) and hosting
**Decision: Streamable HTTP, hosted in-process, bound to `127.0.0.1`.** Rationale, stated decisively:

- The tools must mutate the **live GUI instance's** `AppModel`/`CanvasViewController` on the main actor. stdio MCP servers are *spawned as a fresh child process* by the client and have no handle to the running app; making stdio work would require shipping a second "shim" binary that bridges stdin/stdout to the app over a local socket/XPC — an extra moving part for zero benefit here.
- An **in-process HTTP server** runs inside the same address space as the canvas, so `tools/call` hops straight onto `@MainActor` and calls `CanvasTools.run`. Claude Code natively supports URL servers (`claude mcp add --transport http sprawl http://127.0.0.1:<port>/mcp`, or a project-scope `.mcp.json`).
- **Hosting mechanism:** `Network.framework` `NWListener` (TCP, `using: .tcp`, `requiredLocalEndpoint` = `127.0.0.1:<port>`) — dependency-free, matching Sprawl's no-SPM-for-infra ethos. Hand-roll the minimal HTTP/1.1 + SSE framing needed for Streamable HTTP (one `POST /mcp` endpoint that returns `application/json` for unary replies or an `text/event-stream` body when streaming; optional `GET /mcp` SSE channel for server→client notifications; `Mcp-Session-Id` header for session continuity).
- **No entitlement blocker:** confirmed Sprawl is **not** App-Sandboxed — `project.yml` has no entitlements file and signs ad-hoc (`codesign --force --sign -`, `ENABLE_USER_SCRIPT_SANDBOXING: NO`). A localhost listening socket needs no `com.apple.security.network.server` because there is no sandbox. (If sandboxing is ever added, that entitlement becomes required — note in Risks.)
- stdio is recorded as a **future fallback** (for clients that can't do HTTP) via a thin shim that proxies to the same localhost endpoint — not built now.

## UX & interaction
Lives on the canvas as a new **`mcpServer` panel kind** ("Canvas Control"), wired exactly like `gitObserver` per FOUNDATION §5. It is a *control surface*; the server lifecycle is owned by the app, not the panel.

Panel contents (top to bottom):
1. **Status row** — running/stopped pill, `127.0.0.1:<port>`, connected-client count.
2. **Master toggle** — Start/Stop server. **"Allow canvas writes" gate** (default OFF): when OFF, mutating tools (`spawn/move/resize/open_file`) return an `isError` result telling the agent to ask the user to enable writes; reads always work. `run_git` stays read-only regardless (§6 safety).
3. **Connect Claude Code** button — writes/updates a project-scope `.mcp.json` into the **focused terminal panel's working directory** (or a chosen project folder) with the HTTP URL + a token reference, and shows the exact `claude mcp add` one-liner to copy. A "Copy config" button copies the JSON.
4. **Live audit log** — append-only list of every `tools/call` (timestamp, tool, target panel id, OK/error). This is the human's window into agent activity; mirrors the streaming feel of other panels.

Step-by-step user flow:
1. User opens a terminal panel, `cd`s into a project, hasn't run `claude` yet.
2. User opens the **Canvas Control** panel (dock "AI" folder / File menu / canvas context menu), clicks **Start**, then **Connect Claude Code** (writes `.mcp.json` to the terminal's cwd).
3. User toggles **Allow canvas writes** on if they want the agent to rearrange panels.
4. In the terminal, `claude` starts, auto-discovers the `sprawl` MCP server, and `tools/list` shows the canvas tools.
5. Agent calls e.g. `spawn_panel` → a panel animates in on the canvas, the audit log appends a row, and the change autosaves (because `CanvasTools` routes through `AppModel.addItem`, FOUNDATION §6).

## Files & touchpoints
**New files (all under `Sprawl/Claude/`, then `xcodegen generate`):**
- `Sprawl/Claude/MCPServer.swift` — `NWListener` lifecycle (start/stop/port), HTTP/1.1 + SSE framing, JSON-RPC 2.0 dispatch, MCP lifecycle (`initialize` → capabilities `{tools:{listChanged:true}}` + `serverInfo` + negotiated `protocolVersion`, then `notifications/initialized`), `tools/list`, `tools/call`. Holds a `CanvasTools` instance (the §6 runner) and a bearer-token check. `tools/list` serializes `canvasTools.definitions` (`[ToolDefinition]`); `tools/call` decodes `arguments` → `JSONValue`, `await`s `canvasTools.run(name:input:)` on `@MainActor`, wraps the `(content,isError)` into MCP `{content:[{type:"text",text:…}], isError}`. Publishes an audit closure for the panel.
- `Sprawl/Claude/MCPTypes.swift` — JSON-RPC 2.0 request/response/notification + MCP `InitializeResult`, `ServerCapabilities`, `ToolCallResult` `Codable` types. **Reuses `ToolDefinition` and `JSONValue` from `ClaudeTypes.swift`** — do not redefine.
- `Sprawl/Claude/MCPServerPanel.swift` — UI, mirrors `GitObserverPanel` shape: `let containerView = NSView()`, `init(...)`, `func attach(to window: WindowView) { window.setContent(containerView) }` (`Sprawl/Windows/WindowView.swift:135`), `var onTitleChange:`, `var onRepoChange:`/persist callback. Owns status/toggles/audit-log views and the `.mcp.json` writer.

**Every-switch wiring (copy the `gitObserver` template, FOUNDATION §5):**
- `Sprawl/Model/AppModel.swift` — `WorkItem.Kind` add `case mcpServer`; `symbolName` case; stored ref `var mcpServerPanel: MCPServerPanel?`; `addItem` name base `"Canvas Control"`; `installItem` build case (construct panel, `attach(to:)`, wire `onTitleChange`, wire persist to `onPersistableChange?()`); `snapshot` `kindState = .mcpServer` (+ `workingDirectory` = project where `.mcp.json` was written); `restore` mapping.
- `Sprawl/Persistence/WorkspaceState.swift` — `ItemState.Kind` add `mcpServer`. Add top-level `mcpAutoStart: Bool` + `mcpPort: Int?` (see Data).
- `Sprawl/App/FloatingDock.swift` — `var onNewMCPServer: (() -> Void)?` + folder menu item ("Canvas Control").
- `Sprawl/App/MainSplitViewController.swift` — `installDock()` wiring + `@objc func newMCPServer(_:)`.
- `Sprawl/App/AppDelegate.swift` — File-menu item (next free key equivalent).
- `Sprawl/Canvas/CanvasView.swift` — context-menu item + `@objc` handler.
- `Sprawl/Support/LucideIcon.swift` — **no server/plug icon exists** (icons are hand-coded `[Shape]` path arrays: `folderPlus`, `squareTerminal`, `globe`, …). Add a new `static let server` (or `plugZap`) shape, or reuse `globe`. This is a real extra touchpoint beyond the §5 template.
- `project.yml` — picks up new `Sprawl/Claude/*` via glob; run `xcodegen generate` before building (quit the app first so the post-build re-sign/mirror to `./build/Sprawl.app` succeeds).

## Data & persistence
- `ItemState.Kind` gains `mcpServer`; the panel persists like `gitObserver` (its `workingDirectory` = the project folder whose `.mcp.json` it manages, so reconnect survives restart).
- `WorkspaceState` top-level: `mcpAutoStart: Bool = false` and `mcpPort: Int?` (sticky port across launches; nil → pick a default, e.g. 8787, falling back to ephemeral on conflict). Keep additions minimal and defaulted so old `workspace.json` files decode.
- **Bearer token in Keychain**, not `workspace.json` — reuse the `ClaudeAuth` Keychain pattern (FOUNDATION §2) under a distinct service `com.sprawl.mcp` / account `MCP_SERVER_TOKEN`. Generate once, persist, so the written `.mcp.json` stays valid across restarts. The `.mcp.json` references the token via env expansion (`"headers": {"Authorization": "Bearer ${SPRAWL_MCP_TOKEN}"}`) rather than embedding the secret in a possibly git-tracked file.

## Claude usage
- **The server makes no Claude API calls.** It is the inverse direction: the consuming model is the user's **Claude Code session** (typically **Opus 4.8**, `claude-opus-4-8`, for agentic canvas driving — most capable at multi-step tool orchestration; Sonnet 4.6 is fine for lighter rearrangement). Model choice is the client's, not Sprawl's.
- **The tool schemas ARE the prompt surface** consumed by that external model — so `CanvasTools.definitions` descriptions must be crisp and action-oriented (e.g. `spawn_panel`: "Create a new panel on the canvas (terminal|document|browser|git*). Returns the new panel's id."). No additional system prompt is authored by Sprawl; MCP `serverInfo.instructions` MAY carry a one-paragraph "this canvas is the user's live workspace; address panels by id; ask before destructive ops" hint.
- **Tools:** the full `CanvasTools` set, gated (reads always; writes behind the panel toggle; `run_git` read-only).
- **Caching / vision:** N/A on Sprawl's side — prompt caching and any vision are handled by the client. (Optional, out-of-scope gold-plating: Sprawl could use **Haiku 4.5** via `ClaudeClient` to summarize audit-log rows into plain English; not part of this spec.)

## Effort
**L.** Breakdown:
- `NWListener` HTTP/1.1 + SSE + JSON-RPC framing (`MCPServer.swift`) — **M**, the genuine work (manual chunked/SSE, keep-alive, off-main socket I/O).
- MCP lifecycle + `tools/list`/`tools/call` adapter over `CanvasTools` — **S** (thin; reuses §6 + §1a types).
- Panel UI + `.mcp.json` writer + audit log (`MCPServerPanel.swift`) — **M**.
- Every-switch wiring + new Lucide icon — **S** (mechanical, copy `gitObserver`).
- Token/Keychain + write-gate + localhost binding — **S/M**.
- *Prerequisite:* promoting `CanvasTools` from design to working is its own **M** and should be tracked under the Phase-2 work, not double-counted here.

## Risks / open questions
- **Hand-rolled HTTP/SSE correctness** (chunked transfer, SSE event framing, keep-alive, partial reads across `NWConnection` receives). Mitigation: tight unit tests against `curl`/the MCP Inspector; keep the endpoint surface to exactly what Streamable HTTP needs.
- **MCP protocol-version drift** — pin/negotiate the version Claude Code sends in `initialize`; reject unknown major versions gracefully.
- **Concurrency** — tool calls arrive off-main and may be parallel; `CanvasTools` is `@MainActor`. Serialize or queue main-actor hops; decide whether to advertise `disable_parallel_tool_use` semantics (the client controls this, but the server must tolerate concurrency).
- **Secret hygiene** — ensure the written `.mcp.json` never embeds the raw token in a git-tracked project; prefer env-var expansion and warn if the cwd is a repo.
- **Lifecycle** — confirm: server is app-scoped (survives closing the panel), stops on app quit; closing the last Canvas Control panel does **not** stop it (only the toggle does). Decide auto-start-on-launch default (proposed: off).
- **Port conflicts / multiple Sprawl windows** — single shared server per app process; sticky port with ephemeral fallback.
- **Safety of writes** — even with the gate, an agent loop could spam panels; consider a rate limit / "undo last agent batch." Destructive git stays out (§6) until a confirmation gate exists.
- **Future sandboxing** — if Sprawl ever adopts App Sandbox, add `com.apple.security.network.server`.

## Acceptance criteria
- [ ] `mcpServer` kind builds clean through **every** switch (AppModel enum/symbol/ref/addItem/installItem/snapshot/restore; `WorkspaceState.ItemState.Kind`; dock; `MainSplitViewController`; `AppDelegate` menu; `CanvasView` context menu) and a new Lucide icon renders.
- [ ] Panel can **Start/Stop** an `NWListener` on `127.0.0.1:<port>`; status row reflects state and client count.
- [ ] `claude mcp add --transport http sprawl http://127.0.0.1:<port>/mcp` (or the panel-written `.mcp.json`) makes the server discoverable; `claude` lists Sprawl's tools.
- [ ] MCP `initialize` → `tools/list` returns `CanvasTools.definitions` (no schema divergence from §6); `tools/call` executes via `CanvasTools.run` on the main actor and returns a well-formed `{content,isError}`.
- [ ] A successful `spawn_panel`/`move_panel` call **visibly changes the canvas**, appends an audit-log row, and **autosaves** (`onPersistableChange` fires) identically to a user action.
- [ ] **Write gate** works: with "Allow canvas writes" OFF, mutating tools return `isError` with a clear message and the canvas is unchanged; reads still succeed; `run_git` is read-only in both states.
- [ ] Requests without the valid bearer token are rejected (401); the server only ever binds loopback (never `0.0.0.0`).
- [ ] Server is reachable from a non-Sprawl MCP client (MCP Inspector) for the same tool set.
- [ ] Persistence round-trips: `mcpAutoStart`/`mcpPort` and the panel survive quit/relaunch; token persists in Keychain (not in `workspace.json`); old `workspace.json` files still decode.
- [ ] `xcodegen generate` + Debug build succeed and mirror to `./build/Sprawl.app`; with the server stopped, Sprawl behaves exactly as today (zero behavior change).


---

## Cross-project Stale/WIP Radar

_Phase 3 · Planned_

# FEATURE: Cross-project Stale/WIP Radar

## Summary
A slim status ribbon drawn on every project folder card that summarizes its git repo at a glance — `3 unpushed · 12 behind · stalled 9d` plus an AI one-liner that says what you were doing and where to pick up. Git facts are computed locally (cheap, deterministic); only the "pick up here…" sentence is an AI call, generated for all repos in one batched, cached Haiku request. Turns the canvas from a layout into a cross-project standup dashboard so the user can re-enter any project cold without spelunking `git log`.

## Phase
**Phase 3.** Depends on the FOUNDATION layer and reuses the read-only git shell-out already shipping in `GitObserverPanel`/`ProjectVelocityPanel`. No new tool-loop or streaming UI needed — it's a one-shot bulk classification, which is exactly the `ClaudeTask.bulk` lane the foundation defines.

## Depends on
- **FOUNDATION §1 `ClaudeClient.send(_:)`** — non-streaming convenience (these responses are short; no SSE UI). Not `stream`.
- **FOUNDATION §2 `ClaudeAuth`** — radar degrades to git-only (no one-liner) when `ClaudeError.noAPIKey`; never blocks the deterministic ribbon.
- **FOUNDATION §3 `ClaudeTask.bulk` → Haiku**, `thinking: nil`, `effort: nil` (Haiku 400s on effort).
- **FOUNDATION §4 caching** — frozen system prompt breakpoint so re-runs across sessions get cache reads.
- **FOUNDATION §6 `CanvasTools`** — NOT required (radar is read-only and doesn't spawn panels). Optional later: a `read_radar` tool so the Phase 2 assistant panel can answer "what's stale?".
- Existing read-only git pattern: `GitObserverPanel.runGitLog` (`Sprawl/Content/GitObserverPanel.swift:254`), `ProjectVelocityPanel` Process block (`Sprawl/Content/ProjectVelocityPanel.swift:165`).
- **No dependency on the assistant `WorkItem.Kind` (FOUNDATION §5)** — the radar is not a panel; it's chrome painted onto existing folder cards. This ships independently.

## UX & interaction
The radar lives **on the project folder card itself** (drawn by `CanvasView`), not in a panel.

1. **The ribbon.** Below the project's name tab (and inside the collapsed pill), `CanvasView` paints a one-line ribbon with up to four segments, each a colored dot + count:
   - `↑3` unpushed (commits ahead of upstream) — amber
   - `↓12` behind upstream — blue
   - `●5` dirty (uncommitted working-tree changes) — orange
   - `9d` stale (days since last commit) — gray→red ramp via the existing `recency()`-style ramp in `ProjectVelocityPanel`
   - A clean, current, pushed repo shows a single muted check; segments with a zero count are omitted.
2. **AI one-liner on hover/click.** Clicking the ribbon (or hovering ~0.5s) opens an `NSPopover` anchored to the ribbon rect showing the full breakdown plus the Haiku sentence: *"Mid-refactor on `auth-rewrite`; 3 commits not pushed and tests untouched — pick up at the session-token TODO."* Popover has a **Pick up here** button.
3. **"Pick up here"** calls `CanvasViewController.focusProject(_:)` (`Sprawl/Canvas/CanvasViewController.swift:107`) to zoom/pan to the folder, then `centerOnItem`/`focusItem` (lines 66/57) on the project's most-recently-touched item (a git panel or terminal in that repo).
4. **Associating a repo.** A project has no repo today. The radar infers one from any child git item's `repoPath`/`workingDirectory`; if none, the folder context menu (`CanvasView.menu(for:)`, `Sprawl/Canvas/CanvasView.swift:319`) gains **"Set Project Repo…"** (NSOpenPanel, directory). Projects with no repo simply draw no ribbon — zero behavior change.
5. **Refresh cadence.** Recompute the deterministic git facts on: workspace restore, project select, item add/remove in a repo project, and a manual **"Refresh Radar"** dock action. The AI one-liners refresh batched on a debounce (default 15 min, or on manual refresh) — never per keystroke, never per redraw.

## Files & touchpoints
New files (all under `Sprawl/Claude/` per FOUNDATION; require `xcodegen generate`):
- **`Sprawl/Claude/RepoRadar.swift`** — `RepoStatus` value type + `RepoRadarScanner` that shells out to `/usr/bin/git` (copy the `Process` pattern from `GitObserverPanel.swift:254`). Runs, per repo, off the main thread: `status --porcelain=v1` (dirty count), `rev-list --count @{u}..HEAD` (ahead) and `--count HEAD..@{u}` (behind, tolerate no-upstream → nil), `log -1 --format=%ct%x1f%s%x1f%D` (last-commit unix time, subject, branch/refs), and `log -5 --format=%s` (recent subjects for the prompt). Returns `[UUID: RepoStatus]` keyed by project id.
- **`Sprawl/Claude/RadarSummarizer.swift`** — builds ONE `ClaudeRequest` over all dirty/stale repos and calls `ClaudeClient.shared.send` (`ClaudeTask.bulk`). Parses one one-liner per project id back into the cache. Catches `ClaudeError.noAPIKey`/`.refused` silently (git ribbon still shows).

Edits to existing files:
- **`Sprawl/Model/AppModel.swift`**
  - `Project` (line 55): add `var repoPath: String?` and transient `var radar: RepoStatus?` (+ `var radarLine: String?`).
  - `snapshot()` (line 527) `ProjectState(...)` construction at line 566: persist `repoPath` and a `RadarCache`.
  - `restore()` (line 574, ~577): read them back so the ribbon paints instantly on relaunch without a git/AI round-trip.
  - Add `func refreshRadar(projects:)` orchestrating scanner → summarizer → `canvas.needsDisplay` + `onPersistableChange?()`.
- **`Sprawl/Canvas/CanvasView.swift`**
  - `drawFolder(for:selected:)` (line 92): after `drawTabTitle` (line 111), call new `drawRadarRibbon(for:in: layout)`; reserve a ribbon strip below `layout.tab` (extend `folderLayout` line 182 with a `ribbon: NSRect`, and `folderBounds` line 207 to include it so it isn't culled). Collapsed pill (line 98) draws a compact badge variant.
  - Add ribbon hit-testing in `mouseDown` (line 214, alongside the chevron/dot hit tests at 225/229) → open the popover / fire `onPickUpHere?(project.id)`.
  - `menu(for:)` (line 319): add **"Set Project Repo…"** for the hit folder.
  - New callbacks `var onPickUpHere: ((UUID) -> Void)?`, `var onSetProjectRepo: ((UUID) -> Void)?` wired in `AppModel` setup (near lines 128–145).
- **`Sprawl/Canvas/CanvasViewController.swift`** — handle `onPickUpHere`: `focusProject` then `centerOnItem` on the repo's last-touched item.
- **`Sprawl/App/FloatingDock.swift`** — add `var onRefreshRadar: (() -> Void)?` (near line 13) and a folder/menu item "Refresh Radar" (folder closures ~lines 41–52). Wire in `MainSplitViewController.installDock()` (`Sprawl/App/MainSplitViewController.swift:66`).
- **`Sprawl/Support/Palette.swift`** — add `radarUnpushed/Behind/Dirty/Stale/Clean` colors near the project tokens (lines 7–12).
- Reuse `LucideIcon` for popover glyphs; reuse `ClaudeModel.pricing` for an optional cost line in the popover footer.

## Data & persistence
`Sprawl/Persistence/WorkspaceState.swift`:
- `ProjectState` (line 37): add `var repoPath: String?` and `var radar: RadarCache?` (both optional → older saves load unchanged).
- New `struct RadarCache: Codable { var ahead: Int?; var behind: Int?; var dirty: Int; var lastCommit: Date?; var branch: String?; var line: String?; var computedAt: Date }`.

Persisting the cache means the ribbon renders correctly on cold launch from the last scan; `computedAt` drives staleness of the cache itself (re-scan if older than the cadence). No `WorkspaceState.version` bump strictly required (additive optionals), but bump to 5 if you want migration to backfill `repoPath` from a child git item. The AI one-liner is cached here, NOT re-requested on every redraw — that's the whole cost story.

## Claude usage
**Model: Haiku 4.5 via `ClaudeTask.bulk`** — labeling/summary is the canonical bulk job; no thinking, no effort (would 400). Cheapest tokens, and one-liners need speed over depth. Batched: one request covers every dirty/stale repo, so N projects ≈ one Haiku call. For large workspaces (20+ repos) or a background nightly sweep, escalate to the **Batches API** (FOUNDATION mentions it) — same prompt shape, 50% cheaper, async.

**Caching (FOUNDATION §4):** Breakpoint 1 on a frozen `SystemBlock` (persona + output contract + the JSON shape). Volatile per-repo facts go last, after the breakpoint. Sort repos by id for deterministic prefix so repeat sweeps get `cacheReadInputTokens > 0`.

**System prompt (frozen, cached):**
> You summarize the working state of git repositories for a developer returning to them. For each repo you receive its name, branch, commits ahead/behind upstream, count and names of uncommitted files, days since last commit, and the last 5 commit subjects. Write ONE present-tense sentence per repo (≤18 words): what they were last doing and a concrete "pick up here" pointer. No counts (the UI shows those). Return strict JSON: `{"<id>": "<sentence>"}`. No prose outside the JSON.

**User message (volatile, last):** a compact JSON array, one object per project: `{id, name, branch, ahead, behind, dirtyFiles:[…names, truncated], staleDays, recentSubjects:[…5]}`.

**Tools:** none (read-only summary). **Vision:** none. Cost surfaced in the popover footer from `usage` × `ClaudeModel.haiku.pricing`.

## Effort
**L.**
- S — `RepoStatus` + `RepoRadarScanner` git shell-out (mirror existing Process code). ~0.5d
- S — `WorkspaceState`/`Project` fields + snapshot/restore. ~0.25d
- M — ribbon rendering across expanded folder + collapsed pill, layout/bounds/culling, hit-testing. ~1d
- S — `NSPopover` breakdown + "Pick up here" → `focusProject`/`centerOnItem`. ~0.5d
- S — `RadarSummarizer` batched Haiku call + JSON parse + caching + debounce/cadence. ~0.5d
- S — dock "Refresh Radar", context-menu "Set Project Repo…", wiring, `xcodegen generate` + build. ~0.5d

## Risks / open questions
- **One repo per project assumption.** A project can hold items from several repos. Decision: radar tracks the project's single `repoPath` (inferred or user-set); multi-repo projects show their primary only. Revisit if real usage mixes repos.
- **`@{u}` no-upstream / detached HEAD / non-repo dir** — scanner must tolerate non-zero git exit and nil out ahead/behind rather than blanking the ribbon (the `terminationStatus == 0` guard pattern at `GitObserverPanel.swift:267`).
- **Process fan-out cost.** 4 git invocations × N repos off-main; throttle with a concurrency cap and never on the draw path. Large monorepos: `status` can be slow — consider `--untracked-files=no` if it bites.
- **Ribbon real estate** on small/collapsed cards and at low zoom (folder tab text already clips). Need a min-width threshold below which the ribbon collapses to a single worst-status dot.
- **AI staleness vs git freshness:** git counts update instantly on refresh; the one-liner lags until the next batched sweep. Acceptable — show the cached line with a subtle "stale summary" affordance if `computedAt` is old.
- **PII / token budget:** dirty file *names* go to the API. Truncate to ~20 names; gate behind the same key the user already pasted. No file contents are sent.

## Acceptance criteria
- [ ] A project with an associated git repo shows a ribbon on its folder card (expanded and collapsed) with correct unpushed / behind / dirty / stale segments; zero-count segments are omitted; a fully clean repo shows a single muted check.
- [ ] A project with no repo (and no inferable child git item) draws no ribbon and behaves exactly as today.
- [ ] Git facts match ground truth for: clean repo, dirty repo, ahead-only, behind-only, detached HEAD, and a no-upstream branch (no crash, ahead/behind nil).
- [ ] Clicking/hovering the ribbon opens a popover with the breakdown + AI one-liner; **Pick up here** zooms/pans to the project and focuses its last-touched item.
- [ ] One Haiku request covers all dirty/stale repos in a sweep (verified by a single network call), returns valid per-id JSON, and is parsed into the cache; a malformed/partial response degrades to git-only without breaking the ribbon.
- [ ] With no API key, the deterministic ribbon still renders; the popover shows the git breakdown and a "no summary (add API key)" hint — no crash, no error dialog.
- [ ] Ribbon + one-liner survive quit/relaunch from the persisted `RadarCache` with no git/AI round-trip on launch; a manual **Refresh Radar** updates both.
- [ ] Repeated sweeps over unchanged repos report `usage.cacheReadInputTokens > 0` (caching verified).
- [ ] Git scans run off the main thread; canvas scrolling/zoom shows no jank with 10+ repo projects.
- [ ] New files registered via `xcodegen generate`; Debug build succeeds and mirrors to `./build/Sprawl.app`.

Relevant paths: `/Users/ramijames/_CODE/Sprawl/Sprawl/Canvas/CanvasView.swift`, `/Users/ramijames/_CODE/Sprawl/Sprawl/Canvas/CanvasViewController.swift`, `/Users/ramijames/_CODE/Sprawl/Sprawl/Model/AppModel.swift`, `/Users/ramijames/_CODE/Sprawl/Sprawl/Persistence/WorkspaceState.swift`, `/Users/ramijames/_CODE/Sprawl/Sprawl/Content/GitObserverPanel.swift`, `/Users/ramijames/_CODE/Sprawl/Sprawl/Content/ProjectVelocityPanel.swift`, `/Users/ramijames/_CODE/Sprawl/Sprawl/App/FloatingDock.swift`, `/Users/ramijames/_CODE/Sprawl/Sprawl/App/MainSplitViewController.swift`, `/Users/ramijames/_CODE/Sprawl/Sprawl/Support/Palette.swift`; new: `/Users/ramijames/_CODE/Sprawl/Sprawl/Claude/RepoRadar.swift`, `/Users/ramijames/_CODE/Sprawl/Sprawl/Claude/RadarSummarizer.swift`.


---

## Spatial Recall (⌘K)

_Phase 3 · Planned_

# Spatial Recall (⌘K) — natural-language "fly me to that panel"

## Summary
A Spotlight-style ⌘K palette where the user types a natural-language description of a panel they remember ("the terminal I ran the migration in", "the doc with the API key notes", "the browser tab on the pricing page") and Sprawl flies the camera across the 20 000×20 000 canvas to the matching `WindowView`, zooms it to fit, selects it, and pulses it. It turns the canvas's biggest weakness — losing panels in a huge spatial sprawl — into a strength, because recall is by *meaning and content*, not by remembering where you parked something.

## Phase
**Phase 3.** It sits on top of the FOUNDATION layer (ClaudeClient, ClaudeModel/ClaudeTask, CanvasTools tool seam) and on the Phase-2 `assistant` plumbing. It is the first feature that reads *live panel content* across the whole workspace and drives the camera as a Claude tool action.

## Depends on
- **FOUNDATION §1 ClaudeClient** — specifically the non-streaming `send(_:)` / `runToolLoop(...)` and the `ToolDefinition`/`ToolChoice`/`ContentBlock.toolUse` types. The client currently in the repo (`Sprawl/AI/ClaudeClient.swift`) is the *minimal* streaming-only `enum` form; Spatial Recall needs the upgraded actor with tool support. If that upgrade isn't done yet, the fallback path (forced structured-JSON over the existing `stream`) is described under Risks.
- **FOUNDATION §3 ClaudeModel / ClaudeTask** — model selection by intent.
- **FOUNDATION §2 ClaudeAuth/Settings** — no-key users get routed to the key sheet instead of a silent failure.
- **FOUNDATION §6 CanvasTools** — the shared tool runner; Spatial Recall adds one tool (`focus_panel`) here so navigation has a single code path with the future agent.
- **No dependency on the assistant panel UI (§5/§7)** — Spatial Recall is its own overlay, not a transcript. It only needs the client + tool seam.

## UX & interaction
1. **Invoke.** User presses **⌘K** anywhere (registered as a menu key equivalent, not a bare monitor — see the `⌘`` comment at `CanvasView`/`AppDelegate` for why menu equivalents claim shortcuts reliably). A borderless, centered overlay panel fades in over the main window (≈520 pt wide), dimming the canvas slightly, with a focused search field: placeholder "Find a panel…". An optional magnifier button on `FloatingDock` triggers the same action.
2. **Type + Return.** User types free text and hits Return. The field switches to a "Searching…" state with a small spinner. Esc dismisses at any time.
3. **Resolve.** The app builds a compact, deterministic workspace index (names, kinds, project, working dirs, document heads, browser URLs/titles, terminal scrollback tails) and sends it to Claude with the query. Claude calls the `focus_panel` tool with the best `item_id` plus ranked `alternatives` (or returns plain text when nothing matches).
4. **Fly.** The overlay dismisses; the camera animates (pan + zoom-to-fit) to the chosen panel via an animated version of the existing `CanvasViewController.fitItemVertically`. On arrival the panel **pulses** (a brief expanding ring in `Palette.panelBorderSelected`, 2–3 cycles), the item is selected (`AppModel.selectItem`, giving it the white outline), and its active leaf focuses.
5. **Correct.** If Claude returned `alternatives`, a thin correction strip persists for ~4 s under the toolbar: "Not it? → [Terminal 2 · ProjectX] [Doc: notes.md] [Browser: Stripe]". Clicking one flies the camera there (live preview). If there was **no confident match**, the overlay stays open and shows Claude's one-line reason ("No panel mentions a migration") plus any near-misses to click.
6. **No key.** A caught `ClaudeError.noAPIKey` opens the FOUNDATION settings sheet; the palette reopens after a key is saved.

## Files & touchpoints
New files under `Sprawl/AI/` (this repo realizes the FOUNDATION's `Sprawl/Claude/` as `Sprawl/AI/`, where `ClaudeClient.swift`/`APIKeyStore.swift` already live):
- **`Sprawl/AI/SpatialRecallController.swift`** — the ⌘K overlay. An `NSViewController` hosted in a borderless child `NSPanel` centered over `window`, reusing the child-panel pattern already proven in `CanvasView.beginEditingName` (`Sprawl/Canvas/CanvasView.swift:369–447`, the `NameEditorPanel`). Owns the search field, spinner/status, and the alternatives strip. Calls the resolver, then asks `MainSplitViewController` to fly.
- **`Sprawl/AI/WorkspaceIndex.swift`** — builds the index. Iterates `AppModel.projects` → `WorkItem`s, producing one deterministic entry per item sorted by `id`: `{ id, kind (WorkItem.Kind.symbolName-ish), project, title, frame, plus kind-specific content }`. Content comes from existing accessors — terminal `currentDirectory` (`TerminalPanel`), document `panel.model.text` head + `fileURL` (`DocumentLeaf`, see `AppModel.tabStates` at `Sprawl/Model/AppModel.swift:512–524`), browser `tabURLs`/`currentURL`/title (`BrowserPanel`), git `repoPath` (`GitObserverPanel`/`GitGraphPanel`/`ProjectVelocityPanel`). Reuses the shape of `AppModel.snapshot()` so it stays in sync as kinds are added.

Edits to existing files:
- **`Sprawl/Content/TerminalPanel.swift`** — add `func recentText(maxLines: Int = 40) -> String` that reads the SwiftTerm buffer via `terminalView.getTerminal()` (the scrollback rows) so "the terminal I ran X in" is actually matchable. This is the only genuinely new content accessor; everything else already exists.
- **`Sprawl/AI/CanvasTools.swift`** (FOUNDATION §6) — add the `focus_panel` tool to `definitions` and a `case "focus_panel"` in `run(...)`. Input schema: `{ item_id: string, reason: string, alternatives: [{ item_id: string, reason: string }] }`. The case resolves the `WorkItem` by UUID, calls `canvasVC.flyToItem(_:pulse:true)` + `model.selectItem`, and returns the `alternatives` JSON back so the overlay can render the correction strip. This is the single navigation primitive the Phase-2 agent reuses.
- **`Sprawl/Canvas/CanvasViewController.swift`** — add `func flyToItem(_ item: WorkItem, pulse: Bool)`: an *animated* sibling of `fitItemVertically` (lines 83–104). Same fit math (top inset 56 / bottom inset 96), but drives the new animated scroll-view call and triggers `window.pulse()` on arrival, then `onViewportChange?()`.
- **`Sprawl/Canvas/CanvasScrollView.swift`** — add `func flyTo(center: NSPoint, magnification: CGFloat, duration: TimeInterval = 0.45)` animating both magnification and clip origin together inside one `NSAnimationContext` group (`self.animator().magnification = …` + `contentView.animator().setBoundsOrigin(…)`), with `allowsImplicitAnimation`. Reuses the existing clamp helpers; commits a `reflectScrolledClipView` on completion. (The existing `centerOnItem`/`fitItemVertically` jump instantly; this is the "fly".)
- **`Sprawl/Windows/WindowView.swift`** — add `func pulse()`: a temporary `CALayer` ring matching the body squircle (corner radius 16, same path as `layer?.shadowPath` at line 128) animated with a `CABasicAnimation` group on `opacity` + `transform.scale` in `Palette.panelBorderSelected`, removed on completion. No persistent state.
- **`Sprawl/App/MainSplitViewController.swift`** — add `@objc func showSpatialRecall(_ sender: Any?)` that presents `SpatialRecallController` over `view.window`, builds the index from `model`, runs the resolver (`ClaudeClient` + `CanvasTools` with `tool_choice` auto, single tool), and on result calls `canvasVC.flyToItem`. It already owns both `model` and `canvasVC`, so no new plumbing.
- **`Sprawl/App/AppDelegate.swift`** — in `setupMenu()` add a "Find Panel…" item with key equivalent `"k"` (a new top-level **Go** menu, or appended to the View menu after `Fit Window to Screen` at line 236), action `#selector(MainSplitViewController.showSpatialRecall(_:))`. Routes through the responder chain like every other action.
- **`Sprawl/App/FloatingDock.swift`** *(optional)* — a magnifier button calling the same selector.

Run `xcodegen generate` after adding the new files, then build (FOUNDATION §5 step 8; quit the running app first so the post-build mirror to `./build/Sprawl.app` re-signs).

## Data & persistence
**No `WorkspaceState` schema changes.** Spatial Recall is read-only over model state and only *moves the camera* — and the viewport is already persisted (`ViewportState` via `CanvasViewController.onViewportChange` → `AppModel.onPersistableChange` → debounced save in `AppDelegate.scheduleSave`). The index is built on demand and never written to disk. Recent queries may optionally be cached in `UserDefaults` (like `snapGrid`) for an MRU list in the palette — **not** in `workspace.json`. Decisive default: don't persist queries.

## Claude usage
- **Model: Sonnet 4.6** (`ClaudeTask.interactive`), but **override the task defaults for latency**: `thinking = nil` and `OutputConfig.effort = "low"`. ⌘K is an interactive lookup; the task is shallow ranking over a structured index, so reasoning budget hurts more (latency) than it helps. Drop to **Haiku 4.5** automatically when the index is small (< ~15 panels) or the query is obviously metadata-only (matches a title/filename) — Haiku has no effort knob, so just omit it. Opus is overkill here and never used.
- **No vision, no streaming.** Use `ClaudeClient.send(_:)` (one round trip) — the answer is a single tool call, not prose to render.
- **Tool:** one tool, `focus_panel` (schema above), `tool_choice` = `{type:"auto"}` so a true "no match" comes back as text instead of a forced bogus pick.
- **System prompt (frozen, cache breakpoint 1):**
  > You are Sprawl's spatial recall. The user is looking for one panel on an infinite canvas. You are given a JSON index of every panel: id, kind, project, title, and content (terminal scrollback/cwd, document text, browser URLs/titles, git repo). Find the single panel that best matches the user's description. Call `focus_panel` with its `id`, a one-line `reason`, and up to 3 ranked `alternatives`. If nothing plausibly matches, reply in one sentence saying so — do not guess.
- **User content:** the workspace index as an early content block with **cache breakpoint 2** at its end (FOUNDATION §4), then the volatile query last. The index is emitted with entries sorted by `id` and stable key order so an unchanged workspace yields byte-identical prefixes → `cacheReadInputTokens > 0` on repeat queries in a session. Panel mutations (move/edit) legitimately invalidate the cache; that's acceptable. Cap per-panel content (e.g. ~40 terminal lines, ~1 KB doc head) to bound tokens.
- **Cost:** read `usage` off the final response × `ClaudeModel.pricing`; a typical lookup is a few-KB index → well under a cent on Sonnet, effectively free on cache reads.

## Effort
**M** (~2–3 focused days).
- Camera-fly animation (`CanvasScrollView.flyTo` + `CanvasViewController.flyToItem`) and `WindowView.pulse()` — ~0.5 day; the fit math already exists.
- `WorkspaceIndex` builder + `TerminalPanel.recentText` — ~0.5 day.
- `SpatialRecallController` overlay UI (field, spinner, alternatives strip, esc/return handling) — ~0.75 day.
- `focus_panel` tool in `CanvasTools` + resolver wiring in `MainSplitViewController` + menu/⌘K — ~0.5 day.
- Prompt/caching tuning, no-key path, polish — ~0.5 day.
Assumes the FOUNDATION ClaudeClient tool support already exists; if not, add ~0.5 day for the structured-JSON fallback.

## Risks / open questions
- **Client maturity.** The shipped `ClaudeClient` is streaming-text-only. *Mitigation / fallback:* drive a forced structured response over the existing `stream` — system-instruct "reply with ONLY JSON `{item_id, reason, alternatives}`", accumulate deltas, parse. Works today; swap to `focus_panel` tool-use once FOUNDATION §1 lands.
- **Terminal scrollback extraction.** Reading text out of SwiftTerm's `getTerminal()` buffer needs verifying (row enumeration API, alt-screen vs scrollback). If it's flaky, degrade gracefully to `currentDirectory` + title only for terminals.
- **Index size on huge workspaces.** Hundreds of panels × content could blow the prompt. *Mitigation:* hard caps per panel, and a cheap pre-filter (local substring/fuzzy match) to send only the top ~40 candidates to Claude for ranking.
- **Animated zoom performance.** `setMagnification` re-rasterizes panels (the very flicker the live-zoom transform avoids in `CanvasScrollView.zoom`). A 0.45 s animated magnification of many panels may stutter. *Open question:* animate with the layer-transform trick (commit real magnification only at the end) vs. accept a short animated `setMagnification`. Start simple; optimize only if it janks.
- **Ambiguity UX.** How aggressive should auto-fly be vs. always showing a pick list? Default: auto-fly to #1 + show alternatives strip; revisit if users report wrong jumps.
- **Privacy.** The index ships document text / terminal output to the API. Acceptable for a dev tool with a user-supplied key, but the no-key gate and a clear first-run note matter.

## Acceptance criteria
- [ ] ⌘K (and the menu item) opens a centered, focused search overlay over the canvas; Esc closes it; it works regardless of which panel had focus.
- [ ] Submitting a query with no API key opens the FOUNDATION key sheet, then resumes.
- [ ] A query that clearly names a panel's content (cwd, filename, URL, or terminal output) flies the camera to the correct `WindowView`, zooms it to fit (respecting the 56/96 insets), selects it, focuses its active leaf, and pulses it 2–3 times.
- [ ] The camera transition is animated (pan + zoom), not an instant jump.
- [ ] When the match is ambiguous, up to 3 ranked alternatives appear and clicking one flies the camera there.
- [ ] A query with no plausible match keeps the overlay open and shows a one-line "no match" reason — no bogus jump.
- [ ] The index is built from live state (a doc edited this session, a terminal's recent commands, a browser's current URL are all matchable) and excludes nothing reachable via `AppModel.projects`.
- [ ] Repeating the same query in one session shows `usage.cacheReadInputTokens > 0` (prefix cache hit).
- [ ] Navigation routes through `CanvasTools.focus_panel` → `CanvasViewController.flyToItem` (same primitive the agent will reuse); the resulting viewport change is autosaved.
- [ ] `xcodegen generate` + Debug build succeed and mirror to `./build/Sprawl.app`; with no key configured, app behavior is unchanged (no ⌘K behavior regression elsewhere).


---

## Lasso-to-Ask (Vision)

_Phase 3 · Planned_

I have enough grounding. Key findings: no marquee selection exists today (mouseDown only hits folders or clears selection); the real foundation lives in `Sprawl/AI/` and is text-only (its `ContentBlock`/request types have no image case yet); WindowView panels are subviews of the flipped CanvasView, so a region bitmap + per-panel text are both reachable from canvas coordinates.

---

## Lasso-to-Ask (vision)

### Summary
Hold ⌥ and drag a marquee across any region of the canvas; on release, Sprawl extracts the text from every panel inside the box **and** renders a bitmap screenshot of that region, then sends both as one multimodal prompt to Claude. It turns "what's going on in this corner of my workspace?" into a single gesture, letting Claude reason over the *visual arrangement* (a terminal next to a diff next to a doc) the way a human collaborator glancing at the screen would.

### Phase
**Phase 3.** Gated on vision (multimodal image content blocks) and on the `assistant` panel existing as a render target. It is the first feature that uploads a rendered bitmap, so it also introduces the screenshot-privacy gate the later agent/computer-use work will reuse.

### Depends on
- **FOUNDATION §1 `ClaudeClient`** (streaming) — reused as-is, but requires the **vision extension to FOUNDATION §1a `ContentBlock`** (a new `.image(base64:mediaType:)` case). This is the one foundation type that must grow; everything else (retry, SSE, refusal handling) is untouched. The currently-built `Sprawl/AI/ClaudeClient.swift` is text-only and would get the same image-block addition.
- **FOUNDATION §3 `ClaudeModel` / `ClaudeTask.interactive`** — model selection.
- **FOUNDATION §2 `ClaudeAuth`** — `ClaudeError.noAPIKey` routes to settings, same as every feature.
- **FOUNDATION §4 prompt caching** — extracted panel text is the cacheable prefix.
- **FOUNDATION §7 `StreamingTranscriptView`** — renders the answer.
- **FOUNDATION §5 `assistant` `WorkItem.Kind` + `AssistantPanel`** (the assistant feature) — the lasso's answer is rendered in a freshly spawned `assistant` panel. Lasso-to-Ask is essentially a *seeding gesture* for an assistant panel; if assistant ships first, this is mostly canvas + capture plumbing.
- **FOUNDATION §6 `CanvasTools`** — *conceptually* reused for the per-kind "read a panel's text" logic (the `read_panel` seam), but executed eagerly at capture time rather than via a tool round-trip.

### UX & interaction
Lives directly on `CanvasView` (the big flipped document view), not in any panel.

1. **Enter lasso.** Hold **⌥ (Option)** and press-drag on empty canvas. The modifier disambiguates from the existing gestures: plain drag on a project tab moves the project (`CanvasView.beginTabDrag`), plain drag on empty canvas does nothing/pans, and a plain click clears selection (`onClearSelection?()`, CanvasView.swift:245). A dock affordance (FloatingDock "Lasso" toggle) is an optional discoverability alias that flips the same mode without the modifier.
2. **Draw the marquee.** While dragging, `CanvasView` draws a translucent accent-stroked rectangle (Palette accent, ~12% fill) snapped to nothing (free-form, since it's a query region, not a layout op). Rect is tracked in **document/canvas coordinates** so zoom level is irrelevant.
3. **Release.** On `mouseUp`, if the rect is larger than a minimum (e.g. 40×40 pt) Sprawl: (a) enumerates `WindowView` subviews whose `frame.intersects(region)`, (b) renders the region bitmap, (c) shows a small floating **composer** anchored at the marquee's top-left.
4. **Composer.** A lightweight `NSPopover`/borderless panel containing: a **thumbnail of exactly the bitmap that will be sent** (privacy: WYSIWYG), a one-line summary ("3 panels • screenshot 1180×640"), a model picker (defaults to Sonnet), a multiline text field ("Ask about this region…"), and **Ask** (⌘↵) / **Cancel** (⎋). Leaving the field blank uses a default question.
5. **First-time consent gate.** The very first Ask (per the persisted consent flag) interrupts with a one-time sheet: "Lasso-to-Ask uploads a screenshot of the selected region and the text inside it to Anthropic's API. Panels may contain secrets (terminal output, .env files)." Buttons: **Allow & Ask** / **Cancel**. Never auto-sends; the bitmap is only built on explicit Ask.
6. **Answer.** On Ask, Sprawl spawns an **`assistant` `WorkItem`** placed just to the right of the region (reusing `AppModel.addItem(kind:.assistant,in:at:)`), seeds it with the multimodal first user turn, and streams the reply into its `StreamingTranscriptView`. The conversation continues as a normal assistant panel (follow-ups are text-only).

### Files & touchpoints
- **`Sprawl/Canvas/CanvasView.swift`** — the bulk of the work:
  - `mouseDown` (line 214): if `event.modifierFlags.contains(.option)` and the hit-test finds no folder, begin a lasso instead of `onClearSelection?()`; record `lassoStart`.
  - `mouseDragged` (line 261): when in lasso mode, update `lassoRect` and `needsDisplay = true` (don't fall through to `beginTabDrag` logic).
  - `mouseUp` (line ~289): on lasso end, validate min size and fire a new callback `var onLassoComplete: ((_ region: NSRect, _ image: Data, _ panelText: String) -> Void)?`.
  - `draw(_:)`: paint the live marquee overlay.
  - New `func captureRegion(_ rect: NSRect) -> Data?` — `bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:to:)` on `self` (the flipped CanvasView, captured at its own scale 1, independent of `CanvasScrollView.magnification`), downscaled to ≤1568px long edge, PNG/JPEG-encoded.
  - New `func panels(in rect: NSRect) -> [WorkItem]` — filter `model.workItems` by `window?.frame.intersects(rect)`.
- **`Sprawl/Canvas/CanvasViewController.swift`** — owns `onLassoComplete`: builds the prompt, presents the composer + consent gate, and on Ask calls `model.addItem(kind:.assistant, …)` then seeds the new panel. Holds the captured `Data` transiently (never stored on the model).
- **New `Sprawl/Claude/LassoCapture.swift`** — pure helper: `panelText(for items: [WorkItem]) -> String` switches on `WorkItem.Kind` and reads each panel's text via existing accessors (`DocumentPanel.text` at DocumentPanel.swift:9; TerminalPanel buffer; BrowserPanel title/URL + `evaluateJavaScript("document.body.innerText")`; GitObserver/GitGraph/ProjectVelocity rendered strings). This is the §6 `read_panel` logic, centralized. Also assembles the `[ContentBlock]` user turn (text block + image block) and the system prompt.
- **New `Sprawl/Claude/LassoComposer.swift`** — the popover `NSViewController` (thumbnail + text field + model picker + Ask/Cancel).
- **`Sprawl/Claude/ClaudeTypes.swift`** (FOUNDATION §1a) — add `case image(base64: String, mediaType: String)` to `ContentBlock` with `Codable` emitting `{"type":"image","source":{"type":"base64","media_type":…,"data":…}}`. (Mirror into `Sprawl/AI/ClaudeClient.swift`'s request encoding until the foundation file lands.)
- **`Sprawl/Claude/AssistantPanel.swift`** (FOUNDATION §5) — add a seed entry point, e.g. `func seed(initialUserTurn: [ContentBlock])`, that injects the multimodal first message and kicks the stream. No new Kind is introduced by this feature; it rides the `assistant` kind.
- **`Sprawl/App/FloatingDock.swift`** (optional) — `var onLassoMode: (() -> Void)?` + a dock button, wired in `MainSplitViewController.installDock()`, for discoverability. Pure convenience; the ⌥-drag is the primary path.
- **No new switch-storm.** Because the answer is an `assistant` panel, none of the AppModel `installItem`/`snapshot`/`restore` switches change for *this* feature beyond what the assistant feature already added.

### Data & persistence
- **`Sprawl/Persistence/WorkspaceState.swift`** — add one top-level `var visionConsentGiven: Bool` (default false) for the one-time screenshot-upload consent. (Acceptable alternative: `UserDefaults`, since consent is app-global rather than per-workspace — but storing it in `WorkspaceState` keeps with the project's single-source persistence model.)
- **The screenshot bitmap and extracted text are NOT persisted.** They live only in memory during composer → request, then are dropped. `workspace.json` must never contain image bytes (privacy + size). The spawned assistant panel persists exactly like any other assistant item; its transcript persistence (if any) is owned by the assistant feature, not here.
- No change to per-item `ItemState` for the lasso itself (the marquee is transient).

### Claude usage
- **Model:** **Sonnet 4.6** (`ClaudeTask.interactive`) by default — vision-capable, balanced cost, the right tier for "look at this and explain." Composer lets the user bump to **Opus 4.8** for a hard region (deep diff reasoning). Haiku is offered but not default (vision works, but this task wants reasoning).
- **Vision:** one base64 image block in the first user turn. Per Anthropic vision guidance, downscale so the long edge ≤ ~1568px and the image stays ≤ ~1.15 MP (image tokens ≈ (w×h)/750); enforce the 5MB/base64 limit. JPEG for photographic-dense regions, PNG for crisp text.
- **Caching (§4):** the extracted panel text block goes **first** with a `cacheControl` breakpoint — re-asking about the same region (same panel contents) gets a cache read. The **image block and the user's question go after the breakpoint** (volatile: each capture is unique, so caching the image yields nothing). System persona is the frozen breakpoint-1 prefix.
- **Tools:** none in v1 (read-only "ask"). The seam to add later is `spawn_panel`/`open_file` (§6) so Claude could answer *and* act ("open the file this error points to").
- **Prompt sketch:**
  - *System (cached):* "You are Sprawl's spatial assistant. The user has lassoed a region of an infinite dev canvas. You receive a screenshot of that region plus the text extracted from the panels inside it. Panels are arranged spatially; their relative position is meaningful. Answer about what's shown; be concise; reference panels by their visible titles."
  - *User turn:* `[ .text("<panels in region, by title:>\n## Terminal 'build'\n<buffer>\n## Document 'notes.md'\n<text>\n…")  (cache breakpoint here), .image(<region screenshot>), .text("<user question, or default: 'What is happening in this region? Anything I should fix?'>") ]`

### Effort
**L.** Breakdown:
- Marquee gesture (mode entry, drag, draw overlay) without regressing pan / tab-drag / select — **M**.
- Region bitmap capture + downscale + per-kind text extraction (`LassoCapture`) — **M**.
- Vision `ContentBlock.image` extension + encoder — **S**.
- Composer popover + consent gate + seeding the assistant panel — **M**.
- Persistence flag, dock affordance, polish — **S**.

### Risks / open questions
- **WKWebView capture is the big one.** `cacheDisplay`/`bitmapImageRepForCachingDisplay` frequently render **blank/white** for WebKit-backed views (`BrowserPanel`, and possibly the terminal if it's layer-hosted out of process). Mitigation: composite browser panels in via `WKWebView.takeSnapshot(with:)` per-panel, or accept a blank web rect and rely on the extracted `innerText`. Needs a capture-fidelity spike before committing.
- **Magnification coordinate mapping.** The marquee is in document coordinates; capturing the documentView at scale 1 avoids zoom blur, but verify the rect maps correctly when the canvas is zoomed (`CanvasScrollView.magnification`).
- **Privacy / secret leakage.** A region can include a terminal showing API keys or an open `.env` document. Consent gate + WYSIWYG thumbnail are the controls; open question whether to add a lightweight redaction (drag-to-blur in the composer) in v1 or defer.
- **Image size on a 20000×20000 canvas** — a zoomed-out marquee could be enormous; must clamp/downscale before encode or token cost explodes.
- **Gesture discoverability** — is ⌥-drag obvious enough, or is the dock toggle mandatory? Lean toward shipping both.
- **Empty/blank-region selection** — composer should no-op (or just send the screenshot with "no panels in region").

### Acceptance criteria
- [ ] ⌥-drag on empty canvas draws a live marquee and does **not** trigger pan, project-tab drag, or selection-clear.
- [ ] Releasing a marquee ≥ min size opens the composer anchored at the region; smaller drags are discarded silently.
- [ ] Composer thumbnail shows **exactly** the bitmap that will be uploaded (no hidden capture).
- [ ] First Ask shows the one-time consent sheet; declining sends nothing; accepting persists `visionConsentGiven = true` so it isn't shown again.
- [ ] On Ask, an `assistant` panel spawns adjacent to the region and **streams** a reply that demonstrably references both the screenshot and the panel text.
- [ ] The request contains exactly one image block (≤1568px long edge, ≤5MB) and an extracted-text block carrying a `cache_control` breakpoint; a repeat Ask on the unchanged region reports `cacheReadInputTokens > 0`.
- [ ] No image bytes or extracted text appear in `workspace.json`.
- [ ] Key-less user Asking is routed to the §2 settings presenter (via `ClaudeError.noAPIKey`), not a silent failure.
- [ ] Capturing a region containing a `BrowserPanel` either renders its content or degrades gracefully (innerText still included, no crash, no all-white panel passed off as content without note).
- [ ] Builds clean after `xcodegen generate` (new files under `Sprawl/Claude/`) per FOUNDATION §5 step 8.


---