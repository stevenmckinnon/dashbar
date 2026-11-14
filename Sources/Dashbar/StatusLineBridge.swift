import Foundation

/// Claude plan limits from Claude Code's own status line, with no network request and no Keychain access.
///
/// Claude Code runs a user-chosen "status line" command after each reply and pipes it the session's details as
/// JSON, including, for Pro, Max and Ultra plans, `rate_limits` (the 5-hour and weekly windows: percent used and
/// reset time). With the user's consent Dashbar points that setting at a small shell script, the bridge, which saves
/// only `rate_limits` and the time to a file Dashbar reads, then runs the status line the user had before, if any,
/// with the same input, so it looks and works exactly as it did.
///
/// The bridge is a `/bin/sh` script rather than a helper inside the app because Claude Code stores the command's path:
/// a script in Application Support keeps working when the app is updated, moved, renamed (the local build) or even
/// deleted, in which case it still runs the user's own status line. It uses only tools every Mac has (`plutil` parses
/// the JSON), so it needs neither jq nor Python, and it costs a few milliseconds per reply.
enum StatusLineBridge {
    static let scriptName = "claude-statusline-bridge.sh"

    /// The script. `$1` is the user's previous status line command, if any, after an optional `--account=<key>` naming
    /// which Claude Code account (config folder) it runs for, so each account's reading goes to its own file.
    /// `DASHBAR_STATUSLINE_DIR` overrides where the reading goes (tests use it). Saving the reading can fail without
    /// affecting the status line.
    static let script = #"""
    #!/bin/sh
    # Dashbar's Claude Code status line bridge (version 2). Dashbar added it with your consent.
    # Claude Code runs this after each reply with the session's details as JSON on stdin. It saves only the
    # rate_limits part (your plan usage percentages and reset times) and the time to a file Dashbar reads, then
    # runs the status line you had before, if any, with the same input. It sends nothing anywhere.
    # Remove it in Dashbar's Settings, which puts your previous status line back.
    out_dir="${DASHBAR_STATUSLINE_DIR:-$HOME/Library/Caches/Dashbar}"
    account=
    case $1 in --account=*) account=$(printf '%s' "${1#--account=}" | /usr/bin/tr -cd 'a-f0-9'); shift ;; esac
    reading="$out_dir/claude-statusline${account:+-$account}.json"
    input=$(/bin/cat)

    save() {
      limits=$(printf '%s' "$input" | /usr/bin/plutil -extract rate_limits json -o - - 2>/dev/null) || return 0
      case $limits in '{'*'}') ;; *) return 0 ;; esac
      session=$(printf '%s' "$input" | /usr/bin/plutil -extract session_id raw -o - - 2>/dev/null | /usr/bin/tr -cd 'A-Za-z0-9_-')
      api=$(printf '%s' "$input" | /usr/bin/plutil -extract cost.total_api_duration_ms raw -o - - 2>/dev/null | /usr/bin/tr -cd '0-9.')
      seen="$out_dir/claude-statusline-sessions"
      /bin/mkdir -p "$seen" || return 0
      marker="$seen/${session:-unknown}"
      # Only a new reply brings new limits. Reruns of an idle session (on a timer, say) carry old ones: skip them.
      if [ -n "$api" ] && [ -f "$marker" ] && [ "$(/bin/cat "$marker")" = "$api" ]; then return 0; fi
      tmp="$out_dir/.claude-statusline.$$"
      if printf '{"version":1,"written_at":%s,"rate_limits":%s}\n' "$(/bin/date +%s)" "$limits" >"$tmp" &&
        /bin/mv -f "$tmp" "$reading"; then
        printf '%s' "$api" >"$marker"
      else
        /bin/rm -f "$tmp"
      fi
      /usr/bin/find "$seen" -type f -mtime +2 -delete
    }
    (save) >/dev/null 2>&1

    previous=$1
    case $previous in *claude-statusline-bridge*) previous= ;; esac
    [ -n "$previous" ] || exit 0
    printf '%s\n' "$input" | /bin/sh -c "$previous"

    """#

    // MARK: Paths

    struct Paths {
        /// Claude Code's user settings file.
        var settings: URL
        /// Dashbar's own folder for the script, the install record and backups. Shared by the release and local builds.
        var support: URL
        /// Where the bridge saves readings (only used here to tidy up on removal).
        var readings: URL = ClaudeStatusLine.defaultURL.deletingLastPathComponent()
        /// Which account this is for (`ResolvedAccount.key`): nil for the default account, which keeps the original
        /// file names and command, so a bridge added before accounts existed carries on as it was.
        var account: String? = nil

        var script: URL { support.appendingPathComponent(StatusLineBridge.scriptName) }
        var record: URL { support.appendingPathComponent(account.map { "claude-statusline-install-\($0).json" } ?? "claude-statusline-install.json") }
        var backups: URL { support.appendingPathComponent("Backups") }
        /// The file this account's bridge writes.
        var reading: URL { readings.appendingPathComponent(ClaudeStatusLine.fileName(account: account)) }

        /// One account's settings.json, and its own reading and record.
        static func forAccount(_ account: ResolvedAccount) -> Paths {
            Paths(settings: account.settingsFile, support: homeDir.appendingPathComponent("Library/Application Support/Dashbar"),
                  account: account.key)
        }

        /// `~/.claude/settings.json`, or the folder `CLAUDE_CONFIG_DIR` names when Dashbar was started with it.
        static func `default`(environment: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
            let config = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? homeDir.appendingPathComponent(".claude")
            return Paths(settings: config.appendingPathComponent("settings.json"),
                         support: homeDir.appendingPathComponent("Library/Application Support/Dashbar"))
        }
    }

    // MARK: Status

    enum Status: Equatable {
        /// Not added. `current` is the user's own status line command, if they have one.
        case notInstalled(current: String?)
        /// Added. `previous` is the status line it runs after saving the limits, if there was one.
        case installed(previous: String?)
        /// Claude Code's settings can't be read: what's wrong and what to do.
        case unreadable(String)

        var isInstalled: Bool { if case .installed = self { return true } else { return false } }
    }

    enum Failure: LocalizedError, Equatable {
        case invalidSettings(String)
        case noClaudeFolder(String)
        case busy
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidSettings(let why):
                return "Claude Code's settings.json isn't valid JSON (\(why)). Dashbar didn't change it. Fix the file, or let Claude Code rewrite it, then try again."
            case .noClaudeFolder(let path):
                return "Couldn't find Claude Code's settings folder (\(Fmt.tilde(path))). Run `claude` in a terminal once, then try again."
            case .busy:
                return "Claude Code's settings kept changing while Dashbar was saving. Nothing was changed. Try again in a moment."
            case .writeFailed(let why):
                return "Couldn't save Claude Code's settings (\(why)). Nothing was changed."
            }
        }
    }

    static func status(_ paths: Paths) -> Status {
        let text: String?
        do { text = try readSettings(paths.settings) } catch { return .unreadable(error.localizedDescription) }
        guard let text else { return .notInstalled(current: nil) }
        let parsed: [String: Any]
        do { parsed = try object(text) } catch { return .unreadable(error.localizedDescription) }
        let command = (parsed["statusLine"] as? [String: Any])?["command"] as? String
        if let command, isBridge(command) {
            let record = Record.load(paths.record).flatMap { $0.settingsPath == paths.settings.path ? $0 : nil }
            return .installed(previous: record.map(\.previousCommand) ?? previousCommand(inBridgeCommand: command))
        }
        return .notInstalled(current: command)
    }

    // MARK: Install and remove

    /// Points Claude Code's status line at the bridge, keeping any other settings of the existing one (padding,
    /// refresh interval). Records the previous status line so `uninstall` can put it back exactly, and backs up
    /// settings.json first. Running it again only refreshes the script.
    static func install(_ paths: Paths, now: Date = Date()) throws {
        try writeScript(paths)
        try editSettings(paths, now: now) { text in
            let doc = try Document(text ?? "")
            let existing = doc.member("statusLine")
            var entry: [String: Any] = [:]
            if let existing, let old = try? object(existing.raw) {
                if let command = old["command"] as? String, isBridge(command) { return nil }   // already added
                entry = old
            }
            let previousCommand = entry["command"] as? String
            entry["type"] = "command"
            entry["command"] = bridgeCommand(script: paths.script, previous: previousCommand, account: paths.account)
            try Record(settingsPath: paths.settings.path, previousStatusLine: existing?.raw, installedAt: now).save(paths.record)
            return doc.setting("statusLine", to: try json(entry))
        }
    }

    /// Puts back the status line the user had before (or none), exactly as it was, and removes the script. If the
    /// status line is no longer the bridge (the user changed it since), settings.json is left alone.
    static func uninstall(_ paths: Paths, now: Date = Date()) throws {
        if FileManager.default.fileExists(atPath: paths.settings.deletingLastPathComponent().path) {
            try editSettings(paths, now: now) { text in
                guard let text else { return nil }
                let doc = try Document(text)
                guard let member = doc.member("statusLine"),
                      let entry = try? object(member.raw),
                      let command = entry["command"] as? String, isBridge(command) else { return nil }
                if let record = Record.load(paths.record), record.settingsPath == paths.settings.path {
                    if let previous = record.previousStatusLine { return doc.setting("statusLine", to: previous, verbatim: true) }
                    return doc.removing("statusLine")
                }
                // No record (deleted, or made for another settings file): rebuild it from the command itself.
                guard let previous = previousCommand(inBridgeCommand: command) else { return doc.removing("statusLine") }
                var restored = entry
                restored["command"] = previous
                return doc.setting("statusLine", to: try json(restored))
            }
        }
        let fm = FileManager.default
        try? fm.removeItem(at: paths.record)
        try? fm.removeItem(at: paths.reading)
        // The script and the reply markers are shared: they go only with the last account's bridge.
        let others = ((try? fm.contentsOfDirectory(atPath: paths.support.path)) ?? [])
            .filter { $0.hasPrefix("claude-statusline-install") && $0.hasSuffix(".json") }
        guard others.isEmpty else { return }
        try? fm.removeItem(at: paths.script)
        try? fm.removeItem(at: paths.readings.appendingPathComponent("claude-statusline-sessions"))
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

    /// `/bin/sh '<script>' '<previous command>'`. Running it through `/bin/sh` means it works even if the script
    /// loses its executable bit, and the previous command travels as an argument, so settings.json alone says
    /// what to put back.
    static func bridgeCommand(script: URL, previous: String?, account: String? = nil) -> String {
        var command = "/bin/sh " + shellQuote(script.path)
        if let account { command += " --account=" + account }
        if let previous, !previous.isEmpty { command += " " + shellQuote(previous) }
        return command
    }

    static func isBridge(_ command: String) -> Bool { command.contains(scriptName) }

    static func previousCommand(inBridgeCommand command: String) -> String? {
        var words = shellWords(command)
        if words.count >= 3, words[2].hasPrefix("--account=") { words.remove(at: 2) }
        guard words.count >= 3, words[1].hasSuffix(scriptName) else { return nil }
        return words[2].isEmpty ? nil : words[2]
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    /// Splits the commands `bridgeCommand` writes: words separated by spaces, single quotes, backslash escapes.
    static func shellWords(_ s: String) -> [String] {
        var words: [String] = [], current = "", inWord = false, quoted = false, escape = false
        for ch in s {
            if escape { current.append(ch); escape = false; continue }
            if quoted {
                if ch == "'" { quoted = false } else { current.append(ch) }
                continue
            }
            switch ch {
            case "'": quoted = true; inWord = true
            case "\\": escape = true; inWord = true
            case " ", "\t", "\n":
                if inWord { words.append(current); current = ""; inWord = false }
            default: current.append(ch); inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }

    // MARK: The record of what was there before

    struct Record: Codable {
        var settingsPath: String
        /// The previous `statusLine` value, exactly as it was written in settings.json, or nil if there was none.
        var previousStatusLine: String?
        var installedAt: Date

        var previousCommand: String? {
            previousStatusLine.flatMap { try? StatusLineBridge.object($0) }?["command"] as? String
        }

        static func load(_ url: URL) -> Record? {
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        }

        func save(_ url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        }
    }

    // MARK: Editing settings.json

    /// Reads the file (nil if there is none), works out the new text, then re-reads it just before writing: if Claude
    /// Code changed it in between, starts again from the new contents. `transform` returns nil for "no change".
    static func editSettings(_ paths: Paths, now: Date, _ transform: (String?) throws -> String?) throws {
        let url = paths.settings.resolvingSymlinksInPath()   // a symlinked settings.json (dotfiles) stays a symlink
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else {
            throw Failure.noClaudeFolder(url.deletingLastPathComponent().path)
        }
        for _ in 0..<3 {
            let before = try readSettings(url)
            guard let after = try transform(before) else { return }
            guard try readSettings(url) == before else { continue }
            if let before { backup(before, paths: paths, now: now) }
            try write(after, to: url)
            return
        }
        throw Failure.busy
    }

    static func readSettings(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw Failure.writeFailed("couldn't read it: \(error.localizedDescription)") }
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.invalidSettings("it isn't UTF-8 text") }
        return text
    }

    private static func write(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).dashbar-\(getpid())")
        do {
            try Data(text.utf8).write(to: tmp)
            let mode = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
            try fm.setAttributes([.posixPermissions: mode ?? NSNumber(value: 0o644)], ofItemAtPath: tmp.path)
            guard rename(tmp.path, url.path) == 0 else { throw Failure.writeFailed(String(cString: strerror(errno))) }
        } catch let failure as Failure {
            try? fm.removeItem(at: tmp)
            throw failure
        } catch {
            try? fm.removeItem(at: tmp)
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    /// Keeps the five most recent copies of settings.json from before Dashbar changed it, in Dashbar's own folder.
    private static func backup(_ text: String, paths: Paths, now: Date) {
        let fm = FileManager.default
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        try? fm.createDirectory(at: paths.backups, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: paths.backups.appendingPathComponent("claude-settings-\(f.string(from: now)).json"))
        let old = ((try? fm.contentsOfDirectory(atPath: paths.backups.path)) ?? [])
            .filter { $0.hasPrefix("claude-settings-") }.sorted().dropLast(5)
        for name in old { try? fm.removeItem(at: paths.backups.appendingPathComponent(name)) }
    }

    /// The settings as an object; empty text counts as `{}`. Throws `invalidSettings` for anything else.
    static func object(_ text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed]) }
        catch { throw Failure.invalidSettings("it couldn't be parsed") }
        guard let object = value as? [String: Any] else { throw Failure.invalidSettings("it isn't a JSON object") }
        return object
    }

    /// Two-space indented JSON, the way Claude Code writes its settings, with `type` and `command` first.
    static func json(_ value: [String: Any]) throws -> String {
        let first = ["type", "command"].filter { value[$0] != nil }
        let rest = value.keys.filter { !first.contains($0) }.sorted()
        var lines: [String] = []
        for key in first + rest {
            let k = String(decoding: try JSONSerialization.data(withJSONObject: key, options: .fragmentsAllowed), as: UTF8.self)
            let v = String(decoding: try JSONSerialization.data(withJSONObject: value[key]!,
                                                                options: [.fragmentsAllowed, .withoutEscapingSlashes, .sortedKeys]),
                           as: UTF8.self)
            lines.append("  \(k): \(v)")
        }
        return lines.isEmpty ? "{}" : "{\n" + lines.joined(separator: ",\n") + "\n}"
    }

    /// The top level of a settings file, as text, so one member can be replaced, added or removed while every other
    /// byte (key order, spacing, the user's own formatting) stays as it was.
    struct Document {
        struct Member {
            let name: String
            /// Byte offsets: where the key's opening quote is, and where the value starts and ends.
            let start: Int, valueStart: Int, valueEnd: Int
            let raw: String
        }

        let bytes: [UInt8]
        let open: Int, close: Int
        let members: [Member]

        init(_ text: String) throws {
            _ = try StatusLineBridge.object(text)   // refuse anything that isn't valid JSON before touching it
            var b = Array(text.utf8)
            if b.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { b = Array("{}\n".utf8) }
            bytes = b
            var p = Scanner(bytes: b)
            p.skipSpace()
            guard p.peek == UInt8(ascii: "{") else { throw Failure.invalidSettings("it isn't a JSON object") }
            open = p.i
            p.i += 1
            var found: [Member] = []
            while true {
                p.skipSpace()
                guard let c = p.peek else { throw Failure.invalidSettings("it ends early") }
                if c == UInt8(ascii: "}") { break }
                if c == UInt8(ascii: ",") { p.i += 1; continue }
                let start = p.i
                let keyEnd = try p.skipString()
                let name = (try? JSONSerialization.jsonObject(with: Data(b[start..<keyEnd]), options: .fragmentsAllowed)) as? String ?? ""
                p.skipSpace()
                guard p.peek == UInt8(ascii: ":") else { throw Failure.invalidSettings("unexpected text") }
                p.i += 1
                p.skipSpace()
                let valueStart = p.i
                try p.skipValue()
                found.append(Member(name: name, start: start, valueStart: valueStart, valueEnd: p.i,
                                    raw: String(decoding: b[valueStart..<p.i], as: UTF8.self)))
            }
            close = p.i
            members = found
        }

        func member(_ name: String) -> Member? { members.last { $0.name == name } }

        /// The indentation of the line a member starts on, or nil if it shares its line with something else.
        private func indent(at offset: Int) -> String? {
            var i = offset - 1
            while i >= 0, bytes[i] == 0x20 || bytes[i] == 0x09 { i -= 1 }
            guard i >= 0, bytes[i] == 0x0A else { return nil }
            return String(decoding: bytes[(i + 1)..<offset], as: UTF8.self)
        }

        private func splice(_ range: Range<Int>, _ text: String) -> String {
            String(decoding: Array(bytes[..<range.lowerBound]) + Array(text.utf8) + Array(bytes[range.upperBound...]), as: UTF8.self)
        }

        /// `value` is JSON text. A member that exists is replaced in place; a new one goes last, indented like the others.
        /// `verbatim` puts the text back exactly as given (restoring what was there), without re-indenting it.
        func setting(_ name: String, to value: String, verbatim: Bool = false) -> String {
            if let m = member(name) {
                return splice(m.valueStart..<m.valueEnd, verbatim ? value : indented(value, by: indent(at: m.start) ?? ""))
            }
            let key = String(decoding: (try? JSONSerialization.data(withJSONObject: name, options: .fragmentsAllowed)) ?? Data(), as: UTF8.self)
            guard let last = members.last else {
                return splice((open + 1)..<close, "\n  \(key): \(indented(value, by: "  "))\n")
            }
            if let pad = indent(at: last.start) {
                return splice(last.valueEnd..<last.valueEnd, ",\n\(pad)\(key): \(indented(value, by: pad))")
            }
            return splice(last.valueEnd..<last.valueEnd, ", \(key): \(value)")
        }

        /// Removes a member and the comma that joined it to its neighbours.
        func removing(_ name: String) -> String {
            guard let i = members.lastIndex(where: { $0.name == name }) else { return String(decoding: bytes, as: UTF8.self) }
            let m = members[i]
            if i + 1 < members.count { return splice(m.start..<members[i + 1].start, "") }
            if i > 0 { return splice(members[i - 1].valueEnd..<m.valueEnd, "") }
            return splice((open + 1)..<close, "")
        }

        private func indented(_ value: String, by pad: String) -> String {
            value.components(separatedBy: "\n").enumerated().map { $0.offset == 0 ? $0.element : pad + $0.element }
                .joined(separator: "\n")
        }

        struct Scanner {
            let bytes: [UInt8]
            var i = 0
            var peek: UInt8? { i < bytes.count ? bytes[i] : nil }

            mutating func skipSpace() {
                while let c = peek, c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { i += 1 }
            }

            /// From an opening quote to just past the closing one. Returns where it ended.
            mutating func skipString() throws -> Int {
                guard peek == UInt8(ascii: "\"") else { throw Failure.invalidSettings("unexpected text") }
                i += 1
                while let c = peek {
                    i += 1
                    if c == UInt8(ascii: "\\") { i += 1 } else if c == UInt8(ascii: "\"") { return i }
                }
                throw Failure.invalidSettings("an unfinished string")
            }

            mutating func skipValue() throws {
                guard let c = peek else { throw Failure.invalidSettings("it ends early") }
                if c == UInt8(ascii: "\"") { _ = try skipString(); return }
                if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") {
                    var depth = 0
                    while let c = peek {
                        if c == UInt8(ascii: "\"") { _ = try skipString(); continue }
                        if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") { depth += 1 }
                        if c == UInt8(ascii: "}") || c == UInt8(ascii: "]") { depth -= 1 }
                        i += 1
                        if depth == 0 { return }
                    }
                    throw Failure.invalidSettings("it ends early")
                }
                let ends: [UInt8] = [UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x0A, 0x0D, 0x09]
                while let c = peek, !ends.contains(c) { i += 1 }
            }
        }
    }
}

/// Reads what the bridge saved: the plan limits from Claude Code's most recent reply.
enum ClaudeStatusLine {
    /// Shared by every copy of Dashbar (the release and a local build), like `claude-plan.json`.
    static let defaultURL = homeDir.appendingPathComponent("Library/Caches/Dashbar/claude-statusline.json")

    /// "claude-statusline.json" for the default account, "claude-statusline-<key>.json" for another.
    static func fileName(account: String?) -> String {
        account.map { "claude-statusline-\($0).json" } ?? "claude-statusline.json"
    }

    /// Where an account's bridge saves its reading.
    static func url(for account: ResolvedAccount) -> URL {
        defaultURL.deletingLastPathComponent().appendingPathComponent(fileName(account: account.key))
    }

    static let unrecognisedMessage = "Claude Code's status line data had no limits Dashbar recognises. Its format may have changed."

    struct Reading {
        /// When the bridge saved it, which is just after the Claude Code reply that brought it.
        var writtenAt: Date
        /// Every window in the file, including any whose reset time has passed; see `current(now:)`.
        var limits: [RateLimit]
        /// The file had limits in a shape Dashbar doesn't know: show a warning rather than nothing.
        var unrecognised = false

        /// Without windows that have already reset: their numbers no longer apply.
        func current(now: Date = Date()) -> [RateLimit] {
            limits.filter { ($0.resetsAt ?? .distantFuture) > now }
        }
    }

    static func read(from url: URL = defaultURL) -> Reading? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    /// `{"version":1,"written_at":<epoch s>,"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":<epoch s>},…}}`.
    /// Each window may be absent.
    static func parse(_ data: Data) -> Reading? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data.isEmpty ? nil : Reading(writtenAt: .distantPast, limits: [], unrecognised: true)
        }
        let written = (obj["written_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? .distantPast
        guard let windows = obj["rate_limits"] as? [String: Any] else {
            return Reading(writtenAt: written, limits: [], unrecognised: true)
        }
        let order = ["five_hour": 0, "seven_day": 1, "seven_day_sonnet": 2, "seven_day_opus": 3, "spend_limit": 5]
        let limits = windows.compactMap { key, value -> (Int, RateLimit)? in
            guard let window = value as? [String: Any],
                  let used = (window["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            var length = ClaudePlanLimits.window(for: key)
            if key == "spend_limit" {
                switch window["period"] as? String {
                case "daily"?: length = 86400
                case "weekly"?: length = 7 * 86400
                case "monthly"?: length = 30 * 86400
                default: length = nil
                }
            }
            return (order[key] ?? 9, RateLimit(label: ClaudePlanLimits.label(for: key), usedPercent: used, resetsAt: reset, window: length))
        }
        .sorted { ($0.0, $0.1.label) < ($1.0, $1.1.label) }
        .map(\.1)
        return Reading(writtenAt: written, limits: limits, unrecognised: limits.isEmpty && !windows.isEmpty)
    }

    /// Under limits from the status line once they're a while old: "Updated 25m ago · refreshes after your next
    /// Claude Code reply". Nil while they're recent.
    static func ageLine(writtenAt: Date, now: Date) -> String? {
        guard now.timeIntervalSince(writtenAt) >= 5 * 60 else { return nil }
        return "Updated \(Fmt.ago(writtenAt, now: now)) ago · refreshes after your next Claude Code reply"
    }
}
