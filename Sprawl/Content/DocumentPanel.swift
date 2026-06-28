import AppKit
import SwiftUI
import Combine
import CodeEditSourceEditor
import CodeEditLanguages

/// Backing store for a document editor: its text, file location, and detected language.
final class DocumentModel: ObservableObject {
    @Published var text: String
    var fileURL: URL?
    var language: CodeLanguage

    /// `initialText`, when provided, seeds the editor with restored (possibly unsaved) content
    /// instead of re-reading the file from disk — preserving exact in-memory state on relaunch.
    init(fileURL: URL?, initialText: String? = nil) {
        self.fileURL = fileURL
        if let initialText {
            text = initialText
            language = fileURL.map { CodeLanguage.detectLanguageFrom(url: $0) } ?? .default
        } else if let url = fileURL, let contents = try? String(contentsOf: url, encoding: .utf8) {
            text = contents
            language = CodeLanguage.detectLanguageFrom(url: url)
        } else {
            text = ""
            language = .default
        }
    }

    func save() {
        guard let url = fileURL else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func saveAs(url: URL) {
        fileURL = url
        language = CodeLanguage.detectLanguageFrom(url: url)
        save()
    }
}

/// SwiftUI wrapper around CodeEditSourceEditor's `SourceEditor` view.
struct DocumentEditorView: View {
    @ObservedObject var model: DocumentModel
    @State private var editorState = SourceEditorState()

    var body: some View {
        SourceEditor(
            $model.text,
            language: model.language,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: .endlessDark,
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    wrapLines: false,
                    tabWidth: 4)
            ),
            state: $editorState)
    }
}

/// Owns a document editor and hosts it inside a window panel. The only file (besides this one)
/// that touches CodeEditSourceEditor types.
final class DocumentPanel: NSObject {
    let model: DocumentModel
    private let hostingView: NSHostingView<DocumentEditorView>
    private var textObserver: AnyCancellable?

    /// The editor text changed — request an autosave of the workspace snapshot.
    var onTextChange: (() -> Void)? {
        didSet {
            textObserver = model.$text
                .dropFirst()   // ignore the initial value emitted on subscribe
                .sink { [weak self] _ in self?.onTextChange?() }
        }
    }

    init(fileURL: URL?, initialText: String? = nil) {
        model = DocumentModel(fileURL: fileURL, initialText: initialText)
        hostingView = NSHostingView(rootView: DocumentEditorView(model: model))
        super.init()
    }

    func attach(to window: WindowView) {
        window.setContent(hostingView)
    }

    func save() {
        model.save()
    }
}

extension EditorTheme {
    /// Dark theme matching the app's canvas.
    static let endlessDark = EditorTheme(
        text: .init(color: NSColor(calibratedWhite: 0.86, alpha: 1)),
        insertionPoint: NSColor(calibratedWhite: 0.86, alpha: 1),
        invisibles: .init(color: NSColor(calibratedWhite: 0.35, alpha: 1)),
        background: Palette.editorBackground,
        lineHighlight: NSColor(calibratedWhite: 0.19, alpha: 1),
        selection: NSColor(calibratedRed: 0.26, green: 0.36, blue: 0.52, alpha: 1),
        keywords: .init(color: NSColor(calibratedRed: 0.80, green: 0.47, blue: 0.86, alpha: 1), bold: true),
        commands: .init(color: NSColor(calibratedRed: 0.60, green: 0.80, blue: 0.95, alpha: 1)),
        types: .init(color: NSColor(calibratedRed: 0.40, green: 0.78, blue: 0.78, alpha: 1)),
        attributes: .init(color: NSColor(calibratedRed: 0.60, green: 0.80, blue: 0.95, alpha: 1)),
        variables: .init(color: NSColor(calibratedWhite: 0.86, alpha: 1)),
        values: .init(color: NSColor(calibratedRed: 0.95, green: 0.62, blue: 0.40, alpha: 1)),
        numbers: .init(color: NSColor(calibratedRed: 0.95, green: 0.62, blue: 0.40, alpha: 1)),
        strings: .init(color: NSColor(calibratedRed: 0.60, green: 0.85, blue: 0.45, alpha: 1)),
        characters: .init(color: NSColor(calibratedRed: 0.60, green: 0.85, blue: 0.45, alpha: 1)),
        comments: .init(color: NSColor(calibratedWhite: 0.45, alpha: 1), italic: true))
}
