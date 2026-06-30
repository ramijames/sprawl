import AppKit
import SwiftUI
import Combine
import CodeEditSourceEditor
import CodeEditLanguages

/// Backing store for a document editor: its text, file location, and detected language.
final class DocumentModel: ObservableObject {
    @Published var text: String
    /// Soft-wrap long lines to the editor width. On by default; toggled from the functions bar.
    @Published var wrapLines: Bool = true
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

    /// Replace the editor's contents with the file at `url` (Open loads in the same window).
    func open(url: URL) {
        fileURL = url
        language = CodeLanguage.detectLanguageFrom(url: url)
        text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

/// SwiftUI wrapper around CodeEditSourceEditor's `SourceEditor` view.
struct DocumentEditorView: View {
    @ObservedObject var model: DocumentModel
    @State private var editorState = SourceEditorState()

    var body: some View {
        SourceEditor(
            $model.text,
            language: .default,   // plain text for now — no syntax highlighting
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: .endlessDark,
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    wrapLines: model.wrapLines,
                    tabWidth: 4),
                peripherals: .init(showGutter: false, showMinimap: false)   // no line numbers
            ),
            state: $editorState)
    }
}

/// Owns a document editor and hosts it inside a window panel. The only file (besides this one)
/// that touches CodeEditSourceEditor types.
final class DocumentPanel: NSObject {
    let model: DocumentModel
    private let hostingView: NSHostingView<DocumentEditorView>
    private let container = NSView()
    private let editorClip = NSView()
    private var textObserver: AnyCancellable?

    /// Soft-wrap state (mirrored from the model); toggled from the options bar.
    var wrapLines: Bool { model.wrapLines }
    func toggleWrap() { model.wrapLines.toggle() }

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
        buildUI()
    }

    /// The editor (functions bar + editor), for hosting inside a window panel or tabbed container.
    var contentView: NSView { container }

    func attach(to window: WindowView) {
        window.setContent(container)
    }

    func save() {
        model.save()
    }

    private func buildUI() {
        container.wantsLayer = true
        container.layer?.backgroundColor = Palette.editorBackground.cgColor

        // Clip the editor to a rounded rect so overscrolled content (the gutter + its background)
        // can't spill past the window's rounded corners when you scroll too far. (Open / Save / Wrap
        // controls now live in the floating options bar instead of an in-panel functions bar.)
        editorClip.wantsLayer = true
        editorClip.layer?.masksToBounds = true
        editorClip.layer?.cornerRadius = 10
        editorClip.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]   // bottom corners only
        editorClip.translatesAutoresizingMaskIntoConstraints = false

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        editorClip.addSubview(hostingView)
        container.addSubview(editorClip)

        NSLayoutConstraint.activate([
            editorClip.topAnchor.constraint(equalTo: container.topAnchor),
            editorClip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            editorClip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            editorClip.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            hostingView.topAnchor.constraint(equalTo: editorClip.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: editorClip.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: editorClip.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: editorClip.bottomAnchor),
        ])
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
