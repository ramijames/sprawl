# Sprawl

**A canvas-based developer environment for macOS.** Sprawl gives you one infinite,
zoomable/pannable surface onto which you place freely draggable and resizable "windows" —
each hosting a **live terminal** or a **code/text editor** — grouped into **projects** that all
live side by side on the same canvas. Think of it as a spatial workbench for the way you
actually work: related shells and files laid out together, every project visible at once, the
whole layout saved and restored exactly as you left it.

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
- **Projects on one shared canvas** — every project is a labeled "folder" card that wraps its
  own windows; they're laid out spatially across the same surface, not hidden behind tabs.
  Click a project in the sidebar to pan/zoom straight to it. Double-click a folder's tab to
  rename it.
- **Selection** — a single white outline shows what's selected: click empty canvas to select
  nothing, a folder to select that project, or a window/terminal to select that item.
- **Persistent workspace** — close the app and reopen it to find everything exactly where you
  left it (see [Persistence](#persistence)).
- **Dark, terminal-like UI** — chrome-less window with a unified toolbar, dark vibrancy
  sidebar, and each project drawn as a "folder" card with its name on a top-left tab.

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
| Cut / Copy / Paste | ⌘X / ⌘C / ⌘V |
| Select All      | ⌘A       |
| Zoom In         | ⌘+       |
| Zoom Out        | ⌘−       |
| Actual Size     | ⌘0       |

**Selecting & renaming**

- Click empty canvas to select nothing, a **folder** to select that project, or a
  **window/terminal** to select that item — the selection shows as a single white outline.
- Click a project in the **sidebar** to pan/zoom straight to it. **Double-click a folder tab**
  to rename it (Return commits, Esc / clicking away cancels).

**Canvas navigation**

- **Pan:** two-finger scroll / trackpad drag over empty canvas.
- **Zoom:** pinch, or **⌘ + scroll** (zooms toward the cursor), or the toolbar zoom control.
- Scrolling over a **terminal** scrolls *that terminal* — its scrollback, or the running
  full-screen app (e.g. `less`, `vim`, a TUI) via wheel/arrow events. **Hold ⌥** while scrolling
  over a terminal to pan the canvas instead.

---

## Persistence

State is saved continuously (debounced) and on quit to:

```
~/Library/Application Support/Sprawl/workspace.json
```

Reopening the app restores:

- **Window** position and size.
- **Projects** — their names, which one was current, and where each folder sits on the shared
  canvas (so empty folders keep their spot).
- **Panels** — their kind, title, position, size, and stacking order on the canvas.
- **Canvas viewport** — the global zoom level and scroll position.
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
