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
- **Tabbed windows** — every window (terminal, document, or browser) holds tabs: ⌘T opens one,
  ⌘W closes it (closing the last tab closes the window), acting on the selected window. Press
  **⌘`** to center and zoom the selected window to fill the screen.
- **Snapping** — a toolbar button (top-right) toggles snapping; with it on, moving or resizing a
  window magnetically **aligns its edges and centers to nearby windows** (Figma-style smart guides),
  and lines / click-to-place snap to the grid.
- **Auto-tiling** — arrange a project's windows into a tidy, non-overlapping layout in one undoable
  step (then pan/zoom to frame it): **Uniform Grid**, **2×2**, **3×3**, **Columns**, or **Pack**
  (keep sizes). From the top-bar tile button, a folder's right-click **Tile Windows** submenu, or **⌥⌘T**.
- **Live terminals** — each terminal panel runs your login shell (`$SHELL`) with a real PTY
  (via [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)).
- **Documents** — a plain-text editor for notes and scratch text (open / save), with word-wrap.
- **Code editor** — point it at a repository and browse the **file tree** (single-click toggles a
  folder, double-click renames, right-click for Open in Finder / Open in Tab / Copy Path / Copy
  Relative Path / Delete-to-Trash); open files as **tabs** (⌘W closes) with syntax highlighting + line
  numbers (via [CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor)) and autosave
  to disk. **Search** across the repo with match-case / whole-word / regex toggles and **Replace All**;
  click a hit to jump to its line.
- **Code intelligence (LSP)** — autocomplete, go-to-definition, diagnostics (a **Problems** pane +
  inline **squiggles**), hover, **signature help**, **Format Document** (⌥⇧F), and **Rename Symbol**
  (⌥⌘R, across files), via language servers: **Swift** out of the box (`xcrun sourcekit-lsp`) and
  **JS/TS** when `typescript-language-server` is installed. Servers start lazily and are found on your
  login PATH.
- **Command palette (⌘K)** — a fuzzy launcher to create tools, run a tiling layout, jump to a project,
  zoom, toggle snapping, undo/redo, or open Preferences, all from the keyboard.
- **Diff** — see uncommitted changes (`git diff HEAD`) as a **changed-files list** (with per-file
  +/- counts) beside a GitHub-style **side-by-side** diff for the selected file. **Stage/unstage** each
  file and **commit** the staged changes with a message, in-panel.
- **Annotations** — **sticky notes**, **free text**, and **lines / connectors** (orthogonal "elbow"
  routing with rounded corners and arrowheads), all with a floating **options bar** for color,
  thickness, font, and arrowheads.
- **Tabbed browser** — a single-row toolbar (**close · back · forward · reload · address ·
  bookmarks**) with the **tab strip below** it (⌘T new / ⌘W close), two-finger swipe and ⌘←/⌘→ for
  back/forward, and address-bar search. **Ad / tracker blocking is on by default** (EasyList +
  EasyPrivacy, including cosmetic rules; cached for offline). Onboarding-imported **bookmarks** appear
  in a bookmarks bar, a bookmarks menu, and on the new-tab page, whose **"Frequently browsed"** grid is
  powered by imported **history**. Links that open a new window become tabs; sized OAuth/sign-in popups
  stay separate windows. Open tabs are saved and restored.
- **Git Observer** — point a window at any folder containing a git repository and see a
  GitHub-style **contribution graph** for a calendar year (Jan–Dec, one shaded square per day),
  with **◀ / ▶ year navigation** and horizontal scrolling, plus a **commit timeline** (date ·
  subject · author, newest first). The chosen repository is saved and reloaded with the workspace.
- **Git Graph** — visualize a repo's **branch & merge history** as colored swim-lanes with a node
  per commit, curved fork/merge connectors, ref chips, and a subject / author / short-hash column
  (newest at top, latest 2000 commits).
- **Project Velocity** — a glanceable health summary of a repo: a **recency** header (colored dot +
  "Updated N days ago"), a **commit histogram** across the whole history (so spikes in activity
  stand out), and a **core-contributors** list with share bars showing who's doing the work.
- **Claude** — a streaming AI assistant panel (Anthropic Messages API) with a model picker
  (Sonnet 4.6 / Opus 4.8 / Haiku 4.5) that's **repo-aware by location**: created inside a project
  that has a Git widget, it inherits that repo's branch, status, and recent commits as context. A
  **chat-bubble** UI (Send nested in the input) with project-aware starter prompts; the API key is
  stored in the macOS Keychain. See [`dev-docs/claude-integration-spec.md`](dev-docs/claude-integration-spec.md).
- **Projects on one shared canvas** — every project is a rounded "folder" card that wraps its own
  windows, laid out spatially across the same surface (not hidden behind tabs). Its name is a
  **zoom-invariant white label** above the top-left corner (constant size at any zoom). Click a folder
  (or its name) to select the project and open a **project options bar** to rename it, set its color,
  and choose a **tiling mode** (Freeform / Grid / Columns — **Grid** is the default). Click a project
  in the sidebar to pan/zoom straight to it; drag a folder to move the whole project.
- **Live tiling** — set a project to **Grid** or **Columns** and it stays tidy on its own: it
  re-tiles whenever a window is added or removed. In **Grid**, each window owns an **explicit cell** —
  drag a window into **any** cell (empty cells can be anywhere) and it drops there, or **swaps** with
  whatever's already in that cell, with a highlighted **placeholder** showing the target. In Grid you
  can also **resize a window's edge into the next column/row** to make it **span multiple cells**.
- **Selection** — a white outline shows what's selected; **Shift-click** to select multiple items
  at once (then DELETE removes the group, ESC deselects). DELETE removes the selection; **⌘Z / ⇧⌘Z**
  undo / redo create, delete, move/resize, and annotation edits.
- **Top bar + group tabs** — a custom flat top bar (Lucide icons): a sidebar toggle, a standalone
  **New Project** button, and a centered pill of group **tabs** — **Ideate**, **Review** (Diff /
  Velocity / Observer / Graph), **Create** (Terminal / Document / Code / Browser / Claude), and
  **Manage**. Clicking a tab opens a **custom dropdown** of its tools (icon + name) beneath it;
  picking one arms it and places the item **where you next click on the canvas**. **Annotate** tools
  (Sticky / Text / Arrow) live in a small dock on the right edge; undo / redo and the snap toggle sit
  at the right of the bar.
- **Right-click** — empty canvas to make a project where you click; empty space inside a folder to
  add any tool (terminal, document, code, browser, git widgets, diff, annotations, …) to it.
- **Persistent workspace** — close the app and reopen it to find everything exactly where you
  left it (see [Persistence](#persistence)).
- **Dark, terminal-like UI** — chrome-less window with a custom flat top bar, dark vibrancy
  sidebar, and each project drawn as a "folder" card with its name pinned above its top-left corner.

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

## App icon

The icon lives in the asset catalog at `Sprawl/Resources/Assets.xcassets/AppIcon.appiconset`
(wired up via `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` in `project.yml`).

To set or change it, drop a single square **1024×1024 PNG** at `Sprawl/Resources/AppIcon.png`
and run the generator, which slices it into all ten macOS sizes:

```sh
./scripts/make-icon.sh                 # uses Sprawl/Resources/AppIcon.png
./scripts/make-icon.sh path/to/my.png  # or pass a different master
```

Then rebuild. (Prefer to manage sizes by hand? Drop the individually named PNGs —
`icon_16x16.png`, `icon_16x16@2x.png`, … `icon_512x512@2x.png` — straight into the
`AppIcon.appiconset` folder instead.)

---

## Usage

Create terminals, documents, and projects from the **top bar's group tabs**, the sidebar **+**
button, the keyboard, or by **right-clicking the canvas**:

| Action          | Shortcut |
| --------------- | -------- |
| New Terminal    | ⌘1       |
| New Document    | ⌘2       |
| New Browser     | ⌘3       |
| New Git Observer | ⌘4      |
| New Git Graph    | ⌘5      |
| New Project Velocity | ⌘6  |
| New Claude       | ⌘7       |
| New Tab (in the selected window) | ⌘T |
| Close Tab (in the selected window) | ⌘W |
| Fit selected window to screen | ⌘` |
| Back / Forward (in a browser) | ⌘← / ⌘→ (or two-finger swipe) |
| Open File…      | ⌘O       |
| Save            | ⌘S       |
| New Project     | ⌘⇧N      |
| Cut / Copy / Paste | ⌘X / ⌘C / ⌘V |
| Select All      | ⌘A       |
| Zoom In         | ⌘+       |
| Zoom Out        | ⌘−       |
| Actual Size     | ⌘0       |

**Right-click (context menu)**

- Right-click **empty canvas** to create a **new project** right where you clicked.
- Right-click **empty space inside a project's folder** to add a **new terminal, document, or
  browser** to that project — its window spawns at the click.

**Selecting & renaming**

- Click empty canvas to select nothing, a **folder** (or its name) to select that project — which
  opens its **options bar** (rename / color / tiling) — or a **window/terminal** to select that item.
  The selection shows as a single white outline.
- Click a project in the **sidebar** to pan/zoom straight to it. Rename a project from its **options
  bar** or by double-clicking it in the sidebar.

**Canvas navigation**

- **Pan:** **hold ⌥** and two-finger scroll (anywhere). Plain scroll over empty canvas does
  nothing — moving the canvas always requires ⌥.
- **Zoom:** pinch, **⌘ + scroll** (zooms toward the cursor), or the View menu (⌘+ / ⌘− / ⌘0).
- Plain scroll over a **terminal**, **browser**, or **editor** scrolls *that* content (a
  terminal's scrollback, or a running full-screen app like `less`/`vim` via wheel/arrow
  events). Hold ⌥ to pan the canvas instead.

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

### Crash logs

Crashes (and the app's stderr) are captured to `~/Library/Application Support/Sprawl/console.log` —
Swift fatal-error messages with file/line, uncaught exceptions, and signal backtraces. Useful when
the app is launched via `open` (where stderr is otherwise discarded). macOS also writes full native
reports to `~/Library/Logs/DiagnosticReports/Sprawl-*.ips`.

---

## Project structure

```
Sprawl/
  App/         App entry point, window controller, split view, menu, app delegate
  Canvas/      Zoomable/pannable scroll view, canvas document view, canvas controller
  Windows/     WindowView — the draggable/resizable panel chrome
  Content/     Terminal/Document panels, BrowserPanel, GitObserverPanel, GitGraphPanel,
               ProjectVelocityPanel, TabbedContainer
  Sidebar/     Project/item source-list sidebar
  Model/       AppModel — projects, items, and snapshot/restore
  Persistence/ WorkspaceState (Codable) + WorkspaceStore (JSON on disk)
  Resources/   Assets.xcassets (AppIcon) + the master AppIcon.png
  Support/     Palette (color theme), LucideIcon (icon renderer)
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
