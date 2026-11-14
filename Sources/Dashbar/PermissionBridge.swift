import Foundation

/// Answering Claude Code's permission prompts from Dashbar. Opt-in and off by default: the first feature that acts on
/// an agent rather than only reading about it.
///
/// Claude Code runs `PermissionRequest` hooks when it is about to ask the user to allow a tool
/// (https://code.claude.com/docs/en/hooks#permissionrequest). The hook gets the request as JSON on stdin (`session_id`,
/// `cwd`, `tool_name`, `tool_input`, …) and may answer by printing
/// `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny",…}}}` and exiting 0.
/// A hook that prints nothing and exits 0 leaves the permission flow unchanged, so Claude Code asks in the terminal as
/// usual; one that times out has its output discarded, with the same result.
///
/// With the user's consent Dashbar adds one such hook: a `/bin/sh` script in Application Support (so it keeps working,
/// or harmlessly does nothing, whatever happens to the app). While Dashbar is running it leaves the request in a
/// folder only the user can read, and waits a bounded time for Dashbar's answer. Safety rules, all enforced by the script:
/// - It never answers by itself. Only an answer file Dashbar writes when the user clicks Allow or Deny makes it print.
/// - On a timeout, with Dashbar not running, or on any error it prints nothing, leaving the terminal prompt to answer.
///
/// Claude Code shows its own prompt in the terminal at once and runs the hook beside it (checked live with Claude Code
/// 2.1.325): whichever answers first wins, and an answer in the terminal leaves the hook running, which Dashbar notices
/// from the session file (`PermissionRequest.answeredInTerminal`). So the wait only bounds how long Dashbar offers an
/// answer; it never holds the terminal back.
/// - Request IDs are 128 random bits, files are user-only (0700 folder, 0600 files), and the folder must be the user's.
///
/// Any process running as the user could write an answer file, but such a process could equally type into the terminal
/// or edit Claude Code's settings, so this opens nothing that wasn't already open to it.
enum PermissionBridge {
    static let scriptName = "claude-permission-bridge.sh"
    /// What Claude Code shows while the script runs, if it shows anything: in practice its own prompt covers it.
    static let statusMessage = "Waiting for an answer in Dashbar"
    /// Longest the script waits for an answer, whatever the setting says. The hook's own timeout sits above this, so
    /// Claude Code never has to cancel it.
    static let maxWait = 300
    static let hookTimeout = 330
    static let waitChoices = [30, 60, 120, 300]
    /// Long by default: the terminal prompt is up the whole time, so waiting costs nothing, and someone away from the
    /// terminal can still answer from the notification minutes later.
    static let defaultWait = 300
    static let denyMessage = "The user denied this in Dashbar."

    /// `$DASHBAR_PERMISSION_DIR` overrides the folder (tests use it). Everything the script runs is an absolute path to a
    /// tool every Mac has; `plutil` reads and writes the JSON.
    static let script = #"""
    #!/bin/sh
    # Dashbar's Claude Code permission bridge (version 2). Dashbar added it with your consent.
    # Claude Code runs this when it is about to ask you to allow a tool. If Dashbar is running, this shows the request
    # there and waits a short while for you to click Allow or Deny, then hands Claude Code that answer. If you don't
    # answer in Dashbar, if Dashbar isn't running, or if anything goes wrong, it prints nothing and Claude Code asks you
    # in the terminal as usual. It never answers by itself and sends nothing anywhere.
    # Remove it in Dashbar's Settings, under Labs.
    dir="${DASHBAR_PERMISSION_DIR:-$HOME/Library/Application Support/Dashbar/Permissions}"
    umask 077
    id=
    # Which Claude Code account (config folder) this hook is in, so Dashbar can say so. Hex digits only.
    account=
    case $1 in --account=*) account=$(printf '%s' "${1#--account=}" | /usr/bin/tr -cd 'a-f0-9') ;; esac

    cleanup() {
      [ -n "$id" ] && /bin/rm -f "$dir/requests/$id.json" "$dir/requests/.$id.tmp" "$dir/decisions/$id"
    }

    # Each running copy of Dashbar rewrites its own alive.<app> file every few seconds while it can answer.
    # Sets $beat to the first one that is fresh.
    alive() {
      now=$(/bin/date +%s)
      for beat in "$dir"/alive.*; do
        [ -f "$beat" ] && [ -O "$beat" ] || continue
        seen=$(/usr/bin/stat -f %m "$beat") || continue
        [ $((now - seen)) -lt 45 ] && return 0
      done
      return 1
    }

    field() { printf '%s' "$input" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null; }

    main() {
      input=$(/bin/cat)   # read it all first, so Claude Code never writes to a closed pipe
      [ -d "$dir/requests" ] && [ -d "$dir/decisions" ] && [ -O "$dir" ] || return 0
      alive || return 0
      [ "$(field hook_event_name)" = PermissionRequest ] || return 0
      tool=$(field tool_name)
      # These two need an answer typed into Claude Code itself, which a plain allow can't give.
      case $tool in ''|AskUserQuestion|ExitPlanMode) return 0 ;; esac

      limit=$(/usr/bin/sed -n 's/^wait=\([0-9][0-9]*\)$/\1/p' "$beat" | /usr/bin/head -n 1)
      [ -n "$limit" ] || limit=300
      [ "$limit" -le 300 ] || limit=300
      [ "$limit" -ge 5 ] || limit=5

      # The tool's input, without file contents and edits: Dashbar shows the command, path or address.
      ti=$(printf '%s' "$input" | /usr/bin/plutil -extract tool_input json -o - - 2>/dev/null) || ti='{}'
      for key in content new_string old_string edits new_source; do
        t=$(printf '%s' "$ti" | /usr/bin/plutil -remove "$key" -o - - 2>/dev/null) && ti=$t
      done
      [ ${#ti} -le 16384 ] || ti='{}'

      id=$(/usr/bin/od -An -N16 -tx1 /dev/urandom | /usr/bin/tr -d ' \n')
      case $id in *[!0-9a-f]*) id=; return 0 ;; esac
      [ ${#id} -eq 32 ] || { id=; return 0; }
      created=$(/bin/date +%s)
      tmp="$dir/requests/.$id.tmp"
      printf '{"version":1}' >"$tmp" || return 0
      /usr/bin/plutil -insert id -string "$id" "$tmp" &&
        /usr/bin/plutil -insert pid -integer "$$" "$tmp" &&
        /usr/bin/plutil -insert created -integer "$created" "$tmp" &&
        /usr/bin/plutil -insert wait -integer "$limit" "$tmp" &&
        /usr/bin/plutil -insert tool_name -string "$tool" "$tmp" &&
        /usr/bin/plutil -insert tool_input -json "$ti" "$tmp" &&
        /usr/bin/plutil -insert session_id -string "$(field session_id)" "$tmp" &&
        /usr/bin/plutil -insert cwd -string "$(field cwd)" "$tmp" &&
        /usr/bin/plutil -insert agent_type -string "$(field agent_type)" "$tmp" &&
        /usr/bin/plutil -insert account -string "$account" "$tmp" || return 0
      /bin/mv -f "$tmp" "$dir/requests/$id.json" || return 0

      end=$((created + limit))
      n=0
      while :; do
        answer="$dir/decisions/$id"
        if [ -f "$answer" ] && [ -O "$answer" ]; then
          case $(/usr/bin/head -c 16 "$answer") in
            allow) printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}' ;;
            deny) printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"The user denied this in Dashbar."}}}' ;;
          esac
          return 0
        fi
        # Dashbar handed it back to the terminal (or was removed): stop waiting.
        [ -f "$dir/requests/$id.json" ] || return 0
        n=$((n + 1))
        if [ $((n % 8)) -eq 0 ]; then
          [ "$(/bin/date +%s)" -lt "$end" ] || return 0
          alive || return 0
        fi
        /bin/sleep 0.25
      done
    }

    trap 'cleanup; exit 0' HUP INT TERM
    main 2>/dev/null
    cleanup
    exit 0

    """#

    // MARK: Paths

    struct Paths {
        /// Claude Code's user settings file.
        var settings: URL
        /// Dashbar's own folder for scripts and backups, shared with the status line bridge.
        var support: URL
        /// Which account this is for (`ResolvedAccount.key`): nil for the default account, which keeps the original
        /// record name and command, so a hook added before accounts existed carries on as it was. The script and the
        /// queue are shared by every account.
        var account: String? = nil

        var script: URL { support.appendingPathComponent(PermissionBridge.scriptName) }
        /// Where requests and answers pass between the script and Dashbar. User-only.
        var queue: URL { support.appendingPathComponent("Permissions") }
        var record: URL {
            support.appendingPathComponent(account.map { "claude-permission-install-\($0).json" } ?? "claude-permission-install.json")
        }
        /// The status line bridge's paths, for its settings editing and backups.
        var editing: StatusLineBridge.Paths { StatusLineBridge.Paths(settings: settings, support: support) }

        static func `default`(environment: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
            let p = StatusLineBridge.Paths.default(environment: environment)
            return Paths(settings: p.settings, support: p.support)
        }

        /// One account's settings.json and its own install record.
        static func forAccount(_ account: ResolvedAccount) -> Paths {
            let p = StatusLineBridge.Paths.forAccount(account)
            return Paths(settings: p.settings, support: p.support, account: p.account)
        }
    }

    enum Status: Equatable {
        case notInstalled
        case installed
        /// Claude Code's settings can't be read: what's wrong.
        case unreadable(String)

        var isInstalled: Bool { self == .installed }
    }

    static func status(_ paths: Paths) -> Status {
        do {
            guard let text = try StatusLineBridge.readSettings(paths.settings) else { return .notInstalled }
            let settings = try StatusLineBridge.object(text)
            return ourHandlerCount(in: settings["hooks"]) > 0 ? .installed : .notInstalled
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    // MARK: The command and the hook entry

    /// `/bin/sh '<script>' [--account=<key>]`: shell form, which every Claude Code version with hooks runs, and which
    /// keeps working if the script loses its executable bit. The account tells Dashbar which account a request is from.
    static func command(_ paths: Paths) -> String {
        "/bin/sh " + StatusLineBridge.shellQuote(paths.script.path) + (paths.account.map { " --account=" + $0 } ?? "")
    }

    static func isOurs(_ command: String) -> Bool { command.contains(scriptName) }

    /// The matcher group Dashbar adds to `hooks.PermissionRequest`, as JSON text with `pad` as its indentation.
    static func group(_ paths: Paths, pad: String) -> String {
        let q = { (s: String) in StatusLineBridge.jsonString(s) }
        let i1 = pad + "  ", i2 = pad + "    ", i3 = pad + "      "
        return "{\n"
            + "\(i1)\"matcher\": \"*\",\n"
            + "\(i1)\"hooks\": [\n"
            + "\(i2){\n"
            + "\(i3)\"type\": \"command\",\n"
            + "\(i3)\"command\": \(q(command(paths))),\n"
            + "\(i3)\"timeout\": \(hookTimeout),\n"
            + "\(i3)\"statusMessage\": \(q(statusMessage))\n"
            + "\(i2)}\n"
            + "\(i1)]\n"
            + "\(pad)}"
    }

    /// How many of Dashbar's handlers `hooks.PermissionRequest` holds.
    static func ourHandlerCount(in hooks: Any?) -> Int {
        let groups = (hooks as? [String: Any])?["PermissionRequest"] as? [Any] ?? []
        return groups.reduce(0) { total, group in
            let handlers = (group as? [String: Any])?["hooks"] as? [Any] ?? []
            return total + handlers.filter { ((($0 as? [String: Any])?["command"]) as? String).map(isOurs) ?? false }.count
        }
    }

    /// A group made only of Dashbar's handlers, which removing takes out whole.
    private static func isOurGroup(_ group: Any) -> Bool {
        guard let handlers = (group as? [String: Any])?["hooks"] as? [Any], !handlers.isEmpty else { return false }
        return handlers.allSatisfy { ((($0 as? [String: Any])?["command"]) as? String).map(isOurs) ?? false }
    }

    // MARK: Install and remove

    /// Adds Dashbar's hook to `hooks.PermissionRequest` after any the user has, changing no other byte of the file.
    /// Backs up settings.json first. Running it again only refreshes the script and the folder.
    static func install(_ paths: Paths, now: Date = Date()) throws {
        try writeScript(paths)
        try prepareQueue(paths)
        try StatusLineBridge.editSettings(paths.editing, now: now) { text in
            let doc = try StatusLineBridge.Document(text ?? "")
            guard let hooksMember = doc.member("hooks") else {
                try Record(settingsPath: paths.settings.path, hadHooks: false).save(paths.record)
                // Indented relative to the key; `setting` lines it up with the other settings.
                return doc.setting("hooks", to: "{\n  \"PermissionRequest\": [\n    \(group(paths, pad: "    "))\n  ]\n}")
            }
            guard let hooks = try? StatusLineBridge.object(hooksMember.raw) else {
                throw StatusLineBridge.Failure.invalidSettings("its hooks setting isn't an object")
            }
            if ourHandlerCount(in: hooks) > 0 {
                // Already added. Keep a record, so the shared script stays while this account uses it.
                if Record.load(paths.record) == nil { try Record(settingsPath: paths.settings.path, hadHooks: true).save(paths.record) }
                return nil
            }
            try Record(settingsPath: paths.settings.path, hadHooks: true).save(paths.record)
            let hooksDoc = try StatusLineBridge.Document(hooksMember.raw)
            let hooksPad = lineIndent(doc.bytesText, at: hooksMember.start) ?? ""
            let newHooks: String
            if let list = hooksDoc.member("PermissionRequest") {
                guard hooks["PermissionRequest"] is [Any] else {
                    throw StatusLineBridge.Failure.invalidSettings("its PermissionRequest hooks aren't a list")
                }
                let keyPad = lineIndent(hooksMember.raw, at: list.start) ?? hooksPad + "  "
                let array = try ArrayText(list.raw)
                let elementPad = array.elementIndent ?? keyPad + "  "
                let appended = array.appending(group(paths, pad: elementPad), closingPad: keyPad, elementPad: elementPad)
                newHooks = hooksDoc.setting("PermissionRequest", to: appended, verbatim: true)
            } else if hooksDoc.members.isEmpty {
                let keyPad = hooksPad + "  "
                newHooks = "{\n\(keyPad)\"PermissionRequest\": [\n\(keyPad)  \(group(paths, pad: keyPad + "  "))\n\(keyPad)]\n\(hooksPad)}"
            } else {
                // Indented relative to the key; `setting` lines it up with the user's other hook events.
                newHooks = hooksDoc.setting("PermissionRequest", to: "[\n  \(group(paths, pad: "  "))\n]")
            }
            return doc.setting("hooks", to: newHooks, verbatim: true)
        }
    }

    /// Takes out only Dashbar's hook, leaving the user's own hooks as they were, and removes the script and the folder.
    /// When nothing else changed since, the file goes back to exactly how it was before.
    static func uninstall(_ paths: Paths, now: Date = Date()) throws {
        if FileManager.default.fileExists(atPath: paths.settings.deletingLastPathComponent().path) {
            try StatusLineBridge.editSettings(paths.editing, now: now) { text in
                guard let text else { return nil }
                let doc = try StatusLineBridge.Document(text)
                guard let hooksMember = doc.member("hooks"), let hooks = try? StatusLineBridge.object(hooksMember.raw),
                      ourHandlerCount(in: hooks) > 0 else { return nil }
                let hooksDoc = try StatusLineBridge.Document(hooksMember.raw)
                guard let list = hooksDoc.member("PermissionRequest"), let groups = hooks["PermissionRequest"] as? [Any] else { return nil }
                // Take out Dashbar's own groups as text, last first so earlier offsets stay right.
                var arrayText = list.raw
                var remaining = try ArrayText(arrayText)
                for index in groups.indices.reversed() where isOurGroup(groups[index]) && index < remaining.elements.count {
                    arrayText = remaining.removing(index)
                    remaining = try ArrayText(arrayText)
                }
                // A group the user merged Dashbar's handler into: rewrite just that list without it.
                if let left = try? JSONSerialization.jsonObject(with: Data(arrayText.utf8)) as? [Any],
                   ourHandlerCount(in: ["PermissionRequest": left]) > 0 {
                    let cleaned: [Any] = left.compactMap { g in
                        guard var group = g as? [String: Any], let handlers = group["hooks"] as? [Any] else { return g }
                        let kept = handlers.filter { !(((($0 as? [String: Any])?["command"]) as? String).map(isOurs) ?? false) }
                        if kept.isEmpty { return nil }
                        group["hooks"] = kept
                        return group
                    }
                    let data = try JSONSerialization.data(withJSONObject: cleaned, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                    arrayText = String(decoding: data, as: UTF8.self)
                }
                let emptied = ((try? JSONSerialization.jsonObject(with: Data(arrayText.utf8))) as? [Any])?.isEmpty ?? false
                guard emptied else {
                    return doc.setting("hooks", to: hooksDoc.setting("PermissionRequest", to: arrayText, verbatim: true), verbatim: true)
                }
                let record = Record.load(paths.record).flatMap { $0.settingsPath == paths.settings.path ? $0 : nil }
                if hooksDoc.members.count == 1, record?.hadHooks != true {
                    return doc.removing("hooks")   // Dashbar made the hooks setting: take it out whole
                }
                return doc.setting("hooks", to: hooksDoc.removing("PermissionRequest"), verbatim: true)
            }
        }
        let fm = FileManager.default
        try? fm.removeItem(at: paths.record)
        // The script and the queue are shared: they go only with the last account's hook.
        guard !isInUse(paths) else { return }
        try? fm.removeItem(at: paths.script)
        // Any script still waiting sees its request gone and stops; the terminal prompt is still there to answer.
        try? fm.removeItem(at: paths.queue)
    }

    /// Some account still has Dashbar's hook, going by the install records.
    static func isInUse(_ paths: Paths) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: paths.support.path)) ?? [])
            .contains { $0.hasPrefix("claude-permission-install") && $0.hasSuffix(".json") }
    }

    /// Whether settings.json had a `hooks` setting before Dashbar added one, so removing puts back exactly that.
    struct Record: Codable {
        var settingsPath: String
        var hadHooks: Bool

        static func load(_ url: URL) -> Record? {
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        }

        func save(_ url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        }
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
            throw StatusLineBridge.Failure.writeFailed(error.localizedDescription)
        }
    }

    /// The request and answer folders, readable by this user only.
    static func prepareQueue(_ paths: Paths) throws {
        let fm = FileManager.default
        do {
            for dir in [paths.queue, paths.queue.appendingPathComponent("requests"), paths.queue.appendingPathComponent("decisions")] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            }
        } catch {
            throw StatusLineBridge.Failure.writeFailed(error.localizedDescription)
        }
    }

    // MARK: Text helpers

    /// The indentation of the line `offset` starts on, or nil if something else comes first on that line.
    static func lineIndent(_ text: String, at offset: Int) -> String? {
        let bytes = Array(text.utf8)
        guard offset <= bytes.count else { return nil }
        var i = offset - 1
        while i >= 0, bytes[i] == 0x20 || bytes[i] == 0x09 { i -= 1 }
        guard i >= 0, bytes[i] == 0x0A else { return nil }
        return String(decoding: bytes[(i + 1)..<offset], as: UTF8.self)
    }

    /// A JSON array as text, so one element can be added or removed while every other byte stays as it was.
    struct ArrayText {
        let bytes: [UInt8]
        let open: Int, close: Int
        /// Byte ranges of each element's value.
        let elements: [Range<Int>]

        init(_ text: String) throws {
            bytes = Array(text.utf8)
            var p = StatusLineBridge.Document.Scanner(bytes: bytes)
            p.skipSpace()
            guard p.peek == UInt8(ascii: "[") else { throw StatusLineBridge.Failure.invalidSettings("a hooks list isn't a list") }
            open = p.i
            p.i += 1
            var found: [Range<Int>] = []
            while true {
                p.skipSpace()
                guard let c = p.peek else { throw StatusLineBridge.Failure.invalidSettings("it ends early") }
                if c == UInt8(ascii: "]") { break }
                if c == UInt8(ascii: ",") { p.i += 1; continue }
                let start = p.i
                try p.skipValue()
                found.append(start..<p.i)
            }
            close = p.i
            elements = found
        }

        private var text: String { String(decoding: bytes, as: UTF8.self) }

        /// The indentation of the last element, when elements sit on lines of their own.
        var elementIndent: String? { elements.last.flatMap { PermissionBridge.lineIndent(text, at: $0.lowerBound) } }

        private func splice(_ range: Range<Int>, _ new: String) -> String {
            String(decoding: Array(bytes[..<range.lowerBound]) + Array(new.utf8) + Array(bytes[range.upperBound...]), as: UTF8.self)
        }

        /// `value` goes last. An empty list becomes one element on its own line.
        func appending(_ value: String, closingPad: String, elementPad: String) -> String {
            guard let last = elements.last else {
                return splice(open..<(close + 1), "[\n\(elementPad)\(value)\n\(closingPad)]")
            }
            if let pad = PermissionBridge.lineIndent(text, at: last.lowerBound) {
                return splice(last.upperBound..<last.upperBound, ",\n\(pad)\(value)")
            }
            return splice(last.upperBound..<last.upperBound, ", \(value)")
        }

        /// Removes element `i` and the comma that joined it to its neighbours. Undoes `appending` exactly.
        func removing(_ i: Int) -> String {
            let e = elements[i]
            if i > 0 { return splice(elements[i - 1].upperBound..<e.upperBound, "") }
            if i + 1 < elements.count { return splice(e.lowerBound..<elements[i + 1].lowerBound, "") }
            return splice((open + 1)..<close, "")
        }
    }
}

extension StatusLineBridge.Document {
    var bytesText: String { String(decoding: bytes, as: UTF8.self) }
}

extension StatusLineBridge {
    /// A string as JSON text, without escaping slashes (paths read as they are).
    static func jsonString(_ s: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("\"\"".utf8),
               as: UTF8.self)
    }
}

// MARK: - Pending requests

/// One permission prompt the bridge left for Dashbar, waiting for an answer.
struct PermissionRequest: Identifiable, Equatable {
    let id: String
    let sessionId: String
    let cwd: String
    let tool: String
    /// The fields of the tool's input worth showing: `command`, `file_path`, `url`, `pattern`, `description`…
    let input: [String: String]
    /// A subagent's type when the request came from one.
    let agentType: String?
    let created: Date
    let expires: Date
    /// The waiting script's process, so a request whose script has gone (Claude Code quit, the session ended) is dropped.
    let pid: Int32
    /// The account whose hook sent it (`ResolvedAccount.key`), nil for the default account.
    var account: String? = nil

    enum Answer: String { case allow, deny, terminal = "ask" }

    /// 32 lowercase hex digits: the 128 random bits the script makes.
    static func isValidID(_ id: String) -> Bool { id.utf8.count == 32 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }

    /// Parses a request file. Nil for anything that isn't one (wrong id, missing tool), which is then ignored.
    static func parse(_ data: Data) -> PermissionRequest? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = o["id"] as? String, isValidID(id),
              let tool = o["tool_name"] as? String, !tool.isEmpty,
              let created = (o["created"] as? NSNumber)?.doubleValue else { return nil }
        let wait = min(Double(PermissionBridge.maxWait), max(5, (o["wait"] as? NSNumber)?.doubleValue ?? Double(PermissionBridge.defaultWait)))
        var input: [String: String] = [:]
        if let raw = o["tool_input"] as? [String: Any] {
            for (key, value) in raw {
                if let s = value as? String { input[key] = s }
                else if let n = value as? NSNumber { input[key] = n.stringValue }
                else if JSONSerialization.isValidJSONObject(value),
                        let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) {
                    input[key] = String(decoding: data, as: UTF8.self)
                }
            }
        }
        let agent = (o["agent_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let account = (o["account"] as? String).flatMap { a in
            !a.isEmpty && a.utf8.count <= 64 && a.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) ? a : nil
        }
        return PermissionRequest(id: id, sessionId: o["session_id"] as? String ?? "", cwd: o["cwd"] as? String ?? "",
                                 tool: tool, input: input, agentType: agent,
                                 created: Date(timeIntervalSince1970: created),
                                 expires: Date(timeIntervalSince1970: created + wait),
                                 pid: (o["pid"] as? NSNumber)?.int32Value ?? 0, account: account)
    }

    /// The name of the account it came from, only while Dashbar reads more than one Claude Code account.
    func accountLabel(in accounts: [ResolvedAccount]) -> String? {
        guard accounts.count > 1 else { return nil }
        return accounts.first { $0.key == account }?.label
    }

    /// Still worth showing: not timed out, and its script still waiting.
    func isLive(now: Date, alive: (Int32) -> Bool = ClaudeSessions.isAlive) -> Bool {
        now < expires && pid > 1 && alive(pid)
    }

    var project: String { cwd.isEmpty ? "" : URL(fileURLWithPath: Fmt.root(fromCwd: cwd)).lastPathComponent }

    /// "Run a command", "Edit a file": what Claude wants to do, in words.
    var action: String {
        switch tool {
        case "Bash", "Monitor": return "Run a command"
        case "PowerShell": return "Run a PowerShell command"
        case "Edit", "MultiEdit": return "Edit a file"
        case "Write": return "Write a file"
        case "NotebookEdit": return "Edit a notebook"
        case "Read": return "Read a file"
        case "Glob", "Grep", "LS": return "Search files"
        case "WebFetch": return "Fetch a web page"
        case "WebSearch": return "Search the web"
        case "Agent", "Task": return "Start a subagent"
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
                if parts.count >= 3 { return "Use \(parts.dropFirst(2).joined(separator: "_")) from \(parts[1])" }
            }
            return "Use \(tool)"
        }
    }

    /// The command, path, address or pattern, cut to `limit` characters. Nil when the input has nothing readable.
    func detail(limit: Int = 400) -> String? {
        let text: String?
        switch tool {
        case "Bash", "Monitor", "PowerShell": text = input["command"]
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
            text = (input["file_path"] ?? input["notebook_path"]).map(Fmt.tilde)
        case "WebFetch": text = input["url"]
        case "WebSearch": text = input["query"]
        case "Glob", "Grep": text = [input["pattern"], input["path"].map(Fmt.tilde)].compactMap { $0 }.joined(separator: " in ")
        case "Agent", "Task": text = input["description"] ?? input["prompt"]
        default:
            let pairs = input.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
            text = pairs.isEmpty ? nil : pairs.joined(separator: "\n")
        }
        guard var t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        let lines = t.components(separatedBy: "\n")
        if lines.count > 6 { t = lines.prefix(6).joined(separator: "\n") + "\n…" }
        if t.count > limit { t = String(t.prefix(limit - 1)) + "…" }
        return t
    }

    /// For one line (a notification): newlines folded into spaces.
    var oneLine: String {
        let d = detail(limit: 160)?.replacingOccurrences(of: "\n", with: " ")
        return d.map { "\(action): \($0)" } ?? action
    }

    /// The Bash `description` Claude gave, when there is one: a plain-words gloss on the command.
    var why: String? {
        guard ["Bash", "PowerShell", "Monitor"].contains(tool), let d = input["description"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !d.isEmpty else { return nil }
        return d.count > 120 ? String(d.prefix(119)) + "…" : d
    }
}

/// The folder the bridge and Dashbar share: reads pending requests, writes answers and the "Dashbar is here" heartbeat.
struct PermissionQueue {
    let root: URL
    var requests: URL { root.appendingPathComponent("requests") }
    var decisions: URL { root.appendingPathComponent("decisions") }
    /// This copy's heartbeat: the release and a local build each keep their own, so one quitting never stops the other.
    var alive: URL { root.appendingPathComponent("alive." + (Bundle.main.bundleIdentifier ?? "dashbar")) }

    static let `default` = PermissionQueue(root: PermissionBridge.Paths.default().queue)

    /// Tells the bridge Dashbar is running and how long to wait for an answer. Rewritten every few seconds.
    func heartbeat(wait: Int) {
        guard FileManager.default.fileExists(atPath: requests.path) else { return }
        let clamped = min(PermissionBridge.maxWait, max(5, wait))
        writeAtomically(Data("wait=\(clamped)\n".utf8), to: alive)
    }

    /// Says Dashbar is going away, so waiting scripts stop at once and the terminal prompt appears.
    func goodbye() { try? FileManager.default.removeItem(at: alive) }

    /// Requests still waiting, oldest first. Files left by a script that is gone, or long past their time, are deleted.
    func read(now: Date = Date(), alive isAlive: (Int32) -> Bool = ClaudeSessions.isAlive) -> [PermissionRequest] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: requests, includingPropertiesForKeys: nil) else { return [] }
        var live: [PermissionRequest] = []
        for url in files where url.pathExtension == "json" && !url.lastPathComponent.hasPrefix(".") {
            guard let data = try? Data(contentsOf: url), let request = PermissionRequest.parse(data) else {
                // Unreadable: a file being written right now, or junk. Tidy only once it is old.
                if let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                   now.timeIntervalSince(modified) > Double(PermissionBridge.hookTimeout) { try? fm.removeItem(at: url) }
                continue
            }
            if request.isLive(now: now, alive: isAlive) {
                live.append(request)
            } else if !isAlive(request.pid) || now.timeIntervalSince(request.expires) > 60 {
                try? fm.removeItem(at: url)
                try? fm.removeItem(at: decisions.appendingPathComponent(request.id))
            }
        }
        return live.sorted { ($0.created, $0.id) < ($1.created, $1.id) }
    }

    enum Failure: LocalizedError {
        case gone
        case writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .gone: return "That request was already answered or timed out. Check the session's terminal."
            case .writeFailed(let why): return "Couldn't send the answer (\(why)). Answer in the session's terminal instead."
            }
        }
    }

    /// Writes the answer file the waiting script looks for. Only for a request that is still there.
    func answer(_ id: String, _ answer: PermissionRequest.Answer) throws {
        guard PermissionRequest.isValidID(id),
              FileManager.default.fileExists(atPath: requests.appendingPathComponent(id + ".json").path) else { throw Failure.gone }
        guard writeAtomically(Data((answer.rawValue + "\n").utf8), to: decisions.appendingPathComponent(id)) else {
            throw Failure.writeFailed("the answer folder isn't writable")
        }
    }

    /// Written to a hidden file then renamed, so the script never reads half a file. User-only.
    @discardableResult
    private func writeAtomically(_ data: Data, to url: URL) -> Bool {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        guard rename(tmp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        return true
    }
}

extension PermissionRequest {
    /// Requests answered in the terminal. Claude Code shows its own prompt at once, beside the waiting hook, and doesn't
    /// stop the hook when the prompt is answered there, so Dashbar watches the session file instead: once it has said
    /// "permission prompt" for a request (`seen`) and then says anything else, the prompt was answered. `seen` keeps
    /// only the ids of requests still pending.
    static func answeredInTerminal(_ requests: [PermissionRequest], sessions raw: [LiveSession], seen: inout Set<String>) -> [String] {
        var answered: [String] = []
        for r in requests {
            guard let s = raw.first(where: { $0.id == r.sessionId }) else { continue }
            if s.isWaiting && s.waitingFor == "permission prompt" {
                seen.insert(r.id)
            } else if seen.contains(r.id) {
                answered.append(r.id)
            }
        }
        seen.formIntersection(requests.map(\.id).filter { !answered.contains($0) })
        return answered
    }

    /// Sessions with a pending request read as "Needs permission" from the moment the request arrives (Claude Code's
    /// own session file may say so a little later), waiting since the request. Sorted as `ClaudeSessions` sorts them.
    static func marking(_ sessions: [LiveSession], with requests: [PermissionRequest], now: Date = Date()) -> [LiveSession] {
        guard !requests.isEmpty else { return sessions }
        let first = Dictionary(requests.map { ($0.sessionId, $0) }, uniquingKeysWith: { $0.created <= $1.created ? $0 : $1 })
        return sessions.map { s in
            guard let r = first[s.id], !(s.isWaiting && s.waitingFor == "permission prompt") else { return s }
            return LiveSession(id: s.id, pid: s.pid, name: s.name, cwd: s.cwd, status: "waiting", since: r.created,
                               entrypoint: s.entrypoint, root: s.root, waitingFor: "permission prompt",
                               account: s.account, configDir: s.configDir)
        }
        .sorted { ($0.urgency, $1.since) < ($1.urgency, $0.since) }
    }
}
