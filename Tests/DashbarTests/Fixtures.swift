import Foundation

/// Builds throwaway log folders shaped like Claude Code's and Codex's, timestamped "now"
/// so day and hour bucketing land in today.
struct Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dashbar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func dir(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func write(_ path: String, lines: [[String: Any]]) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func append(_ url: URL, lines: [[String: Any]]) throws {
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        h.write(Data(text.utf8))
        try h.close()
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    static var now: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    /// One Claude Code assistant record.
    static func claude(id: String, request: String = "req", model: String = "claude-opus-5-5", cwd: String = "/Users/x/dev/app",
                       input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0,
                       sidechain: Bool = false, session: String = "s1") -> [String: Any] {
        [
            "type": "assistant", "timestamp": now, "sessionId": session, "cwd": cwd, "requestId": request,
            "isSidechain": sidechain,
            "message": [
                "id": id, "model": model, "role": "assistant",
                "usage": ["input_tokens": input, "output_tokens": output,
                          "cache_read_input_tokens": cacheRead, "cache_creation_input_tokens": cacheWrite],
            ] as [String: Any],
        ]
    }

    /// One Codex cumulative token_count event.
    static func codexTokens(input: Int, cached: Int, output: Int, rateUsed: Double? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            "type": "token_count",
            "info": ["total_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output]],
        ]
        if let rateUsed {
            payload["rate_limits"] = ["primary": ["used_percent": rateUsed, "window_minutes": 300, "resets_in_seconds": 3600.0]]
        }
        return ["timestamp": now, "type": "event_msg", "payload": payload]
    }
}
