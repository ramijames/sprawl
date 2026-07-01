import AppKit
import SwiftUI
import CodeEditSourceEditor
import CodeEditTextView

/// Bridges the editor's completion UI to a `LanguageService`: answers the editor's async completion
/// requests with LSP results and applies the chosen item by replacing the typed identifier prefix.
/// The class itself is non-isolated (so `CodeFileModel` can own it) — only the delegate methods,
/// which the editor calls on the main actor, are `@MainActor`.
final class LSPCompletionProvider: CodeSuggestionDelegate {
    private let currentURL: () -> URL?
    private let serviceProvider: () -> LanguageService?

    init(currentURL: @escaping () -> URL?, serviceProvider: @escaping () -> LanguageService?) {
        self.currentURL = currentURL
        self.serviceProvider = serviceProvider
    }

    func completionTriggerCharacters() -> Set<String> { ["."] }

    func completionSuggestionsRequested(
        textView: TextViewController, cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        guard let service = serviceProvider(), let url = currentURL() else { return nil }
        let items = await service.completions(url, line: max(0, cursorPosition.start.line - 1),
                                              character: max(0, cursorPosition.start.column - 1))
        guard !items.isEmpty else { return nil }
        return (cursorPosition, items.map { LSPEntry(completion: $0) })
    }

    func completionOnCursorMove(textView: TextViewController, cursorPosition: CursorPosition) -> [CodeSuggestionEntry]? {
        nil   // let the editor re-request as the user types
    }

    func completionWindowApplyCompletion(item: CodeSuggestionEntry, textView: TextViewController,
                                         cursorPosition: CursorPosition?) {
        guard let entry = item as? LSPEntry,
              let tv = textView.textView,
              let sm = tv.selectionManager,
              let caret = sm.textSelections.first?.range else { return }
        // Replace the identifier already typed before the caret with the completion's insert text.
        let text = tv.string as NSString
        var start = caret.location
        while start > 0, Self.isIdentifierChar(text.character(at: start - 1)) { start -= 1 }
        tv.replaceCharacters(in: NSRange(location: start, length: caret.location - start),
                             with: entry.completion.insertText)
    }

    private static func isIdentifierChar(_ c: unichar) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95   // A-Z a-z 0-9 _
    }
}

/// Bridges the editor's go-to-definition to a `LanguageService`: resolves the symbol under a range to
/// a target file + position, and opens it via `openFile` (cross-file navigation).
final class LSPDefinitionProvider: JumpToDefinitionDelegate {
    private let currentURL: () -> URL?
    private let serviceProvider: () -> LanguageService?
    private let openFile: (URL, Int) -> Void

    init(currentURL: @escaping () -> URL?, serviceProvider: @escaping () -> LanguageService?,
         openFile: @escaping (URL, Int) -> Void) {
        self.currentURL = currentURL
        self.serviceProvider = serviceProvider
        self.openFile = openFile
    }

    func queryLinks(forRange range: NSRange, textView: TextViewController) async -> [JumpToDefinitionLink]? {
        guard let service = serviceProvider(), let url = currentURL(),
              let tv = textView.textView else { return nil }
        let pos = LSP.offset((tv.string as NSString), to: range.location)
        guard let def = await service.definition(url, line: pos.line, character: pos.character) else { return nil }
        return [JumpToDefinitionLink(
            url: def.url,
            targetRange: CursorPosition(line: def.line + 1, column: def.character + 1),
            typeName: def.url.lastPathComponent, sourcePreview: "", documentation: nil)]
    }

    func openLink(link: JumpToDefinitionLink) {
        guard let url = link.url else { return }
        openFile(url, link.targetRange.start.line)
    }
}

/// Captures the editor's `TextViewController` once it's built (per file) so the panel can reach the
/// text view for hover (point → offset mapping). Rebuilt per file via `.id`.
final class ControllerCoordinator: TextViewCoordinator {
    private let onReady: (TextViewController) -> Void
    init(onReady: @escaping (TextViewController) -> Void) { self.onReady = onReady }
    func prepareCoordinator(controller: TextViewController) { onReady(controller) }
}

/// Position helpers between editor UTF-16 offsets and LSP 0-based line/character.
enum LSP {
    static func offset(_ text: NSString, to offset: Int) -> (line: Int, character: Int) {
        var line = 0, lineStart = 0, i = 0
        let end = min(offset, text.length)
        while i < end { if text.character(at: i) == 10 { line += 1; lineStart = i + 1 }; i += 1 }   // \n
        return (line, offset - lineStart)
    }

    /// UTF-16 offset for an LSP (line, character) position within `text`.
    static func offset(in text: NSString, line: Int, character: Int) -> Int {
        var currentLine = 0, i = 0
        while currentLine < line && i < text.length { if text.character(at: i) == 10 { currentLine += 1 }; i += 1 }
        return min(text.length, i + character)
    }
}

/// A completion item adapted to the editor's `CodeSuggestionEntry` protocol.
struct LSPEntry: CodeSuggestionEntry {
    let completion: LanguageService.Completion
    var label: String { completion.label }
    var detail: String? { completion.detail }
    var documentation: String? { nil }
    var pathComponents: [String]? { nil }
    var targetPosition: CursorPosition? { nil }
    var sourcePreview: String? { nil }
    var image: Image { Image(systemName: "chevron.left.forwardslash.chevron.right") }
    var imageColor: Color { .secondary }
    var deprecated: Bool { false }
}
