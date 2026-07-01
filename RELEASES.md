# Releases

A running log of notable changes to Sprawl, newest first. Dates are `YYYY-MM-DD`. The app is
pre-1.0 (`MARKETING_VERSION 0.1.0`), so entries are dated rather than version-tagged for now.

## 2026-07-01

### Added
- **Deeper code intelligence (LSP).** **Format Document** (⌥⇧F), **Rename Symbol** (⌥⌘R — prompts
  for a name and applies the edits across open + on-disk files), **inline diagnostic squiggles**
  (red/orange underlines under errors/warnings), and **signature help** (typing `(` or `,` shows the
  active signature at the caret). Also in the Command Palette.
- **Editor tabs.** The Code editor opens files as tabs — click to switch, × or **⌘W** to close.
- **Diff staging + commit.** The Diff app now has a per-file **stage/unstage checkbox** (reflecting
  `git status`) and a **commit message box + Commit button** that commits the staged changes.
- **Flexible grid.** A grid project now gives each window an **explicit cell**: empty cells can be
  anywhere, and dragging a window drops it into whatever cell you're over (empty → moves there;
  occupied → the two **swap**). Grid is now the **default** layout for new projects.
- **Browser — single-row toolbar.** The browser drops its title bar for a one-line toolbar:
  **close (red dot) · back · forward · reload · address · bookmarks**, with the **tab strip below**
  it. Keeps standard resize, border, and rounded corners.
- **Browser — ad / tracker blocking (on by default).** Fetches **EasyList + EasyPrivacy** (public
  filter lists), converts them to WebKit content-blocker rules **including cosmetic/element-hiding
  rules** (which hide first-party promoted content like Reddit's ads), compiles them in chunks, and
  caches them for offline use. A small curated set blocks instantly while the lists load.
- **Browser — bookmarks & history import.** Onboarding now imports **full bookmarks** (URL + title)
  and **history** from Chrome/Brave/Edge/etc., Firefox, and Safari (best-effort). Bookmarks appear in
  a **bookmarks bar**, a **bookmarks menu**, and a **Bookmarks section** on the new-tab page; the
  new-tab **"Frequently browsed"** grid is now powered by imported history.
- **Browser — address-bar autocomplete.** Typing shows a dropdown of matching bookmarks + frequent
  hosts (↑/↓ to move, Enter to open, Esc to dismiss, or click).
- **Browser — bookmark management.** A toolbar **★** bookmarks/unbookmarks the current page;
  bookmark-bar chips show **favicons** and have a right-click menu (**Rename… / Remove / Copy Link**).
- **Browser — find in page (⌘F).** A find bar (Enter = next, ↑/↓ = prev/next, Esc = close); the
  field turns red when there's no match.
- **Browser — downloads.** Non-viewable responses and download links save to **~/Downloads**
  (auto-deduped) and reveal in Finder when finished.
- **Browser — sign-in popups as modals.** A sized `window.open`/OAuth popup opens **centered over the
  browser that spawned it**, instead of cascading elsewhere on the canvas.
- **Toggle Sidebar (⌘\\).** A View-menu item + shortcut to show/hide the sidebar.

### Fixed
- Grid drag drop-zone is now centered on the dragged window (it used to bias down-and-right).
- Grid delete no longer leaves a stuck placeholder highlight.
- Browser popups (OAuth / `window.open`) no longer crash on a duplicate script-message handler.
- **Annotations stay freeform** in Grid/Columns projects — sticky notes, free text, and lines are no
  longer tiled, snapped, or counted in the grid.
- **Free text is placeable in a Grid project** again (adding it no longer triggers a grid reflow that
  stole its edit focus).

## 2026-06-30

### Added
- **Annotations.** **Sticky notes** (solid pastel text pads), **Free Text** (background-less pastel
  text that hugs its content), and **Lines / connectors** — two-point orthogonal "elbow" connectors
  with rounded corners and optional arrowheads, drawn by click-drag or click-then-click, with
  endpoint + segment handles (snap-aware) and auto-simplifying elbows.
- **Options bar.** A floating, dock-styled contextual toolbar above the selected item: color / font /
  size for annotations, thickness + arrowhead toggles for lines, a repository picker for the
  git/code/diff tools, and open / save / word-wrap for documents — plus a delete button. Toggled
  controls highlight with an accent background.
- **Undo / redo.** A command-stack history (⌘Z / ⇧⌘Z) covering create, delete, move/resize, and
  annotation edits; Edit-menu items and toolbar buttons beside the snap toggle.
- **Multi-select.** Shift-click to select multiple items (all outlined); DELETE removes the whole
  group as one undoable step and ESC deselects everything.
- **Code editor.** Pick a repository, browse its **file tree** (single-click folder toggle,
  double-click rename, a right-click menu with Open in Finder / Open in Tab / Copy Path / Copy
  Relative Path / Delete-to-Trash), and edit files with syntax highlighting + line numbers; edits
  autosave to disk. The window title shows the selected repo.
- **Code search & replace.** Find across the repo with **match-case / whole-word / regex** toggles;
  click a result to open the file and **scroll to that line**. **Replace All** rewrites matches across
  every file (regex templates in regex mode, literal otherwise).
- **Code intelligence (LSP).** The Code editor speaks the **Language Server Protocol** for
  **autocomplete**, **go-to-definition** (cross-file), **diagnostics** (a **Problems** pane in the
  activity bar — click to jump, colored by severity), and **hover** (dwell for quick info). **Swift**
  works out of the box via `xcrun sourcekit-lsp`; **JavaScript / TypeScript** via
  `typescript-language-server` when it's installed (`npm i -g typescript-language-server typescript`).
  Servers start lazily per language and are discovered on your login PATH.
- **Command palette (⌘K).** A Spotlight-style fuzzy launcher: create any tool, run a tiling layout,
  **jump to a project**, zoom, toggle snapping, undo/redo, or open Preferences — keyboard-first
  (↑/↓ to move, ↩ to run, Esc to dismiss).
- **Diff.** Uncommitted changes (`git diff HEAD`) as a **changed-files list** (with per-file +/-
  counts on the right) beside a GitHub-style **side-by-side** diff for the selected file (old vs.
  new, red / green, wrapped, with line-number gutters).
- **Preferences window.** A tabbed window (General · Account): the undo-history limit, plus the
  Anthropic (Claude) connection status and API key (stored in the Keychain).
- **Auto-tiling.** Arrange a project's windows into a tidy, non-overlapping layout as one undoable
  step, then pan/zoom to frame the result. Layouts: **Uniform Grid**, **2×2**, **3×3**, **Columns**,
  and **Pack** (keeps each window's size and packs them into rows). From the top-bar tile button,
  a folder's right-click **Tile Windows** submenu, or **⌥⌘T** (View ▸ Tile Windows, Uniform Grid).
- **Onboarding.** A first-run wizard (intro → browser-profile access → install Claude → create your
  first project) living in a dedicated onboarding space.

### Changed
- **Snapping aligns to neighbors.** Window move/resize now magnetically aligns edges and centers to
  nearby windows (Figma-style guides, ~8px on-screen) instead of rounding to an absolute grid.
- **Claude chat.** Redesigned as chat bubbles (your messages right, Claude's left in a monospace
  bubble up to 85% width), with the Send button nested inside the input box and project-aware
  starter prompts above it.
- **Documents are plain text** (no gutter / syntax highlighting); the dedicated Code app provides
  highlighting + line numbers.
- **App menu** reorganized: About Sprawl · Preferences · Hide / Hide Others · Quit.
- **Rename** items by double-clicking the window header (projects rename from the project options bar
  or the sidebar); added names no longer get a numeric suffix.
- **Projects on the canvas reworked.** Removed the folder **tab**, **collapse chevron**, and **color
  dot** (and the collapse feature). The project name is now a **zoom-invariant white label** pinned
  just above the folder's top-left corner — a constant on-screen size at any zoom (it lives in a
  screen-space overlay, so it never scales during a pinch). Click a folder *or its name* to select the
  project and show a **project options bar** to rename it, change its color, and pick a **tiling
  mode** — **Freeform / Grid / Columns**. Grid and Columns are *live*: the project re-tiles as windows
  are added, removed, or moved, and dragging a window opens a highlighted **placeholder gap** showing
  where it will drop. In **Grid**, you can also **resize a window to span multiple cells** (drag its
  edge into the next column/row — same placeholder highlight); the grid repacks around it. The options
  bar follows the project as you drag it.
- **Top bar + group tabs.** Replaced the macOS toolbar (and its system "glass" item grouping) and the
  bottom dock with a custom flat **top bar** (#141414, #383838 borders): a sidebar toggle, a **New
  Project** button, and a centered pill of group **tabs** — **Ideate**, **Review** (Diff / Velocity /
  Observer / Graph), **Create** (Terminal / Document / Code / Browser / Claude), **Manage** — each
  opening a **custom dropdown** of tools (icon + name) below it; picking one arms it to place where you
  next click. **Annotate** tools (Sticky / Text / Arrow) live in a small dock on the right edge; undo /
  redo and the snap toggle sit at the right of the bar.

### Removed
- **Figma app.** Removed entirely; any saved Figma windows are dropped on load.

### Fixed
- **Delete / Escape for every element.** Selecting a non-text panel now pulls keyboard focus to it,
  so DELETE (remove) and ESCAPE (deselect) work for lines, annotations, and git/analytics widgets —
  not just text panels.
- **Multi-delete undo.** Grouped the delete into one step and drop focus to the canvas (keeping the
  controller in the responder chain) so ⌘Z restores the whole group.
- **Code editor files not loading.** Replaced the CDN-hosted Monaco web view (blank in the WKWebView
  sandbox) with the native source editor, and rebuild the editor per file so selections load.

## 2026-06-29

### Added
- **Git Observer.** A window that points at any git repo and shows a GitHub-style **contribution
  graph** for a calendar year (Jan–Dec) with **◀ / ▶ year navigation** and horizontal scroll, plus
  a **commit timeline** (date · subject · author). The selected repo persists with the workspace.
- **Git Graph.** Visualizes a repo's **branch & merge history** as colored swim-lanes — a node per
  commit, curved fork/merge connectors, ref chips, and a subject / author / short-hash column
  (newest first, latest 2000 commits).
- **Project Velocity.** A glanceable repo health summary: a recency header ("Updated N days ago"),
  a **commit histogram** over the whole history (spikes stand out), and a **core-contributors** list
  with share bars showing who's doing the work.
- **Dock folders.** The floating dock is now a standalone **New Project** button plus grouped
  flyout folders — **Apps** (Terminal / Document / Browser), **Git** (Git Observer / Git Graph),
  **Analytics** (Project Velocity) — each a caret button opening a menu *above* the dock. New File
  menu items + shortcuts: Git Graph (⌘5), Project Velocity (⌘6).
- **App icon.** Wired up an asset catalog (`AppIcon`) with a generator script
  (`scripts/make-icon.sh`) that slices a single 1024px master into all macOS sizes.
- **Empty states.** Git Observer / Graph / Velocity show a centered faded icon + "Select Repository"
  button until a repository is chosen.
- **Crash logging.** A `CrashReporter` captures Swift fatal errors (with file/line), uncaught
  exceptions, and signal backtraces to `~/Library/Application Support/Sprawl/console.log`.

### Fixed
- **OAuth/popup sign-in crash.** Adopting a popup's web configuration re-registered the `sprawlFocus`
  script message handler and threw `NSInvalidArgumentException`; registration is now idempotent.
- **Git Graph resize crash.** The graph's document view was under-constrained, so resizing could
  produce a NaN frame that trapped in `draw`; added position constraints + finite/range guards.
- **Git Observer empty grid.** The contribution view had a zero frame (document view left with
  `translatesAutoresizingMaskIntoConstraints = true`), so no cells drew.
- **Build signing.** The post-build copy to `./build/Sprawl.app` now signs each nested binary
  individually (the old `--deep` pass could silently leave the app unsigned → launch failures).

### Changed
- **Window drag/resize** suppress Core Animation's implicit animation so panels track the cursor
  exactly; canvas + window chrome rasterize asynchronously.

## 2026-06-28

### Added
- **Browser popups & dialogs.** `target="_blank"` / `window.open` now open a single new browser
  panel (instead of navigating in place or duplicating); JS `alert`/`confirm`/`prompt` show as
  sheets; and a popup that calls `window.close()` closes itself, so OAuth/login flows complete.
- **Browser windows.** A third panel type alongside terminals and documents: a `WKWebView` with
  an address bar (back/forward + a URL/search field). Create with **New Browser** (⌘B) or the
  toolbar/sidebar **+** menus; the window title follows the page title, and each browser's last
  URL persists across relaunch.
- **Project tabs.** Each tab now has a **collapse** chevron (hides the project's windows and
  shrinks the folder to just its tab) and a **color** dot opening a 4×4 grid of 16 preset colors;
  the chosen color subtly tints the folder fill/stroke. **Drag a project by its tab** to move the
  whole project (all its windows) at once. Collapse state and color persist.
- **Persistent workspace.** The whole session is saved to
  `~/Library/Application Support/Sprawl/workspace.json` (continuous, debounced autosave + a save
  on quit) and restored on launch: OS window position/size, projects, panels (kind, title,
  position, size, z-order), the canvas viewport, documents (file path + exact unsaved text), and
  terminals (relaunched as fresh login shells in their last working directory). A corrupt
  `workspace.json` is preserved as `workspace.corrupt.json` instead of being overwritten.
- **Single shared canvas.** All projects now live on one infinite canvas at once, each drawn as
  a rounded "folder" card that wraps its windows, with the project name on a top-left tab. New
  projects appear in open space near the current view; clicking a project in the sidebar
  pans/zooms to it. (Replaces the previous one-canvas-per-project model; existing saved
  workspaces are migrated to spread their projects out without overlapping.)
- **Three-level selection.** Click empty canvas to select nothing, a folder to select a project,
  or a window/terminal to select that item — shown as a single white outline.
- **Rename projects** by double-clicking a folder's tab (inline editor; Return commits, Esc /
  click-away cancels).
- **Edit menu** (Cut/Copy/Paste/Select All) so `⌘V` paste and copy work in terminals and fields.
- **`RELEASES.md`** (this file) and an expanded **`README.md`**.

### Changed
- **Modifier canvas navigation.** Holding **⌥ pans** / **⌘ zooms** the canvas over *any* item
  (terminal, browser, editor) — the item no longer scrolls while a modifier is held.
- **Rounder corners.** Larger radii on project folders and window panels; the hosted content
  (terminal/browser/editor) is clipped to match.
- **Panel chrome redesign.** A single hairline border (no title-bar band), centered title, a
  macOS-style red close dot that reveals ✕ on hover, and more inner content padding.
- **New colors.** Folders are `#272634` with `#343345` / `#5E5C7D` borders; terminal windows and
  their content are `#141414` with `#383838` / `#5B5959` borders. Selection now just recolors the
  1px border instead of drawing a thick white outline.
- **⌘-scroll zooms anywhere** over the canvas — even when the cursor is over a terminal or editor.
- **Terminal scrolling.** Plain scroll over a terminal now scrolls *that terminal*: the
  scrollback on the normal screen, or — for full-screen apps (Claude Code, `less`, `vim`) — real
  mouse-wheel events when the app uses mouse reporting, else arrow keys (alternate-scroll).
  Trackpad scrolling is supported (SwiftTerm ignores it on its own). Hold **⌥** to pan the canvas
  over a terminal instead.
- **Builds** always emit the app to a predictable, git-ignored `./build/Sprawl.app`.
- **Code signing** uses a stable self-signed identity (`Sprawl Dev`) so macOS stops re-prompting
  for permissions on every rebuild (ad-hoc signing changed the app identity each build).

### Fixed
- Window position/size now reliably restore (taken over from AppKit frame autosave, which wasn't
  applying), with an off-screen guard for disconnected displays.
