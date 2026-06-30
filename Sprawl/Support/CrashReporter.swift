import Foundation

/// Captures crashes to a predictable log file so they can be diagnosed after the fact — essential
/// because, when launched via `open`, the app's stderr (where Swift prints "Fatal error: … at
/// File.swift:line") is otherwise discarded.
///
/// It does three things on launch:
///   1. Redirects stderr to `~/Library/Application Support/Sprawl/console.log` (append), so Swift
///      runtime trap messages — the most useful single line, with file + line number — are kept.
///   2. Installs an uncaught-`NSException` handler that logs the name, reason, and symbolicated stack.
///   3. Installs POSIX signal handlers (SIGILL/SIGTRAP/SIGABRT/SIGSEGV/SIGBUS/SIGFPE) that append a
///      backtrace before re-raising, so Swift traps (which become SIGILL/SIGTRAP) leave a stack too.
enum CrashReporter {
    /// The log file crashes and stderr are written to.
    static var logURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Sprawl/console.log")
    }

    static func install() {
        redirectStderr()
        NSSetUncaughtExceptionHandler(sprawlExceptionHandler)
        for sig in [SIGILL, SIGTRAP, SIGABRT, SIGSEGV, SIGBUS, SIGFPE] {
            signal(sig, sprawlSignalHandler)
        }
    }

    private static func redirectStderr() {
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Keep the file from growing without bound across many runs.
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        freopen(url.path, "a", stderr)
        setvbuf(stderr, nil, _IOLBF, 0)   // line-buffer so messages flush before a crash aborts
        let stamp = ISO8601DateFormatter().string(from: Date())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        fputs("\n========== launch \(stamp) (v\(version)) ==========\n", stderr)
        fflush(stderr)
    }
}

// Top-level C-compatible handlers (must not capture context to be usable as function pointers).

private func sprawlExceptionHandler(_ exception: NSException) {
    var lines = ["", "========== CRASH: uncaught exception \(exception.name.rawValue) =========="]
    if let reason = exception.reason { lines.append(reason) }
    lines.append(contentsOf: exception.callStackSymbols)
    fputs(lines.joined(separator: "\n") + "\n", stderr)
    fflush(stderr)
}

private func sprawlSignalHandler(_ sig: Int32) {
    var lines = ["", "========== CRASH: signal \(sig) =========="]
    lines.append(contentsOf: Thread.callStackSymbols)
    fputs(lines.joined(separator: "\n") + "\n", stderr)
    fflush(stderr)
    signal(sig, SIG_DFL)   // restore default and re-raise so the process still terminates normally
    raise(sig)
}
