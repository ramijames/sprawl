import Foundation

/// The Claude models Sprawl offers, newest generation.
enum ClaudeModel: String, CaseIterable {
    case sonnet = "claude-sonnet-4-6"   // balanced default for interactive use
    case opus = "claude-opus-4-8"       // most capable, for hard problems
    case haiku = "claude-haiku-4-5"     // fast/cheap for light questions

    var displayName: String {
        switch self {
        case .sonnet: return "Sonnet 4.6"
        case .opus: return "Opus 4.8"
        case .haiku: return "Haiku 4.5"
        }
    }
}

/// One turn in a conversation.
struct ClaudeMessage {
    let role: String   // "user" or "assistant"
    let text: String
}

enum ClaudeError: LocalizedError {
    case noAPIKey
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No Anthropic API key set."
        case .http(let code, let body): return "API error \(code): \(body)"
        }
    }
}

/// Minimal streaming client for the Anthropic Messages API (no official Swift SDK exists). Streams
/// text deltas over SSE via `URLSession.bytes`. The stable `system` prefix gets a prompt-cache
/// breakpoint so repeated turns re-read it cheaply.
enum ClaudeClient {
    static func stream(system: String, messages: [ClaudeMessage], model: ClaudeModel,
                       maxTokens: Int = 4096) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let apiKey = APIKeyStore.load() else {
                continuation.finish(throwing: ClaudeError.noAPIKey)
                return
            }
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            let body: [String: Any] = [
                "model": model.rawValue,
                "max_tokens": maxTokens,
                "stream": true,
                "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
                "messages": messages.map { ["role": $0.role, "content": $0.text] },
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var errorBody = ""
                        for try await line in bytes.lines { errorBody += line }
                        continuation.finish(throwing: ClaudeError.http(status, errorBody))
                        return
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = obj["type"] as? String else { continue }
                        switch type {
                        case "content_block_delta":
                            if let delta = obj["delta"] as? [String: Any],
                               delta["type"] as? String == "text_delta",
                               let text = delta["text"] as? String {
                                continuation.yield(text)
                            }
                        case "message_stop":
                            continuation.finish()
                            return
                        case "error":
                            let message = (obj["error"] as? [String: Any])?["message"] as? String ?? "stream error"
                            continuation.finish(throwing: ClaudeError.http(200, message))
                            return
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
