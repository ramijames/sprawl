# Sprawl

**A canvas-based developer environment for macOS.** Sprawl gives you an infinite,
zoomable/pannable surface onto which you place freely draggable and resizable "windows" —
each hosting a **live terminal** or a **code/text editor** — and organizes them into multiple
switchable projects. Think of it as a spatial workbench for the way you actually work: related
shells and files laid out side by side on one canvas, the whole layout saved and restored
exactly as you left it.

It's a native Swift/AppKit app (no Electron, no web view), so terminals are real local shells
with full PTY access and the canvas is GPU-composited for smooth zooming over many live panels.

---

## Features

- **Infinite canvas** — pan and zoom over a large work surface; panels stay live and
  interactive at any zoom level.
- **Window panels** — draggable title bar, edge/corner resize, close, and click-to-raise
  z-ordering.
- **Live terminals** — each terminal panel runs your login shell (`$SHELL`) with a real PTY
  (via [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)).
- **Code & text editor** — open, edit, and save files with syntax highlighting and line
  numbers (via [CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor)).
- **Projects** — group terminals and documents into separate canvases; switch between them
  from the sidebar without tearing down live sessions.
- **Persistent workspace** — close the app and reopen it to find everything exactly where you
  left it (see [Persistence](#persistence)).
- **Dark, terminal-like UI** — chrome-less window with a unified toolbar, dark vibrancy
  sidebar, and per-project boundary frames.

---

## Requirements

- **macOS 14 (Sonoma) or later** to run.
- **Xcode 16 or later** and **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** to build from
  source. The Xcode project is generated from `project.yml`, so XcodeGen is required.

Install XcodeGen if you don't have it:

```sh
brew install xcodegen
```

---

## Building

The `.xcodeproj` is generated, not checked in, so the first step is always to generate it.

```sh
# 1. Generate the Xcode project from project.yml (resolves Swift Package dependencies)
xcodegen generate

# 2. Build
xcodebuild -project Sprawl.xcodeproj -scheme Sprawl -configuration Debug build

# 3. Run
open build/Sprawl.app
```

The built app is always copied to **`./build/Sprawl.app`** (a predictable, git-ignored path)
by a post-build step, regardless of where Xcode's DerivedData happens to live.

Prefer Xcode? After `xcodegen generate`, open `Sprawl.xcodeproj` and press **⌘R**.

> **Note:** the build prints two non-fatal `Running SwiftLint … failed` lines. These come from
> a SwiftLint build-tool plugin inside the third-party CodeEdit packages and do **not** affect
> the app — `xcodebuild` still exits `0` and `build/Sprawl.app` is produced.

---

## Usage

Create terminals, documents, and projects from the toolbar **+** menu, the sidebar **+**
button, or the keyboard:

| Action          | Shortcut |
| --------------- | -------- |
| New Terminal    | ⌘T       |
| New Document    | ⌘N       |
| Open File…      | ⌘O       |
| Save            | ⌘S       |
| New Project     | ⌘⇧N      |
| Zoom In         | ⌘+       |
| Zoom Out        | ⌘−       |
| Actual Size     | ⌘0       |

**Canvas navigation**

- **Pan:** two-finger scroll / trackpad drag.
- **Zoom:** pinch, or **⌘ + scroll** (zooms toward the cursor), or the toolbar zoom control.
- Scrolling over a terminal pans the canvas; **hold ⌥** to scroll the terminal's own
  scrollback instead.

---

## Persistence

State is saved continuously (debounced) and on quit to:

```
~/Library/Application Support/Sprawl/workspace.json
```

Reopening the app restores:

- **Window** position and size.
- **Projects** and which one was current.
- **Panels** — their kind, title, position, size, and stacking order on each canvas.
- **Canvas viewport** — each project's zoom level and scroll position.
- **Documents** — their file path and exact in-memory text (so unsaved edits survive).
- **Terminals** — relaunched as fresh login shells in their last working directory. (A live
  shell process and its scrollback can't be serialized, so the process itself does not carry
  over.)

If `workspace.json` ever fails to decode, it is preserved as `workspace.corrupt.json` rather
than being overwritten, and the app starts fresh.

---

## Project structure

```
Sprawl/
  App/         App entry point, window controller, split view, menu, app delegate
  Canvas/      Zoomable/pannable scroll view, canvas document view, canvas controller
  Windows/     WindowView — the draggable/resizable panel chrome
  Content/     TerminalPanel (SwiftTerm), DocumentPanel (CodeEditSourceEditor)
  Sidebar/     Project/item source-list sidebar
  Model/       AppModel — projects, items, and snapshot/restore
  Persistence/ WorkspaceState (Codable) + WorkspaceStore (JSON on disk)
  Support/     Palette — the color theme
project.yml    XcodeGen project definition (targets, settings, dependencies)
dev-docs/      Architecture and milestone plans
```

---

## Tech stack

| Concern           | Choice |
| ----------------- | ------ |
| Language / UI     | Swift + AppKit (SwiftUI only for the editor host) |
| Canvas zoom/pan   | `NSScrollView` with `allowsMagnification` |
| Terminal          | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) `1.11.2` |
| Editor            | [CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor) `0.15.2` |
| Build / deps      | Xcode + Swift Package Manager, project generated by XcodeGen |
| Min deployment    | macOS 14.0 |

> SwiftTerm is pinned to `1.11.2`: version `1.12.0+` adds a Metal renderer that needs Xcode's
> separately-downloadable Metal Toolchain. `1.11.2` is the newest tag that builds without it.

---

## License

No license has been specified for this project yet.
