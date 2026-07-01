import Foundation
import CoreGraphics

/// Folder-chrome geometry shared by `CanvasView` (drawing/hit-test) and the persistence
/// migrator, so the constants the migration relies on can never silently drift from what is
/// actually drawn.
enum SharedCanvasLayout {
    static let canvasSize = CGSize(width: 20_000, height: 20_000)
    static let framePadding: CGFloat = 80
    static let tabHeight: CGFloat = 44
    static let defaultEmptyContent = CGSize(width: 900, height: 600)
    /// Default size for a newly spawned window panel.
    static let defaultPanelSize = CGSize(width: 460, height: 320)
}

/// Global canvas viewport (zoom + scroll), now that all projects share one surface.
struct ViewportState: Codable {
    var magnification: CGFloat
    var scrollOrigin: CGPoint
}

/// Codable snapshot of the whole workspace, written to disk on quit and read back on launch.
/// Live processes (shells) can't be serialized, so terminals relaunch at their last working
/// directory; documents restore their exact in-memory text (preserving unsaved edits).
struct WorkspaceState: Codable {
    /// nil => legacy v1 (one canvas per project). Current writers set 2. Triggers one-time migration.
    var version: Int?
    var projects: [ProjectState] = []
    /// The project drawn with the white selected outline on relaunch.
    var currentProjectID: UUID?
    /// Global canvas zoom + scroll (nil => center on launch).
    var viewport: ViewportState?
    /// The OS window's frame (position + size) in screen coordinates.
    var windowFrame: CGRect?
}

struct ProjectState: Codable {
    var id: UUID
    var name: String
    /// Items in back-to-front z-order, in ABSOLUTE shared-canvas coordinates.
    var items: [ItemState]
    /// Content-region top-left in shared-canvas coords; authoritative for empty folders and the
    /// spawn seed for the project's first window.
    var anchor: CGPoint?
    /// Accent color index (into Palette.projectColors). `collapsed` is legacy (the feature was
    /// removed) — kept only so older workspaces still decode.
    var collapsed: Bool?
    var colorIndex: Int?
    /// Live tiling mode raw value ("freeform" / "grid" / "columns").
    var tilingMode: String?

    // Legacy v1 per-project viewport — optional, read only during migration; v2 writes omit them.
    var magnification: CGFloat?
    var scrollOrigin: CGPoint?
    var hasViewport: Bool?
}

/// One tab inside a terminal/document window (browsers persist via `browserTabs` instead).
struct TabState: Codable {
    var name: String?
    var filePath: String?
    var documentText: String?
    var workingDirectory: String?
}

/// One node of a saved line path: anchor (x, y) and bezier handle (hx, hy), frame-relative.
struct LineNodeState: Codable, Equatable {
    var x: Double
    var y: Double
    var hx: Double
    var hy: Double
}

struct ItemState: Codable {
    enum Kind: String, Codable { case terminal, document, codeEditor, figma, browser, files, gitObserver, gitGraph, projectVelocity, diff, assistant, onboarding, sticky, freeText, line }

    var name: String
    var kind: Kind
    /// Panel frame in absolute shared-canvas coordinates (position + size).
    var frame: CGRect

    /// Tabs for a terminal/document window, in order, with the active one at `activeTab`.
    /// When absent (older saves), the single `filePath`/`documentText`/`workingDirectory` below
    /// describe one tab.
    var tabs: [TabState]?
    var activeTab: Int?

    // Document-only (legacy single-tab fields; superseded by `tabs`).
    var filePath: String?
    /// Exact editor text at snapshot time — restores unsaved edits, not just the on-disk file.
    var documentText: String?

    // Terminal-only (legacy single-tab field; superseded by `tabs`).
    var workingDirectory: String?

    /// True if the user renamed this item — so the chosen name survives auto-titling after restore.
    var renamed: Bool?

    /// Sticky-note / free-text pastel color index (the text lives in `documentText`).
    var stickyColor: Int?
    /// Free-text font size.
    var freeTextSize: Double?

    // Line annotation: stroke thickness, arrowhead toggles, and the path's nodes (frame-relative
    // anchor + bezier handle, in the panel's local coordinate space). Color reuses `stickyColor`.
    var lineThickness: Double? = nil
    var lineArrowStart: Bool? = nil
    var lineArrowEnd: Bool? = nil
    /// The connector's two endpoints (anchors; handles unused). `lineBend` is the elbow position.
    var lineNodes: [LineNodeState]? = nil
    var lineBend: Double? = nil

    // Legacy single-segment line fields (pre-pen-tool saves); migrated into `lineNodes` on load.
    var lineCurved: Bool? = nil
    var lineStartX: Double? = nil
    var lineStartY: Double? = nil
    var lineEndX: Double? = nil
    var lineEndY: Double? = nil

    // Browser-only: the last URL, so the browser restores where it was. `browserTabs` holds every
    // tab's URL in order (start-page tabs serialize as a sentinel) and supersedes `browserURL` when
    // present; `browserURL` is still written for back-compat with older builds.
    var browserURL: String?
    var browserTabs: [String]?
    var browserActiveTab: Int?

    /// The window's cell in a live grid project (`gridX`/`gridY`, -1 if unassigned) and how many cells
    /// it spans (1×1 unless resized).
    var gridX: Int?
    var gridY: Int?
    var gridCols: Int?
    var gridRows: Int?
}

// MARK: - Migration: per-project canvases (v1) -> one shared canvas (v2)

extension WorkspaceState {
    /// One-time, deterministic, idempotent migration. Legacy v1 projects were each authored on
    /// their own canvas, so all their window frames cluster near the same center and would
    /// overlap on one shared surface. This pins the current project in place (so the promoted
    /// global viewport still frames it) and lays the rest out in a non-overlapping grid, rigidly
    /// translating each project's windows to preserve its internal relative layout exactly.
    /// Translate all saved content so its bounding box re-centers on the current canvas. Used after
    /// the canvas size changed (e.g. the 6000 → 20000 swap) so existing windows don't end up off in
    /// a corner. Preserves relative layout and the user's view (the viewport shifts with it).
    mutating func migrateRecenterIfNeeded() {
        guard (version ?? 0) < 4 else { return }
        var rects: [CGRect] = []
        for project in projects {
            for item in project.items { rects.append(item.frame) }
            if project.items.isEmpty, let anchor = project.anchor {
                rects.append(CGRect(origin: anchor, size: SharedCanvasLayout.defaultEmptyContent))
            }
        }
        if let first = rects.first {
            let bbox = rects.dropFirst().reduce(first) { $0.union($1) }
            let dx = SharedCanvasLayout.canvasSize.width / 2 - bbox.midX
            let dy = SharedCanvasLayout.canvasSize.height / 2 - bbox.midY
            for p in projects.indices {
                if let anchor = projects[p].anchor {
                    projects[p].anchor = CGPoint(x: anchor.x + dx, y: anchor.y + dy)
                }
                for i in projects[p].items.indices {
                    projects[p].items[i].frame.origin.x += dx
                    projects[p].items[i].frame.origin.y += dy
                }
            }
            if let viewport {
                self.viewport = ViewportState(magnification: viewport.magnification,
                                              scrollOrigin: CGPoint(x: viewport.scrollOrigin.x + dx,
                                                                    y: viewport.scrollOrigin.y + dy))
            }
        }
        version = 4
    }

    mutating func migrateToSharedCanvasIfNeeded() {
        guard version == nil else { return }

        let pad = SharedCanvasLayout.framePadding
        let tabH = SharedCanvasLayout.tabHeight
        let canvas = SharedCanvasLayout.canvasSize
        let defaultContent = SharedCanvasLayout.defaultEmptyContent
        let gutter: CGFloat = 320
        let margin: CGFloat = 200

        func contentRect(_ p: ProjectState) -> CGRect? {
            guard let first = p.items.first?.frame else { return nil }
            return p.items.dropFirst().reduce(first) { $0.union($1.frame) }
        }
        let rects = projects.map(contentRect)

        // Uniform cell sized to the LARGEST project's content + chrome + gutter.
        var maxW = defaultContent.width, maxH = defaultContent.height
        for r in rects { if let r { maxW = max(maxW, r.width); maxH = max(maxH, r.height) } }
        let cellW = maxW + 2 * pad + gutter
        let cellH = maxH + 2 * pad + tabH + gutter

        let n = projects.count
        let cols = max(1, Int(ceil(Double(n).squareRoot())))
        func colRow(_ i: Int) -> (Int, Int) { (i % cols, i / cols) }

        // Where a project's content top-left sits inside its cell (room for left/top padding + tab).
        let contentInset = CGPoint(x: pad, y: pad + tabH)

        // Pin the current project at zero delta: anchor the grid so its cell lands on its
        // existing content origin.
        let pinned = currentProjectID.flatMap { id in projects.firstIndex { $0.id == id } } ?? 0
        let pinnedOrigin = rects[pinned]?.origin ?? CGPoint(
            x: canvas.width / 2 - defaultContent.width / 2,
            y: canvas.height / 2 - defaultContent.height / 2)
        let (pc, pr) = colRow(pinned)
        let gridOrigin = CGPoint(
            x: pinnedOrigin.x - (CGFloat(pc) * cellW + contentInset.x),
            y: pinnedOrigin.y - (CGFloat(pr) * cellH + contentInset.y))

        for i in projects.indices {
            let (c, r) = colRow(i)
            var cellOrigin = CGPoint(x: gridOrigin.x + CGFloat(c) * cellW,
                                     y: gridOrigin.y + CGFloat(r) * cellH)
            // Defensive clamp (never triggers for the real near-center data).
            cellOrigin.x = min(max(margin, cellOrigin.x), canvas.width - cellW - margin)
            cellOrigin.y = min(max(margin, cellOrigin.y), canvas.height - cellH - margin)
            let target = CGPoint(x: cellOrigin.x + contentInset.x, y: cellOrigin.y + contentInset.y)

            if i == pinned {
                projects[i].anchor = rects[i]?.origin ?? target
            } else if let cur = rects[i]?.origin {
                let dx = target.x - cur.x, dy = target.y - cur.y
                for j in projects[i].items.indices {
                    projects[i].items[j].frame.origin.x += dx
                    projects[i].items[j].frame.origin.y += dy
                }
                projects[i].anchor = target
            } else {
                projects[i].anchor = target   // empty project: nothing to move
            }
        }

        // Promote the pinned project's old viewport to the global one (valid: it didn't move).
        let pp = projects[pinned]
        if pp.hasViewport == true, let m = pp.magnification, let so = pp.scrollOrigin {
            viewport = ViewportState(magnification: m, scrollOrigin: so)
        }

        version = 2
        for i in projects.indices {
            projects[i].magnification = nil
            projects[i].scrollOrigin = nil
            projects[i].hasViewport = nil
        }
    }
}
