# Persistent Workspace State
> 2026-06-28

## Context

Sprawl currently builds all state in memory and starts fresh every launch
(`MainSplitViewController.viewDidLoad` always creates "Project 1"). The user wants a
**persistent workspace**: closing the window and reopening it should restore *exactly the same
state* — OS window position/size, projects and their contents, each panel's position/size on
the canvas, and the canvas zoom/scroll position.

The original architecture plan already scoped this (milestone 6: "Codable → JSON in Application
Support; terminals relaunch at saved cwd"). This plan implements that.

**Decisions (confirmed with user):**
- **Terminals** relaunch a fresh login shell at each terminal's **last working directory**
  (live process/scrollback can't be serialized; panel position/size/title return).
- **Save timing: continuous autosave** — debounced writes on every structural change, panel
  drag/resize, z-order change, document edit, terminal `cwd` change, and canvas pan/zoom — plus
  a final save on quit. Most crash-resilient.

What AppKit already persists (keep, don't reinvent): the NSWindow frame
(`window.setFrameAutosaveName("MainWindow")`) and the sidebar split width
(`splitView.autosaveName = "MainSplit"`). The plan ensures restore logic does **not** clobber
these (today `viewDidLoad` force-sets the divider to 260 every launch — that must become
first-launch-only).

## Approach

A `Codable` `WorkspaceState` snapshot is written to `~/Library/Application Support/Sprawl/
workspace.json` and read back on launch. `AppModel` gains `snapshot()`/`restore(_:)`. A shared
`installItem(...)` helper (refactored out of `addItem`) builds panels at explicit frames so the
same wiring serves both new items and restored ones. Continuous autosave is driven by an
`onPersistableChange` callback on `AppModel` that fans in from canvas/panel/viewport changes and
is debounced in `AppDelegate`.

### New files

- **`Sprawl/Persistence/WorkspaceState.swift`** *(already created)* — `Codable` structs:
  `WorkspaceState { projects:[ProjectState], currentProjectID:UUID? }`,
  `ProjectState { id, name, items:[ItemState], magnification, scrollOrigin, hasViewport }`,
  `ItemState { name, kind(.terminal/.document), frame, filePath?, documentText?, workingDirectory? }`.
  (`CGRect`/`CGPoint`/`CGFloat` are `Codable`.)
- **`Sprawl/Persistence/WorkspaceStore.swift`** — resolves the Application Support dir (creates
  `Sprawl/`), `load() -> WorkspaceState?` and `save(_:)` (pretty-printed JSON, atomic write).

### Modified files

- **`Model/AppModel.swift`** — core of the change:
  - `Project`: add injectable `id` (`init(name:id:)`) plus `magnification`, `scrollOrigin`,
    `hasViewport` for per-project viewport memory.
  - Add `var onPersistableChange: (() -> Void)?`.
  - Refactor `addItem(kind:url:)`'s body into a private
    `installItem(in:kind:name:frame:documentURL:documentText:terminalDirectory:focus:)` that
    creates the window (via `canvas.addWindow`), wires `onClose`/`onFocus` exactly as today,
    builds the terminal/document panel, and appends to `project.items`. `addItem` calls it with
    `frame:nil, focus:true`; restore calls it with saved frames and `focus:false`.
  - `snapshot() -> WorkspaceState`: per project, order items by their window's index in
    `canvas.subviews` (back-to-front z-order); pull frame from `item.window?.frame`, document
    text/path from `item.document?.model`, cwd from `item.terminal?.currentDirectory`; include
    `currentProject?.id` and viewport fields.
  - `restore(_:)`: rebuild `projects` (with persisted ids + viewport), `installItem` each item,
    set `currentProject` by id.
  - In `addProject` and `restore`, set `project.canvas.onLayoutChange = { onPersistableChange }`;
    in `installItem`, set the document's `onTextChange` and terminal's `onDirectoryChange` to
    fire `onPersistableChange`.

- **`Canvas/CanvasView.swift`** — `addWindow(title:frame:size:)` accepts an optional explicit
  `frame` (falls back to today's cascade `spawnOrigin`). Add `var onLayoutChange: (() -> Void)?`
  fired on add, `bringToFront` (z-order/raise), window `onGeometryChange` (move/resize), and
  close, so layout edits trigger autosave.

- **`Content/TerminalPanel.swift`** — `init(startDirectory: String? = nil)` (spawn the shell in
  that dir instead of always `$HOME`); track `var currentDirectory: String?` from the existing
  `hostCurrentDirectoryUpdate` delegate callback; add `var onDirectoryChange: (() -> Void)?`.

- **`Content/DocumentPanel.swift`** — `DocumentModel.init(fileURL:initialText:)` (use
  `initialText` when present to restore exact unsaved text instead of re-reading disk; still
  detect language from the URL). `DocumentPanel.init(fileURL:initialText:)` and a
  `var onTextChange: (() -> Void)?` driven by a Combine sink on `model.$text` (`import Combine`,
  store the `AnyCancellable`).

- **`Canvas/CanvasViewController.swift`** — track `displayedProject`; in `showCurrentProject()`
  capture the outgoing project's viewport then restore the incoming project's
  (`magnification` + `contentView.bounds.origin`) or center when `!hasViewport`. Add
  `captureCurrentViewport()` (flush live viewport into `displayedProject` before snapshot) and
  `var onViewportChange: (() -> Void)?`, fired from `contentView` bounds-changed notifications
  (set `postsBoundsChangedNotifications = true`), `didEndLiveMagnify`, and the zoom methods.

- **`App/MainSplitViewController.swift`** — `viewDidLoad`: compute `isFresh =
  model.projects.isEmpty`; only `addProject("Project 1")` and only force
  `setPosition(260, ofDividerAt:0)` when `isFresh` (so a restored split width survives). Wire
  `canvasVC.onViewportChange = { model.onPersistableChange?() }`. Add `captureViewport()`
  passthrough to `canvasVC.captureCurrentViewport()`.

- **`App/MainWindowController.swift`** — accept an injected `AppModel` (`init(model:)`) instead
  of creating its own. After setting the frame autosave name, also call
  `window.setFrameUsingName("MainWindow")` for reliable restore (no-op on first launch, so
  `center()` still applies). Add `prepareForSnapshot()` → `splitViewController.captureViewport()`.

- **`App/AppDelegate.swift`** — own `let model = AppModel()` and `let store = WorkspaceStore()`.
  In `applicationDidFinishLaunching`, `if let s = store.load() { model.restore(s) }` **before**
  creating `MainWindowController(model:)`. Set `model.onPersistableChange` to a **debounced**
  (~0.5s `DispatchWorkItem`) save that calls `mainWindowController?.prepareForSnapshot()` then
  `store.save(model.snapshot())`. Add `applicationWillTerminate` → same flush + immediate save.

### Ordering note
Restore happens before the window/VC exist, so `onModelChange`/`onPersistableChange` are still
`nil` during `restore` (no premature saves); `viewDidLoad` then drives the first
`showCurrentProject()` + sidebar reload, and `restoreViewport` runs via `DispatchQueue.main.async`
after layout.

## Verification

1. `xcodegen generate` (picks up the new `Persistence/` files), then
   `xcodebuild -project Sprawl.xcodeproj -scheme Sprawl build`, then run.
2. Create a 2nd project; add terminals + documents; in a terminal `cd` somewhere; drag/resize
   panels; pan and zoom the canvas; type unsaved text in a document; resize/move the OS window.
3. **Quit (⌘Q) and relaunch.** Confirm: same OS window frame + sidebar width; both projects and
   all panels present at the same positions/sizes and z-order; current project + canvas
   zoom/scroll identical; documents show the same (incl. unsaved) text; terminals reopen with a
   fresh shell whose `pwd` is the directory left off in.
4. Force-quit mid-session, relaunch → most recent debounced state restores (validates continuous
   autosave, not just quit-save).
5. Confirm `~/Library/Application Support/Sprawl/workspace.json` exists and is valid JSON.
