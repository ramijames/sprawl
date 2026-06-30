import Foundation

/// A small mutable reference box, so undo/redo closures can track an object that gets recreated
/// (e.g. a deleted item is re-created as a new instance on undo).
final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

/// A simple command-stack undo/redo history for app-level actions (create, delete, move/resize,
/// rename). Text-content editing is handled separately by the focused text view's own undo manager.
final class UndoHistory {
    private struct Action { let name: String; let undo: () -> Void; let redo: () -> Void }
    private var undoStack: [Action] = []
    private var redoStack: [Action] = []
    private var applying = false

    /// Record a reversible action. No-op while an undo/redo is being applied (so reversal steps
    /// don't themselves get recorded). Recording a new action clears the redo stack.
    func register(_ name: String, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        guard !applying else { return }
        undoStack.append(Action(name: name, undo: undo, redo: redo))
        redoStack.removeAll()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let action = undoStack.popLast() else { return }
        applying = true
        action.undo()
        applying = false
        redoStack.append(action)
    }

    func redo() {
        guard let action = redoStack.popLast() else { return }
        applying = true
        action.redo()
        applying = false
        undoStack.append(action)
    }

    func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
