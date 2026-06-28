# Milestone 4 — Document Editor (CodeEditSourceEditor)
> 2026-06-28

## Context

Milestones 1–3 are done (canvas + pan/zoom, window panels, translucent project sidebar, live
SwiftTerm terminals). The document panels are still empty stubs. This milestone makes
**document panels real editors**: open text/code files, edit with syntax highlighting + line
numbers, and save. The user chose **CodeEditSourceEditor** (pinned `0.15.2`, already added to
`project.yml` and resolved).

## Verified API (0.15.2)

The SwiftUI view is `SourceEditor` (a `NSViewControllerRepresentable`), not
`CodeEditSourceEditor`:

```swift
SourceEditor(
    _ text: Binding<String>,
    language: CodeLanguage,                 // CodeLanguage.detectLanguageFrom(url:) / .default
    configuration: SourceEditorConfiguration(
        appearance: .init(theme: EditorTheme, font: NSFont, wrapLines: Bool, tabWidth: Int)
    ),
    state: Binding<SourceEditorState>       // SourceEditorState() default
)
```

`EditorTheme` has **no built-in default** — must be fully constructed (16 attributes). I'll add
a `EditorTheme.endlessDark` static matching the app's dark canvas.

## Implementation

New file `EndlessTerminal/Content/DocumentPanel.swift`:
- `final class DocumentModel: ObservableObject` — `@Published var text`, `var fileURL: URL?`,
  `var language: CodeLanguage`. On init with a URL: load via `String(contentsOf:encoding:.utf8)`
  and `CodeLanguage.detectLanguageFrom(url:)`; else empty + `.default`. `save()` writes back;
  `saveAs(url:)` sets URL, re-detects language, saves.
- `struct DocumentEditorView: View` — `@ObservedObject model`, `@State editorState`, renders
  `SourceEditor($model.text, language: model.language, configuration:…, state: $editorState)`
  with `EditorTheme.endlessDark` + `NSFont.monospacedSystemFont(ofSize: 12)`.
- `final class DocumentPanel: NSObject` — owns `DocumentModel` + `NSHostingView(rootView:)`;
  `attach(to: WindowView)` calls `window.setContent(hostingView)`; `save()` passthrough.
- `extension EditorTheme { static let endlessDark }`.

Wire-up (reuse existing patterns from milestone 3's terminal path):
- `WorkItem` (`Model/AppModel.swift`): add `var document: DocumentPanel?` (strong, mirrors
  existing `var terminal: TerminalPanel?`).
- `AppModel.addItem(kind:url:)`: add optional `url: URL? = nil`. In the `.document` case (today
  a no-op `break`), create `DocumentPanel(fileURL: url)`, `attach(to: window)`, set
  `item.document`, name = `url?.lastPathComponent ?? "Document N"`, set window title.
- Track active document for Save: add `weak var activeDocumentItem: WorkItem?` to `AppModel`;
  set it on document create, on sidebar select of a document, and by wrapping the window's
  existing `onFocus` (set in `CanvasView.addWindow`) so clicking a doc updates it.
- Menu (`App/AppDelegate.swift`) + responder actions on `MainSplitViewController`:
  - **Open… ⌘O** → `NSOpenPanel` (files only) → `model.addItem(kind: .document, url:)`.
  - **Save ⌘S** → `activeDocumentItem?.document`: if `fileURL == nil` show `NSSavePanel` then
    `saveAs` + update sidebar/title; else `save()`.
  - Keep New Document (⌘N) creating an empty untitled editor.
- Sidebar "+" menu (`Sidebar/SidebarViewController.swift`): add an "Open File…" item that calls
  a new `onOpenDocument` closure (wired in `MainSplitViewController` to the same Open flow).

Containment: only `DocumentPanel.swift` imports `CodeEditSourceEditor`/`CodeEditLanguages`/
`SwiftUI` (same isolation approach used for SwiftTerm in `TerminalPanel.swift`).

## Verification

1. `xcodegen generate` then `xcodebuild … build` (first build compiles tree-sitter grammars —
   expect a longer build).
2. Run the app. **+ → New Document**: empty editor panel appears with dark theme + line numbers;
   type code and confirm syntax highlighting once a language is known (e.g. after Save as `.swift`).
3. **⌘O / sidebar Open File…**: pick a source file; it opens in a panel with correct
   highlighting and filename as the title + sidebar row.
4. Edit, **⌘S**, reopen the file in a new panel → changes persisted. New untitled doc + ⌘S →
   NSSavePanel, then saves.
5. Resize/zoom the editor panel; confirm it reflows and stays interactive.
