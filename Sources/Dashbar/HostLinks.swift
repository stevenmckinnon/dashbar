import Foundation
import SQLite3

/// Links that open a Claude Code session's own conversation in the app it runs in, found only when someone clicks to
/// go back to it (never on a timer), off the main thread. A missing or unreadable answer only leaves the app as it
/// was, since `HostApp.open` brings the app forward first.
///
/// - T3 Code: `t3code://threads/<environment>/<thread>`. The environment is the one line of
///   `~/.t3/userdata/environment-id`; the thread comes from T3's `statev2.sqlite`, opened read-only, selecting only
///   `thread_id` where Claude Code's session id is the provider thread's `nativeThreadRef.nativeId`, or for threads T3
///   imported from its older store, the resume cursor's `resume` (`t3Queries`).
///   Never titles, messages or any other column.
/// - Claude (the Desktop app): `claude://code/continue?session=<local id>`. Each of its Code sessions is a
///   `local_<id>.json` under `~/Library/Application Support/Claude/claude-code-sessions/`, which holds Claude Code's
///   session id as `cliSessionId` (or, once it has changed, `lastAssistantCliSessionId`). The file whose bytes contain that pair is the one; nothing in it is parsed or kept
///   (it also holds prompt suggestions), and its name is the id. Desktop ignores the link while its own "entry
///   points" setting is off.
enum HostLinks {
    static let t3BundleID = "com.t3tools.t3code"
    static let desktopBundleID = "com.anthropic.claudefordesktop"

    static func handles(bundleID: String) -> Bool { bundleID == t3BundleID || bundleID == desktopBundleID }

    /// The link for Claude Code session `session` in the app with `bundleID`, or nil. Reads files: call off the main thread.
    static func url(bundleID: String, session: String, home: String = NSHomeDirectory()) -> URL? {
        guard isSessionID(session) else { return nil }
        switch bundleID {
        case t3BundleID:
            let data = home + "/.t3/userdata"
            guard let env = (try? String(contentsOfFile: data + "/environment-id", encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  let thread = t3Thread(database: data + "/statev2.sqlite", session: session) else { return nil }
            return t3URL(environment: env, thread: thread)
        case desktopBundleID:
            let folder = home + "/Library/Application Support/Claude/claude-code-sessions"
            return desktopLocalID(sessions: folder, session: session).flatMap(desktopURL(localID:))
        default:
            return nil
        }
    }

    /// Claude Code's session ids are UUIDs; anything else is never looked for or put in a query.
    static func isSessionID(_ s: String) -> Bool {
        (8...64).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    // MARK: T3 Code

    static func t3URL(environment: String, thread: String) -> URL? {
        guard !environment.isEmpty, environment.count <= 64,
              environment.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              !thread.isEmpty, thread.count <= 200,
              let encoded = thread.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))
        else { return nil }
        return URL(string: "t3code://threads/\(environment)/\(encoded)")
    }

    /// The queries, tried in order and kept here so the test can check they select nothing but the thread id. T3's
    /// current threads name Claude Code's session as the provider thread's `nativeThreadRef.nativeId`; threads it
    /// imported from its older store carry it as the resume cursor's `resume`.
    static let t3Queries = [
        """
        SELECT thread_id FROM orchestration_v2_projection_provider_threads \
        WHERE provider LIKE 'claude%' AND json_extract(payload_json, '$.nativeThreadRef.nativeId') = ?1 \
        ORDER BY updated_at DESC LIMIT 1
        """,
        """
        SELECT thread_id FROM provider_session_runtime \
        WHERE provider_name LIKE 'claude%' AND json_extract(resume_cursor_json, '$.resume') = ?1 \
        ORDER BY last_seen_at DESC LIMIT 1
        """,
    ]

    static func t3Thread(database path: String, session: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let base = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
        var db: OpaquePointer?
        // Read-only and never created; the write-ahead log is seen through mode=ro.
        guard sqlite3_open_v2(base + "?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else { sqlite3_close_v2(db); return nil }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 200)
        for query in t3Queries {
            var stmt: OpaquePointer?
            // A table missing from this version of T3 fails to prepare: try the next.
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK, let stmt else { sqlite3_finalize(stmt); continue }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, session, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) { return String(cString: text) }
        }
        return nil
    }

    // MARK: Claude (the Desktop app)

    static func desktopURL(localID: String) -> URL? {
        guard localID.hasPrefix("local_"), (7...70).contains(localID.count),
              localID.dropFirst(6).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return URL(string: "claude://code/continue?session=" + localID)
    }

    /// The `local_…` id of the Desktop session holding Claude Code session `session`, newest file first.
    static func desktopLocalID(sessions folder: String, session: String) -> String? {
        let root = URL(fileURLWithPath: folder)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var files: [(url: URL, date: Date)] = []
        for case let url as URL in walk {
            // Accounts and organisations, then the session files: never deeper.
            if walk.level > 3 { walk.skipDescendants(); continue }
            let name = url.lastPathComponent
            guard name.hasPrefix("local_"), name.hasSuffix(".json"),
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  (v.fileSize ?? 0) <= 16 << 20 else { continue }
            files.append((url, v.contentModificationDate ?? .distantPast))
        }
        // `lastAssistantCliSessionId` is the newer id when Claude Code's changed during the Desktop session.
        let needles = ["cliSessionId", "lastAssistantCliSessionId"]
            .flatMap { ["\"\($0)\":\"\(session)\"", "\"\($0)\": \"\(session)\""] }.map { Data($0.utf8) }
        for file in files.sorted(by: { $0.date > $1.date }) {
            guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe),
                  needles.contains(where: { data.range(of: $0) != nil }) else { continue }
            return String(file.url.lastPathComponent.dropLast(5))
        }
        return nil
    }
}
