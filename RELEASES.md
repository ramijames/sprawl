# Releases

A running log of notable changes to Sprawl, newest first. Dates are `YYYY-MM-DD`. The app is
pre-1.0 (`MARKETING_VERSION 0.1.0`), so entries are dated rather than version-tagged for now.

## 2026-06-28

### Added
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
