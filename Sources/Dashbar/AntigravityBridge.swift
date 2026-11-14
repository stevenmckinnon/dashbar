import Foundation

/// Antigravity plan limits, token totals and live state from the Antigravity CLI's (`agy`) own status line, with no
/// network request and no sign-in.
///
/// Like Claude Code, the Antigravity CLI runs a user-chosen status line command and pipes it the session's state as JSON
/// (https://antigravity.google/docs/cli/statusline/), whenever the agent's state changes. With the user's consent
/// Dashbar points that setting (`statusLine` in `~/.gemini/antigravity-cli/settings.json`) at a small shell script that
/// saves a short list of fields to files Dashbar reads, then runs the status line the user had before, if any, with the
/// same input, so it looks the same. The installer reuses the Claude bridge's careful editing (`StatusLineBridge`):
/// a backup first, only the `statusLine` key changes, invalid JSON is refused, Remove puts back exactly what was there.
///
/// The payload also carries the account's email, the conversation's title and the transcript's path. The script picks
/// fields one by one (an allow-list, not a deny-list), so those, and anything the CLI adds later, are never saved.
enum AntigravityBridge {
    static let scriptName = "antigravity-statusline-bridge.sh"

    /// `$1` is the user's previous status line command, if any. `DASHBAR_STATUSLINE_DIR` overrides where readings go
    /// (tests use it). Saving can fail without affecting the status line.
    static let script = #"""
    #!/bin/sh
    # Dashbar's Antigravity CLI status line bridge (version 1). Dashbar added it with your consent.
    # The Antigravity CLI runs this when the agent's state changes, with the session's details as JSON on stdin.
    # It saves only your plan quota and tier, and this session's folder, model, token totals, estimated cost and
    # state, to files Dashbar reads, then runs the status line you had before, if any, with the same input.
    # It never saves your email, conversation titles or transcripts, and sends nothing anywhere.
    # Remove it in Dashbar's Settings, which puts your previous status line back.
    out_dir="${DASHBAR_STATUSLINE_DIR:-$HOME/Library/Caches/Dashbar}"
    input=$(/bin/cat)

    get() { printf '%s' "$input" | /usr/bin/plutil -extract "$1" "$2" -o - - 2>/dev/null; }
    # A JSON string, or null: quotes and backslashes escaped, control characters dropped.
    str() {
      [ -n "$1" ] || { printf null; return; }
      printf '"%s"' "$(printf '%s' "$1" | /usr/bin/tr -d '\000-\037' | /usr/bin/sed 's/[\\"]/\\&/g')"
    }
    num() { v=$(get "$1" raw | /usr/bin/tr -cd '0-9.eE+-'); printf '%s' "${v:-null}"; }
    flag() { [ "$(get "$1" raw)" = true ] && printf true || printf false; }

    save() {
      /bin/mkdir -p "$out_dir" || return 0
      now=$(/bin/date +%s)
      quota=$(get quota json)
      case $quota in
      '{'*'}')
        tmp="$out_dir/.antigravity-statusline.$$"
        if printf '{"version":1,"written_at":%s,"plan_tier":%s,"quota":%s}\n' "$now" "$(str "$(get plan_tier raw)")" "$quota" >"$tmp" &&
          /bin/mv -f "$tmp" "$out_dir/antigravity-statusline.json"; then :; else /bin/rm -f "$tmp"; fi ;;
      esac
      session=$(get session_id raw | /usr/bin/tr -cd 'A-Za-z0-9_-')
      [ -n "$session" ] || return 0
      dir="$out_dir/antigravity-sessions"
      /bin/mkdir -p "$dir" || return 0
      tmp="$dir/.$session.$$"
      if printf '{"version":1,"written_at":%s,"session_id":"%s","cwd":%s,"project_dir":%s,"model":%s,"input_tokens":%s,"output_tokens":%s,"cost_usd":%s,"cost_estimated":%s,"agent_state":%s,"tool_confirmation_pending":%s}\n' \
          "$now" "$session" "$(str "$(get cwd raw)")" "$(str "$(get workspace.project_dir raw)")" "$(str "$(get model.id raw)")" \
          "$(num context_window.total_input_tokens)" "$(num context_window.total_output_tokens)" "$(num cost.total_usd)" \
          "$(flag cost.estimated)" "$(str "$(get agent_state raw | /usr/bin/tr -cd 'a-z_')")" "$(flag tool_confirmation_pending)" >"$tmp" &&
        /bin/mv -f "$tmp" "$dir/$session.json"; then :; else /bin/rm -f "$tmp"; fi
      /usr/bin/find "$dir" -type f -mtime +2 -delete
    }
    (save) >/dev/null 2>&1

    previous=$1
    case $previous in *antigravity-statusline-bridge*) previous= ;; esac
    [ -n "$previous" ] || exit 0
    printf '%s\n' "$input" | /bin/sh -c "$previous"

    """#

    // MARK: Paths

    struct Paths {
        /// The Antigravity CLI's user settings file.
        var settings: URL
        /// Dashbar's own folder for the script, the install record and backups (shared with the Claude bridge).
        var support: URL
        /// Where the bridge saves readings (only used here to tidy up on removal).
        var readings: URL = AntigravityStatusLine.folder

        var script: URL { support.appendingPathComponent(AntigravityBridge.scriptName) }
        var record: URL { support.appendingPathComponent("antigravity-statusline-install.json") }
        /// The Claude bridge's settings editing, pointed at this file, with backups named for Antigravity.
        var editing: StatusLineBridge.Paths {
            StatusLineBridge.Paths(settings: settings, support: support, readings: readings, backupPrefix: "antigravity-settings-")
        }

        static func `default`() -> Paths {
            Paths(settings: homeDir.appendingPathComponent(".gemini/antigravity-cli/settings.json"),
                  support: homeDir.appendingPathComponent("Library/Application Support/Dashbar"))
        }
    }

    // MARK: Status

    enum Status: Equatable {
        /// The Antigravity CLI's settings folder doesn't exist: it isn't installed, so Settings shows nothing.
        case absent
        case notInstalled(current: String?)
        case installed(previous: String?)
        case unreadable(String)

        var isInstalled: Bool { if case .installed = self { return true } else { return false } }
    }

    enum Failure: LocalizedError, Equatable {
        case invalidSettings
        case noFolder(String)
        case busy
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidSettings:
                return "The Antigravity CLI's settings.json isn't valid JSON. Dashbar didn't change it. Fix the file, then try again."
            case .noFolder(let path):
                return "Couldn't find the Antigravity CLI's settings folder (\(Fmt.tilde(path))). Run `agy` in a terminal once, then try again."
            case .busy:
                return "The Antigravity CLI's settings kept changing while Dashbar was saving. Nothing was changed. Try again in a moment."
            case .writeFailed(let why):
                return "Couldn't save the Antigravity CLI's settings (\(why)). Nothing was changed."
            }
        }

        /// The Claude bridge's failures, reworded for this file.
        init(_ failure: Error) {
            switch failure as? StatusLineBridge.Failure {
            case .invalidSettings?: self = .invalidSettings
            case .noClaudeFolder(let path)?: self = .noFolder(path)
            case .busy?: self = .busy
            case .writeFailed(let why)?: self = .writeFailed(why)
            case nil: self = .writeFailed(failure.localizedDescription)
            }
        }
    }

    static func status(_ paths: Paths) -> Status {
        let folder = paths.settings.deletingLastPathComponent()
        let text: String?
        do { text = try StatusLineBridge.readSettings(paths.settings) } catch { return .unreadable(Failure(error).localizedDescription) }
        guard let text else {
            return FileManager.default.fileExists(atPath: folder.path) ? .notInstalled(current: nil) : .absent
        }
        let parsed: [String: Any]
        do { parsed = try StatusLineBridge.object(text) } catch { return .unreadable(Failure(error).localizedDescription) }
        let command = (parsed["statusLine"] as? [String: Any])?["command"] as? String
        if let command, isBridge(command) {
            let record = StatusLineBridge.Record.load(paths.record).flatMap { $0.settingsPath == paths.settings.path ? $0 : nil }
            return .installed(previous: record.map(\.previousCommand) ?? previousCommand(inBridgeCommand: command))
        }
        return .notInstalled(current: command)
    }

    // MARK: Install and remove

    /// Points the CLI's status line at the bridge, keeping the rest of the existing entry (padding, `enabled`,
    /// `stack_with_default`). Records the previous entry so `uninstall` can put it back exactly; backs up settings.json.
    static func install(_ paths: Paths, now: Date = Date()) throws {
        let folder = paths.settings.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: folder.path) else { throw Failure.noFolder(folder.path) }
        do {
            try writeScript(paths)
            try StatusLineBridge.editSettings(paths.editing, now: now) { text in
                let doc = try StatusLineBridge.Document(text ?? "")
                let existing = doc.member("statusLine")
                var entry: [String: Any] = [:]
                if let existing, let old = try? StatusLineBridge.object(existing.raw) {
                    if let command = old["command"] as? String, isBridge(command) { return nil }   // already added
                    entry = old
                }
                let previous = entry["command"] as? String
                entry["type"] = "command"
                entry["command"] = bridgeCommand(script: paths.script, previous: previous)
                try StatusLineBridge.Record(settingsPath: paths.settings.path, previousStatusLine: existing?.raw, installedAt: now)
                    .save(paths.record)
                return doc.setting("statusLine", to: try StatusLineBridge.json(entry))
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(error)
        }
    }

    /// Puts back the status line the user had (or none), exactly as it was, and removes the script and readings. If the
    /// status line is no longer the bridge (the user changed it since), settings.json is left alone.
    static func uninstall(_ paths: Paths, now: Date = Date()) throws {
        if FileManager.default.fileExists(atPath: paths.settings.deletingLastPathComponent().path) {
            do {
                try StatusLineBridge.editSettings(paths.editing, now: now) { text in
                    guard let text else { return nil }
                    let doc = try StatusLineBridge.Document(text)
                    guard let member = doc.member("statusLine"),
                          let entry = try? StatusLineBridge.object(member.raw),
                          let command = entry["command"] as? String, isBridge(command) else { return nil }
                    if let record = StatusLineBridge.Record.load(paths.record), record.settingsPath == paths.settings.path {
                        if let previous = record.previousStatusLine { return doc.setting("statusLine", to: previous, verbatim: true) }
                        return doc.removing("statusLine")
                    }
                    guard let previous = previousCommand(inBridgeCommand: command) else { return doc.removing("statusLine") }
                    var restored = entry
                    restored["command"] = previous
                    return doc.setting("statusLine", to: try StatusLineBridge.json(restored))
                }
            } catch {
                throw Failure(error)
            }
        }
        let fm = FileManager.default
        try? fm.removeItem(at: paths.record)
        try? fm.removeItem(at: paths.script)
        try? fm.removeItem(at: paths.readings.appendingPathComponent(AntigravityStatusLine.quotaFile))
        try? fm.removeItem(at: paths.readings.appendingPathComponent(AntigravityStatusLine.sessionsFolder))
    }

    /// Writes the script if it is missing or from another version of Dashbar. Called at launch while it's added.
    static func writeScript(_ paths: Paths) throws {
        let data = Data(script.utf8)
        if (try? Data(contentsOf: paths.script)) == data { return }
        do {
            try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
            try data.write(to: paths.script, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.script.path)
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    // MARK: The command

    /// `/bin/sh '<script>' '<previous command>'`, so settings.json alone says what to put back.
    static func bridgeCommand(script: URL, previous: String?) -> String {
        var command = "/bin/sh " + StatusLineBridge.shellQuote(script.path)
        if let previous, !previous.isEmpty { command += " " + StatusLineBridge.shellQuote(previous) }
        return command
    }

    static func isBridge(_ command: String) -> Bool { command.contains(scriptName) }

    static func previousCommand(inBridgeCommand command: String) -> String? {
        let words = StatusLineBridge.shellWords(command)
        guard words.count >= 3, words[1].hasSuffix(scriptName) else { return nil }
        return words[2].isEmpty ? nil : words[2]
    }
}

// MARK: - Reading what the bridge saved

enum AntigravityStatusLine {
    /// Shared by every copy of Dashbar (the release and a local build), like the Claude status line's reading.
    static let folder = homeDir.appendingPathComponent("Library/Caches/Dashbar")
    static let quotaFile = "antigravity-statusline.json"
    static let sessionsFolder = "antigravity-sessions"
    static var quotaURL: URL { folder.appendingPathComponent(quotaFile) }
    static var sessionsDir: URL { folder.appendingPathComponent(sessionsFolder) }

    static let unrecognisedMessage = "The Antigravity CLI's status line had no limits Dashbar recognises. Its format may have changed."

    // MARK: Quota

    static func readLimits(from url: URL = quotaURL, now: Date = Date()) -> AntigravityLimits? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parseLimits(data, now: now)
    }

    /// `{"version":1,"written_at":<epoch s>,"plan_tier":"Pro","quota":{"gemini-weekly":{"remaining_fraction":0.93,
    /// "reset_time":"2026-07-06T07:50:32Z","reset_in_seconds":560580},…}}`. Buckets that are disabled, or count an
    /// amount rather than a fraction, are left out; windows that have already reset are dropped.
    static func parseLimits(_ data: Data, now: Date = Date()) -> AntigravityLimits? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data.isEmpty ? nil : AntigravityLimits(problem: unrecognisedMessage)
        }
        let written = (obj["written_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        var out = AntigravityLimits(planTier: (obj["plan_tier"] as? String).flatMap { $0.isEmpty ? nil : $0 }, fetchedAt: written)
        guard let quota = obj["quota"] as? [String: Any] else {
            out.problem = unrecognisedMessage
            return out
        }
        var groups: [String: AntigravityLimits.Group] = [:]
        var order: [String] = []
        var fullNames: [String: String] = [:]
        var recognised = 0
        for id in quota.keys.sorted() {
            guard let bucket = quota[id] as? [String: Any] else { continue }
            if bucket["disabled"] as? Bool == true { recognised += 1; continue }
            guard let remaining = (bucket["remaining_fraction"] as? NSNumber)?.doubleValue else {
                if bucket["remaining_amount"] != nil { recognised += 1 }
                continue
            }
            recognised += 1
            let reset = (bucket["reset_time"] as? String).flatMap(Date.fromISO)
                ?? (bucket["reset_in_seconds"] as? NSNumber).map { (written ?? now).addingTimeInterval($0.doubleValue) }
            if let reset, reset <= now { continue }
            let parsed = Self.bucket(id)
            fullNames[parsed.group] = parsed.fullName
            let limit = RateLimit(label: parsed.label, usedPercent: max(0, (1 - remaining) * 100), resetsAt: reset,
                                  window: parsed.window, source: id)
            if groups[parsed.group] == nil {
                groups[parsed.group] = .init(key: parsed.group, name: parsed.groupName, limits: [])
                order.append(parsed.group)
            }
            groups[parsed.group]!.limits.append(limit)
        }
        out.groups = order.sorted(by: groupOrder).compactMap { key in
            groups[key].map { g in
                var g = g
                g.limits.sort { ($0.window ?? .infinity, $0.label) < ($1.window ?? .infinity, $1.label) }
                return g
            }
        }
        // Two groups that read the same once unknown words are left out ("gemini-abc", "gemini-xyz") keep those words.
        let counts = Dictionary(out.groups.map { ($0.name, 1) }, uniquingKeysWith: +)
        out.groups = out.groups.map { g in
            guard counts[g.name, default: 0] > 1, let full = fullNames[g.key] else { return g }
            return .init(key: g.key, name: full, limits: g.limits.map { l in
                l.label == g.name ? RateLimit(label: full, usedPercent: l.usedPercent, resetsAt: l.resetsAt, window: l.window, source: l.source) : l
            })
        }
        if recognised == 0 && !quota.isEmpty { out.problem = unrecognisedMessage }
        return out
    }

    /// Gemini first, then the rest by name.
    private static func groupOrder(_ a: String, _ b: String) -> Bool {
        (a.hasPrefix("gemini") ? 0 : 1, a) < (b.hasPrefix("gemini") ? 0 : 1, b)
    }

    struct Bucket: Equatable {
        /// What the window's IDs share: "gemini" for "gemini-weekly" and "gemini-5h".
        let group: String
        /// The group as a person reads it: "Gemini", "Gemini Argon", "Other models".
        let groupName: String
        let label: String
        let window: TimeInterval?
        /// `groupName` keeping the unknown short words, upper-cased ("Gemini Argon WTU"), for when two groups would
        /// otherwise read the same.
        var fullName: String? = nil
    }

    /// Words in bucket IDs that are names, and how they are written. Only these are capitalised.
    static let knownWords: [String: String] = [
        "gemini": "Gemini", "gemma": "Gemma", "claude": "Claude", "gpt": "GPT", "openai": "OpenAI",
        "flash": "Flash", "pro": "Pro", "ultra": "Ultra", "lite": "Lite", "nano": "Nano", "argon": "Argon",
        "image": "Image", "imagen": "Imagen", "veo": "Veo", "opus": "Opus", "sonnet": "Sonnet", "haiku": "Haiku",
        "thinking": "Thinking", "deep": "Deep", "think": "Think", "agent": "Agent", "code": "Code",
        "and": "and", "or": "or", "models": "models", "model": "model", "other": "Other", "all": "All",
    ]
    /// Shorthand the CLI uses for a whole group: "3p" is the third-party models (Claude and GPT, at the time of writing).
    static let shorthand: [String: String] = ["3p": "Other models"]

    /// Splits a bucket ID into its model group and its window: "gemini-weekly" → Gemini, Weekly (7 days);
    /// "claude-and-gpt-5h" → Claude and GPT, 5-hour; "3p-5h" → Other models, 5-hour.
    /// The group's name follows a rule rather than a list of renames, since new IDs keep arriving: known words are
    /// written as names, numbers stay ("2.5"), other words of four letters or more stay in lower case, and shorter
    /// unknown words ("wtu") are left out of the name (the raw ID stays in the tooltip). A name with nothing left is
    /// "Other models". An ID that names no window is labelled with its group's name.
    static func bucket(_ id: String) -> Bucket {
        var words = id.lowercased().split(whereSeparator: { "-_ .:/".contains($0) }).map(String.init)
        var label: String?, window: TimeInterval?
        func take(_ match: (String) -> Bool) -> Bool {
            guard let i = words.firstIndex(where: match) else { return false }
            words.remove(at: i)
            return true
        }
        if take({ ["weekly", "week", "7d", "7day", "7days", "seven"].contains($0) }) {
            _ = take { $0 == "day" || $0 == "days" }
            window = 7 * 86400
        } else if take({ ["5h", "5hr", "5hour", "5hours", "five", "fivehour"].contains($0) }) {
            _ = take { $0 == "hour" || $0 == "hours" || $0 == "h" }
            window = 5 * 3600
        } else if take({ ["daily", "day", "1d", "24h"].contains($0) }) {
            window = 86400
        }
        if let window { label = RateLimit.name(window: window) }
        let group = words.isEmpty ? "all" : words.joined(separator: "-")
        let name = words.isEmpty ? "All models" : readable(words, keepUnknown: false)
        let full = words.isEmpty ? name : readable(words, keepUnknown: true)
        return Bucket(group: group, groupName: name, label: label ?? name, window: window, fullName: full)
    }

    /// "gemini argon wtu" → "Gemini Argon"; with `keepUnknown`, "Gemini Argon WTU". "gemini 2 5 pro" → "Gemini 2.5 Pro".
    static func readable(_ words: [String], keepUnknown: Bool) -> String {
        if let only = words.first, words.count == 1, let short = shorthand[only] { return short }
        var out: [String] = []
        var lastWasNumber = false
        for w in words {
            let isNumber = !w.isEmpty && w.allSatisfy(\.isNumber)
            if isNumber {
                if lastWasNumber, let prev = out.popLast() { out.append(prev + "." + w) } else { out.append(w) }
            } else if let known = knownWords[w] {
                out.append(known)
            } else if let short = shorthand[w] {
                out.append(short)
            } else if w.count >= 4 {
                out.append(w)
            } else if keepUnknown {
                out.append(w.uppercased())
            }
            lastWasNumber = isNumber
        }
        guard var first = out.first else { return "Other models" }
        // Sentence case: the name starts with a capital even when its first word isn't a known one.
        first = first.prefix(1).uppercased() + first.dropFirst()
        out[0] = first
        return out.joined(separator: " ")
    }

    // MARK: Sessions

    /// One CLI session as the bridge last saw it. Token totals and cost are the whole conversation's so far.
    struct Session: Equatable {
        var id: String
        var writtenAt: Date
        var cwd: String
        var projectDir: String?
        var model: String?
        var inputTokens: Int
        var outputTokens: Int
        var costUSD: Double?
        var costEstimated: Bool
        var state: String
        var confirmationPending: Bool

        /// The folder the session works in: the CLI's project folder when it knows one.
        var folder: String { projectDir.flatMap { $0.isEmpty ? nil : $0 } ?? cwd }
    }

    static func parseSession(_ data: Data) -> Session? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = o["session_id"] as? String, !id.isEmpty,
              let written = (o["written_at"] as? NSNumber)?.doubleValue else { return nil }
        return Session(id: id, writtenAt: Date(timeIntervalSince1970: written), cwd: o["cwd"] as? String ?? "",
                       projectDir: o["project_dir"] as? String, model: (o["model"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                       inputTokens: (o["input_tokens"] as? NSNumber)?.intValue ?? 0,
                       outputTokens: (o["output_tokens"] as? NSNumber)?.intValue ?? 0,
                       costUSD: (o["cost_usd"] as? NSNumber)?.doubleValue, costEstimated: o["cost_estimated"] as? Bool ?? true,
                       state: o["agent_state"] as? String ?? "", confirmationPending: o["tool_confirmation_pending"] as? Bool ?? false)
    }

    /// Every session file written within `maxAge`. A file being replaced right now may not parse; it's skipped.
    static func readSessions(dir: URL = sessionsDir, maxAge: TimeInterval = 2 * 86400, now: Date = Date()) -> [Session] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let mtime = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate,
                  now.timeIntervalSince(mtime) <= maxAge,
                  let data = try? Data(contentsOf: url) else { return nil }
            return parseSession(data)
        }
        .sorted { $0.writtenAt > $1.writtenAt }
    }

    /// The live sessions: each running `agy` process paired with the newest session in its folder, plus any session that
    /// says it is working or asking right now even when no process was matched (the CLI's process may be named
    /// differently). A session from a process that has quit is no longer listed.
    static func live(_ sessions: [Session], processes: [(pid: Int32, root: String)], now: Date = Date(),
                     root: (String) -> String = Fmt.root(fromCwd:)) -> [LiveSession] {
        var unmatched = processes
        var out: [LiveSession] = []
        for s in sessions {   // newest first
            let r = root(s.folder.isEmpty ? homeDir.path : s.folder)
            if let i = unmatched.firstIndex(where: { $0.root == r }) {
                out.append(liveSession(s, pid: unmatched[i].pid, root: r))
                unmatched.remove(at: i)
            } else if now.timeIntervalSince(s.writtenAt) < 120, s.confirmationPending || busyStates.contains(s.state) {
                out.append(liveSession(s, pid: 0, root: r))
            }
        }
        return out
    }

    static let busyStates: Set<String> = ["working", "tool_use", "reviewing", "initializing", "authenticating"]

    static func liveSession(_ s: Session, pid: Int32, root: String) -> LiveSession {
        let status = s.confirmationPending ? "waiting" : busyStates.contains(s.state) ? "busy" : s.state == "error" ? "error" : "idle"
        var live = LiveSession(id: "agy-" + s.id, pid: pid, name: Fmt.project(fromCwd: root), cwd: s.cwd, status: status,
                               since: s.writtenAt, entrypoint: "cli", root: root,
                               waitingFor: s.confirmationPending ? "permission prompt" : nil)
        live.agent = .antigravityCLI
        return live
    }
}

// MARK: - Usage from the sessions' totals

/// Turns the bridge's per-session running totals into the day ledger the usage card reads. Each scan adds what each
/// session's totals grew by since the last one, priced with the CLI's own cost estimate when it gave one.
final class AntigravityUsageTracker {
    struct Snapshot: Codable, Equatable {
        var input = 0
        var output = 0
        var cost: Double?
    }

    struct State: Codable {
        var last: [String: Snapshot]
        var book: UsageBook
    }

    private let dir: URL
    private let cache: ScanCache<State>?
    private var last: [String: Snapshot] = [:]
    private(set) var book = UsageBook()
    private var dirty = false
    /// Whether the bridge has ever saved a session (so the usage card knows whether to show).
    private(set) var found = false

    init(dir: URL = AntigravityStatusLine.sessionsDir, cache: URL? = nil) {
        self.dir = dir
        self.cache = cache.map { ScanCache(url: $0) }
        if let saved = self.cache?.load() {
            last = saved.last
            book = saved.book
            found = !saved.last.isEmpty
        }
    }

    func scan(now: Date = Date()) {
        let sessions = AntigravityStatusLine.readSessions(dir: dir, now: now)
        if !sessions.isEmpty { found = true }
        for s in sessions {
            let old = last[s.id] ?? Snapshot()
            let snapshot = Snapshot(input: s.inputTokens, output: s.outputTokens, cost: s.costUSD)
            guard snapshot != old else { continue }
            var delta = TokenTotals(input: s.inputTokens, output: s.outputTokens).growth(since: TokenTotals(input: old.input, output: old.output))
            if delta.total > 0 { delta.messages = 1 }
            let model = s.model ?? "Antigravity"
            var cost: Double?
            if let now = s.costUSD { cost = max(0, now - (old.cost ?? 0)) }
            else { cost = Pricing.cost(delta, model: Pricing.normalize(displayName: model)) }
            book.add(delta, at: s.writtenAt, model: model, project: Fmt.project(fromCwd: s.folder.isEmpty ? homeDir.path : s.folder),
                     session: s.id, cost: cost)
            last[s.id] = snapshot
            dirty = true
        }
        // The bridge tidies files older than two days; their sessions are finished.
        let live = Set(sessions.map(\.id))
        let before = last.count
        last = last.filter { live.contains($0.key) }
        if last.count != before { dirty = true }
        book.prune(now: now)
    }

    func save() {
        guard dirty, let cache else { return }
        cache.save(State(last: last, book: book))
        dirty = false
    }
}
