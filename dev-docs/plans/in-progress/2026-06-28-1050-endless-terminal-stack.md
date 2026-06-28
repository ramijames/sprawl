# Endless Terminal — Tech Stack & Architecture Plan
> 2026-06-28

## Context

Greenfield project (empty `/Users/ramijames/_CODE/endless-terminal`). The goal is a
**canvas-based developer environment for macOS**: an infinite, zoomable/pannable surface on
which you place freely draggable & resizable "windows" that host **live terminals** and
**text/code editors**, organized into multiple switchable work canvases.

**Hard constraint that drives the stack:** "open and place terminals" requires real local
shells (PTY access), so this must be a native app, not a browser. User decisions:

- **Native, no JS wrapper** (no Electron/Tauri).
- **Swift / macOS-only**, speed is a priority.
- User is already comfortable in Swift / AppKit / SwiftUI.

The key realization: AppKit's `NSScrollView` already provides GPU-composited pan **and**
magnification (zoom) for an arbitrarily large document view, and child `NSView`s — including
SwiftTerm and the editor — stay fully live and interactive while scaled. That removes the
single biggest piece of custom work and makes Swift/AppKit the fastest path to a polished,
fast result.

## Recommended stack

| Concern            | Choice | Notes |
|--------------------|--------|-------|
| Language / UI      | **Swift + AppKit** (SwiftUI only for incidental chrome) | AppKit needed to host NSView-based terminal/editor and to control hit-testing/perf. |
| Canvas (zoom/pan)  | **`NSScrollView`** with `allowsMagnification` | Native pinch-zoom + pan, Core Animation composited. Add ⌘+/⌘- and zoom-at-cursor. |
| Window panels      | Custom `NSView` ("WindowView") | Title bar drag, edge/corner resize, z-order on click. |
| Terminal           | **SwiftTerm** (`LocalProcessTerminalView`) | github.com/migueldeicaza/SwiftTerm — PTY + xterm emulation + ready AppKit view. |
| Text/code editor   | **CodeEditSourceEditor** (tree-sitter highlighting) | github.com/CodeEditApp/CodeEditSourceEditor. Fallback: `STTextView` for plain text. |
| Build / deps       | **Xcode + Swift Package Manager** | All deps are SwiftPM packages. |
| Persistence        | `Codable` → JSON in Application Support | Save canvas layouts; terminals relaunch (restore cwd). |
| Min target         | **macOS 14 (Sonoma)** | Required by current CodeEditSourceEditor / TextKit 2; lower to 13 if dropping that editor. |

## Architecture

- **Canvas surface** — `CanvasScrollView: NSScrollView` (`allowsMagnification = true`,
  `minMagnification ≈ 0.1`, `maxMagnification ≈ 4.0`). Document view = `CanvasView: NSView`
  (large bounds, `wantsLayer = true`, optional dotted-grid background drawn cheaply via a
  tiled `CALayer`/pattern). Pinch-zoom is free; add ⌘+/− and scroll-wheel-with-modifier,
  centering with `setMagnification(_:centeredAt:)`.
- **Window panels** — `WindowView: NSView` with a title bar (drag to move via
  mouseDown/Dragged on `frame.origin`), close button, and corner/edge resize handles. Bring
  to front on click by reordering subviews. Content area swaps in either a terminal or an
  editor. **Drag/resize math must convert through view coordinates** (`convert(_:from:)`) so
  it stays correct under magnification.
- **Terminals** — embed `LocalProcessTerminalView`; `startProcess()` spawning the login shell
  (`$SHELL`, e.g. `/bin/zsh -l`) with the right env and cwd. Forward panel resizes to the
  terminal so cols/rows update.
- **Editors** — `CodeEditSourceEditor` view in a panel. Open via `NSOpenPanel`; load with
  `String(contentsOf:)`, track path + dirty state, save back to disk. Use `STTextView` if a
  lighter plain-text editor is preferred.
- **Multiple canvases** — model `AppModel → [Canvas] → [WindowItem]`. A tab/sidebar lists
  canvases; switching swaps `scrollView.documentView` to that canvas's `CanvasView`. **Keep
  each canvas's view hierarchy alive (hide, don't destroy) so terminal shells survive a
  canvas switch.** Each canvas remembers its own magnification + scroll offset.
- **Persistence** — encode each `WindowItem` (type, frame, editor file path, terminal cwd)
  to JSON in `~/Library/Application Support/EndlessTerminal/`. Restore layout on launch;
  terminals relaunch fresh (optionally `cd` to saved cwd).

## Performance notes (speed is a priority)

- `NSScrollView` magnification + layer-backed views = GPU-composited zoom of many panels.
- Set `wantsLayer = true` on canvas and panels; avoid heavy `draw(_:)` (tiled layer for grid).
- Each terminal runs its own shell process — fine; optionally pause off-screen terminal
  rendering as a later optimization.

## Build milestones

1. **Scaffold** — Xcode app project; add SwiftPM deps (SwiftTerm, CodeEditSourceEditor);
   empty `NSScrollView`+`CanvasView` with working pan/zoom and a grid background.
2. **Window system** — `WindowView` with drag, resize, close, z-order; a "+" to create empty
   panels at the viewport center.
3. **Terminals** — terminal-type panel hosting `LocalProcessTerminalView` spawning `$SHELL`.
4. **Editors** — editor-type panel; open file via `NSOpenPanel`, edit, save.
5. **Multiple canvases** — canvas model + tab/sidebar switching; preserve live sessions.
6. **Persistence** — Codable save/restore of layouts; relaunch terminals at saved cwd.
7. **Polish** — keyboard shortcuts, optional minimap, zoom-to-fit, theming.

## Critical files (to be created)

```
EndlessTerminal.xcodeproj
EndlessTerminal/
  App/                AppDelegate.swift, MainWindowController.swift
  Canvas/             CanvasScrollView.swift, CanvasView.swift, GridBackground.swift
  Windows/            WindowView.swift, WindowChrome.swift (titlebar/resize handles)
  Content/            TerminalPanel.swift (SwiftTerm), EditorPanel.swift (CodeEditSourceEditor)
  Model/              AppModel.swift, Canvas.swift, WindowItem.swift (Codable)
  Persistence/        LayoutStore.swift
  Resources/          Assets, Info.plist
```

## Verification

- **Pan/zoom:** launch app; pinch-zoom and two-finger pan; confirm ⌘+/− and zoom-at-cursor;
  child panels scale and stay interactive while zoomed.
- **Windows:** create several panels; drag and resize each at multiple zoom levels and confirm
  positions are correct (coordinate conversion); click to raise z-order.
- **Terminals:** open a terminal panel; confirm a real shell runs (`ls`, `vim`, colors, `cd`);
  resize the panel and confirm the terminal reflows cols/rows.
- **Editors:** open a text/code file via `NSOpenPanel`; edit, save, reopen to confirm persisted
  content; confirm syntax highlighting for a known language.
- **Canvases:** create 2+ canvases; switch between them and confirm each retains its windows,
  zoom, scroll position, and that terminal sessions survive the switch.
- **Persistence:** quit and relaunch; confirm layouts restore and terminals relaunch at the
  saved working directory.

## Notes / things to confirm during build

- Verify latest SwiftTerm and CodeEditSourceEditor package versions and their minimum macOS
  deployment target before locking the project target (may force macOS 14+).
- If you later want richer scrollback search or split panes inside a single terminal panel,
  SwiftTerm exposes the buffer; budget for it in milestone 7, not earlier.
