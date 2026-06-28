import Foundation

/// Reads and writes the `WorkspaceState` snapshot as JSON in Application Support
/// (`~/Library/Application Support/Sprawl/workspace.json`). Writes are atomic so a crash
/// mid-save can't corrupt the file.
final class WorkspaceStore {
    private let fileURL: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("Sprawl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("workspace.json")
    }

    func load() -> WorkspaceState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try JSONDecoder().decode(WorkspaceState.self, from: data)
        } catch {
            // The file exists but is unreadable. Preserve it (rather than let the next autosave
            // overwrite the only copy) and start fresh.
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent("workspace.corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            NSLog("Sprawl: workspace.json could not be decoded (\(error)); preserved as workspace.corrupt.json")
            return nil
        }
    }

    func save(_ state: WorkspaceState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
