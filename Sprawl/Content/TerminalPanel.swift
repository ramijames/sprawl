import AppKit
import SwiftTerm

/// Owns a live local terminal (SwiftTerm) running the user's login shell, and hosts it inside
/// a window panel's content area. This is the only file that touches the SwiftTerm types.
final class TerminalPanel: NSObject, LocalProcessTerminalViewDelegate {
    let terminalView: LocalProcessTerminalView

    var onTitleChange: ((String) -> Void)?
    var onProcessTerminated: (() -> Void)?
    /// The shell's current working directory changed (reported via OSC 7) — request autosave.
    var onDirectoryChange: (() -> Void)?

    /// Latest working directory reported by the shell, persisted so a restored terminal can
    /// relaunch there. `nil` until the shell first reports one.
    private(set) var currentDirectory: String?

    init(startDirectory: String? = nil) {
        currentDirectory = startDirectory
        terminalView = LocalProcessTerminalView(frame: .zero)
        super.init()
        terminalView.processDelegate = self
        startShell(in: startDirectory)
    }

    /// Place the terminal into a window panel, filling its content area.
    func attach(to window: WindowView) {
        window.setContent(terminalView)
    }

    /// Make the terminal the first responder so keystrokes go to the shell.
    func focus() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    private func startShell(in directory: String?) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["TERM_PROGRAM"] = "Sprawl"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        let environment = env.map { "\($0.key)=\($0.value)" }

        // posix_spawn inherits the current working directory; point the new shell at the saved
        // directory (when restoring) or $HOME. Fall back to $HOME if the saved dir is gone.
        let fileManager = FileManager.default
        let previous = fileManager.currentDirectoryPath
        let home = fileManager.homeDirectoryForCurrentUser.path
        var target = home
        if let directory, fileManager.fileExists(atPath: directory) { target = directory }
        fileManager.changeCurrentDirectoryPath(target)
        // A leading "-" in argv[0] makes the shell a login shell.
        terminalView.startProcess(executable: shell,
                                  args: [],
                                  environment: environment,
                                  execName: "-\(shellName)")
        fileManager.changeCurrentDirectoryPath(previous)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onTitleChange?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // SwiftTerm reports a file:// URL (OSC 7); keep just the path for relaunch.
        guard let directory else { return }
        let path = URL(string: directory)?.path ?? directory
        guard path != currentDirectory else { return }
        currentDirectory = path
        onDirectoryChange?()
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onProcessTerminated?()
    }
}

extension NSView {
    /// True if this view or any ancestor is a terminal view. (SwiftTerm seals `scrollWheel`, so
    /// scroll redirection is done with an event monitor rather than a subclass override.)
    var isInsideTerminal: Bool {
        var view: NSView? = self
        while let current = view {
            if current is TerminalView { return true }
            view = current.superview
        }
        return false
    }

    /// The nearest enclosing window panel, if this view is inside one (used to map a click on a
    /// terminal/document's content back to its item).
    var enclosingWindowView: WindowView? {
        var view: NSView? = self
        while let current = view {
            if let panel = current as? WindowView { return panel }
            view = current.superview
        }
        return nil
    }

    /// Scroll the terminal this view belongs to in response to a wheel/trackpad delta (`points`,
    /// positive = scroll back toward older output). We drive this ourselves because SwiftTerm's
    /// own `scrollWheel` only reads the legacy line-based `deltaY` (0 for trackpad). The right
    /// action depends on what the running program wants:
    ///   - mouse reporting on (e.g. Claude Code) -> send real wheel button events at the cursor;
    ///   - alternate screen, no mouse reporting (e.g. plain `less`/`vim`) -> arrow keys;
    ///   - normal screen -> scroll the actual scrollback.
    /// `accumulator` carries fractional lines across the many small events a trackpad emits.
    @discardableResult
    func scrollEnclosingTerminal(points: CGFloat, locationInWindow: NSPoint, accumulator: inout CGFloat) -> Bool {
        var view: NSView? = self
        var found: TerminalView?
        while let current = view {
            if let term = current as? TerminalView { found = term; break }
            view = current.superview
        }
        guard let term = found else { return false }

        accumulator += points / 16   // ~16 pt per line
        let lines = Int(accumulator)
        guard lines != 0 else { return true }   // consumed, but below the 1-line threshold
        accumulator -= CGFloat(lines)

        let terminal = term.getTerminal()
        let up = lines > 0
        let count = min(abs(lines), 6)

        if terminal.mouseMode != .off {
            let p = term.convert(locationInWindow, from: nil)
            let cols = terminal.cols, rows = terminal.rows
            let cw = max(1, term.bounds.width / CGFloat(cols))
            let ch = max(1, term.bounds.height / CGFloat(rows))
            let col = min(cols - 1, max(0, Int(p.x / cw)))
            let row = min(rows - 1, max(0, Int((term.bounds.height - p.y) / ch)))
            let flags = terminal.encodeButton(button: up ? 4 : 5, release: false, shift: false, meta: false, control: false)
            for _ in 0..<count { terminal.sendEvent(buttonFlags: flags, x: col, y: row) }
        } else if terminal.isCurrentBufferAlternate {
            let seq = up ? (terminal.applicationCursor ? "\u{1b}OA" : "\u{1b}[A")
                         : (terminal.applicationCursor ? "\u{1b}OB" : "\u{1b}[B")
            term.send(txt: String(repeating: seq, count: count))
        } else if up {
            term.scrollUp(lines: lines)
        } else {
            term.scrollDown(lines: -lines)
        }
        return true
    }
}
