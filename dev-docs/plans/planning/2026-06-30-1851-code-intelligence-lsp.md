# Code Intelligence (LSP) — Scoping

> 2026-06-30

## Context

The Code editor (`Sprawl/Content/CodeEditorPanel.swift`, built on `CodeEditSourceEditor`) currently
gives syntax highlighting, a file tree, and find/replace — but no language intelligence. We want real
**autocomplete, diagnostics, hover, and go-to-definition** by speaking the **Language Server Protocol**
to per-language servers (sourcekit-lsp, typescript-language-server, pyright, gopls, rust-analyzer, …).

This is the big, multi-session item. This doc scopes the architecture and a phased path so we can land
it incrementally without destabilizing the editor.

## What already exists (leverage, don't rebuild)

- **The editor has the right hooks.** `SourceEditor(...)` accepts:
  - `completionDelegate: CodeSuggestionDelegate` — async `completionSuggestionsRequested(textView:cursorPosition:)`
    returning `[CodeSuggestionEntry]`, plus trigger characters and apply-completion. → **autocomplete UI is free.**
  - `jumpToDefinitionDelegate: JumpToDefinitionDelegate` — `queryLinks(forRange:textView:)` + `openLink`. → **go-to-definition UI is free.**
  - We already pass `coordinators:` (the jump-to-line `JumpCoordinator`) and `state:` — same wiring point.
- **No sandbox** (no `.entitlements`; terminals already spawn `$SHELL`), so launching LSP server
  subprocesses and reading repo files is unrestricted. LSP is local **stdio JSON-RPC** — no network.
- **`TextViewController`** exposes `setCursorPositions(_:scrollToVisible:)`, cursor/selection, and the
  text — enough to map LSP positions ↔ editor and to apply edits.
- **Gaps:** `CodeEditSourceEditor` has **no diagnostics rendering** (no squiggles API). Diagnostics need
  custom drawing (underlines via a text-view overlay) and/or a "Problems" list. Hover also has no
  built-in popover — needs a small custom popover.

## Dependency

Add an LSP client stack via SPM in `project.yml` (the CodeEdit ecosystem's, battle-tested):
- `ChimeHQ/LanguageServerProtocol` — LSP request/response types.
- `ChimeHQ/LanguageClient` — process transport, init handshake, restart, capability negotiation.
- (`ChimeHQ/JSONRPC` comes transitively.)
Decision point: confirm versions resolve against our Swift toolchain before committing.

## Architecture

```
CodeEditorPanel (per repo)
   └─ LanguageService (one per language, lazily started for the repo)
        ├─ Server process (sourcekit-lsp / typescript-language-server / …) over stdio
        ├─ LanguageClient (init handshake, didOpen/didChange/didClose, capabilities)
        └─ routes: completion · hover · definition · diagnostics(publish)
   └─ editor delegates → translate editor events ↔ LSP
        ├─ LSPCompletionProvider : CodeSuggestionDelegate
        ├─ LSPDefinitionProvider : JumpToDefinitionDelegate
        ├─ diagnostics sink → underline overlay + Problems list (activity-bar mode)
        └─ hover → custom popover on ⌥-hover / shortcut
```

- **Server discovery/registry.** Map file extension → server command + args, found on `PATH`
  (`/usr/bin/env <server>`) or known locations (sourcekit-lsp ships with the Xcode toolchain via
  `xcrun`). A small built-in table; unknown languages simply get no LSP (graceful).
- **Lifecycle.** Start a server lazily the first time a file of its language is opened in the repo;
  send `initialize` with the repo root as `rootURI`; `textDocument/didOpen` on open, debounced
  `didChange` on edits (the panel already observes `editorModel.$text`), `didClose` on switch. One
  server instance per (repo, language). Tear down with the panel; restart on crash (LanguageClient
  supports this).
- **Document sync.** Reuse the existing `editorModel.$text` Combine observer to push incremental (or
  full, to start) `didChange`. Version counter per document.
- **Position mapping.** LSP is UTF-16 line/character; the editor uses `CursorPosition(line:column:)`
  and `NSRange`. Write one `LSPPosition ↔ editor` mapping helper and unit-test it (off-by-one and
  UTF-16 surrogate pitfalls live here).

## Phasing (each phase ships + is independently useful)

1. **Plumbing + completion (Swift first).** Add SPM deps; `LanguageService` that boots sourcekit-lsp
   (`xcrun sourcekit-lsp`) for the repo; `LSPCompletionProvider: CodeSuggestionDelegate` →
   `textDocument/completion`. Wire `completionDelegate` in `CodeEditorBody`. Verify: typing in a
   `.swift` file in a real Swift repo shows real completions.
2. **Diagnostics.** Handle `textDocument/publishDiagnostics`; render inline underlines (custom overlay
   on the text view) + a **Problems** activity-bar pane (reuse the Search-pane pattern) listing
   file:line + message; click → jump (reuse `JumpCoordinator`).
3. **Hover + go-to-definition.** `LSPDefinitionProvider: JumpToDefinitionDelegate` →
   `textDocument/definition` (open the target file at the line, cross-file). Hover popover →
   `textDocument/hover` (render the markdown).
4. **Multi-language + robustness.** Server registry for ts/js (typescript-language-server), Python
   (pyright), Go (gopls), Rust (rust-analyzer); missing-server empty state; crash/restart; cancel
   in-flight requests on fast typing; settle debounce tuning.

## Key decisions / risks

- **Bundling servers?** No — rely on what's installed (sourcekit-lsp via `xcrun` is always present
  with Xcode; others if the user has them). Show a discreet "install <server> for intelligence" hint
  when missing. (Bundling is a later, heavy option.)
- **Performance.** Debounce `didChange`; cancel stale completion/hover requests; cap diagnostics
  rendering. Don't block the main thread on LSP I/O (LanguageClient is async).
- **Position-mapping correctness** is the sharpest edge — isolate + test it.
- **Editor API limits.** Completion + definition are first-class; diagnostics/hover are custom. If the
  custom overlay proves fragile, fall back to the Problems list only (no inline squiggles) for v1.
- **Scope creep.** Formatting, rename, code actions, signature help are explicitly **out** for now.

## Verification

- Open a known Swift repo (e.g. this one) in the Code app; in a `.swift` file: completions appear on
  `.`/identifier; a deliberate error shows a diagnostic + Problems entry; ⌘-click / shortcut jumps to a
  symbol's definition across files; hover shows type info.
- Confirm the server process starts once per repo+language and is killed when the panel closes (no
  orphans: `pgrep sourcekit-lsp`).
- Unit tests for the LSP↔editor position mapper.

## First step if approved

Phase 1 only: add the SPM deps, a minimal `LanguageService` for sourcekit-lsp, and the completion
delegate — behind the existing editor, Swift-only — then evaluate before widening.
