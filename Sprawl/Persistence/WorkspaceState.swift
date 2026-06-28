import Foundation
import CoreGraphics

/// Codable snapshot of the whole workspace, written to disk on quit and read back on launch.
/// Live processes (shells) can't be serialized, so terminals relaunch at their last working
/// directory; documents restore their exact in-memory text (preserving unsaved edits).
struct WorkspaceState: Codable {
    var projects: [ProjectState] = []
    /// Which project was current, so the same one is shown on relaunch.
    var currentProjectID: UUID?
    /// The OS window's frame (position + size) in screen coordinates.
    var windowFrame: CGRect?
}

struct ProjectState: Codable {
    var id: UUID
    var name: String
    /// Items in back-to-front z-order, so restoring in array order recreates the stacking.
    var items: [ItemState]
    /// Saved viewport (canvas zoom + scroll position) so the canvas re-frames identically.
    var magnification: CGFloat
    var scrollOrigin: CGPoint
    var hasViewport: Bool
}

struct ItemState: Codable {
    enum Kind: String, Codable { case terminal, document }

    var name: String
    var kind: Kind
    /// Panel frame in canvas coordinates (position + size).
    var frame: CGRect

    // Document-only.
    var filePath: String?
    /// Exact editor text at snapshot time — restores unsaved edits, not just the on-disk file.
    var documentText: String?

    // Terminal-only.
    var workingDirectory: String?
}
