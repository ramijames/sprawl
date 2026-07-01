import Foundation

/// A minimal Language Server Protocol client: speaks Content-Length-framed JSON-RPC 2.0 to a server
/// subprocess over stdio. Covers the subset we need — requests with responses, client→server
/// notifications, and server→client notifications (e.g. `textDocument/publishDiagnostics`). Messages
/// are plain `[String: Any]` (JSONSerialization) rather than fully-typed LSP models, since we only
/// touch a handful of fields.
final class LSPClient {
    enum LSPError: Error { case launchFailed, stopped, serverError(String) }

    /// Server→client notifications, delivered on the main queue: (method, params).
    var onNotification: ((_ method: String, _ params: [String: Any]) -> Void)?

    private let process = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let queue = DispatchQueue(label: "sprawl.lsp")   // serializes ids, pending, and the read buffer
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Any?, Error>] = [:]
    private var buffer = Data()
    private(set) var isRunning = false

    func start(command: String, arguments: [String], currentDirectory: URL) throws {
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.ingest(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }  // discard logs
        do { try process.run() } catch { throw LSPError.launchFailed }
        isRunning = true
    }

    func stop() {
        isRunning = false
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        queue.async { [weak self] in
            self?.pending.values.forEach { $0.resume(throwing: LSPError.stopped) }
            self?.pending.removeAll()
        }
    }

    func notify(_ method: String, _ params: [String: Any]) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    func request(_ method: String, _ params: [String: Any]) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.isRunning else { continuation.resume(throwing: LSPError.stopped); return }
                let id = self.nextID; self.nextID += 1
                self.pending[id] = continuation
                self.send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            }
        }
    }

    // MARK: - Framing

    private func send(_ object: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: object) else { return }
        var message = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        message.append(body)
        try? inPipe.fileHandleForWriting.write(contentsOf: message)
    }

    /// Append new bytes and dispatch every complete message currently buffered. Runs on `queue`.
    private func ingest(_ data: Data) {
        buffer.append(data)
        let separator = Data("\r\n\r\n".utf8)
        while let headerRange = buffer.range(of: separator) {
            let header = String(decoding: buffer[buffer.startIndex..<headerRange.lowerBound], as: UTF8.self)
            let length = header.split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            let bodyStart = headerRange.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return }  // wait for more
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            let body = buffer[bodyStart..<bodyEnd]
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
            if let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                dispatch(message)
            }
        }
    }

    private func dispatch(_ message: [String: Any]) {
        if message["method"] == nil, let id = message["id"] as? Int {
            let continuation = pending.removeValue(forKey: id)
            if let error = message["error"] as? [String: Any] {
                continuation?.resume(throwing: LSPError.serverError(error["message"] as? String ?? "LSP error"))
            } else {
                continuation?.resume(returning: message["result"])
            }
            return
        }
        guard let method = message["method"] as? String else { return }
        if let id = message["id"] {   // a server→client request — answer null so it doesn't block
            send(["jsonrpc": "2.0", "id": id, "result": NSNull()])
        }
        let params = message["params"] as? [String: Any] ?? [:]
        DispatchQueue.main.async { [weak self] in self?.onNotification?(method, params) }
    }
}
