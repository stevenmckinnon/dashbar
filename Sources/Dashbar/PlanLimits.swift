import Foundation
import Security

/// Experimental, off by default: Claude plan usage (5-hour and weekly windows).
///
/// Claude doesn't store these limits on disk. Claude Code's own `/usage` screen fetches them from an
/// undocumented Anthropic endpoint using its sign-in, which it keeps in the macOS Keychain. With the
/// user's opt-in, Dashbar reads that sign-in (macOS asks the user first) and makes the same read-only
/// request. It never refreshes or stores the token: when the sign-in has expired it asks the user to
/// open Claude Code, which refreshes it, so Claude Code's session is never disturbed.
enum ClaudePlanLimits {
    static let keychainService = "Claude Code-credentials"
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    struct Result {
        var limits: [RateLimit] = []
        var plan: String?
        /// What went wrong, phrased with what to do next. Nil on success.
        var problem: String?
        /// The sign-in is expired or rejected, which Claude Code itself can fix by making any request.
        var needsSignIn = false
        var fetchedAt = Date()
        /// A failure that clears up by itself (rate limited, a server error, no connection): worth waiting out,
        /// and not a reason to throw away the last good reading.
        var transient = false
        /// How long Anthropic asked us to wait (`Retry-After`), when it said.
        var retryAfter: TimeInterval?
        /// Set on limits kept from an earlier reading: why the latest fetch didn't replace them.
        var stale: Stale?
    }

    enum Stale: Equatable {
        case rateLimited, failed
        /// The longer explanation, for the tooltip.
        var explanation: String {
            switch self {
            case .rateLimited: return ClaudePlanLimits.rateLimitedMessage
            case .failed: return "The last refresh didn't work (a server problem or no connection)."
            }
        }
    }

    struct Credentials {
        let token: String
        let expiresAt: Date?
        let plan: String?
        /// Which Keychain entry it came from (a name, not a secret).
        var service: String? = nil
    }

    // The sign-in is kept in memory while it's valid, so the Keychain (and its permission prompt) is only
    // touched at launch, when the sign-in expires, or when Claude rejects it.
    private static let lock = NSLock()
    private static var cached: Credentials?
    private static let rememberedServiceKey = "claudeCredentialService"

    static func fetch() async -> Result {
        let first = await request(with: currentCredentials(forceReread: false))
        // Claude Code may have refreshed its sign-in since we read it: re-read once and retry.
        if first.rejected { return await request(with: currentCredentials(forceReread: true)).result }
        return first.result
    }

    /// Asks Claude Code to refresh its own sign-in by making one tiny request (`claude -p`, on the cheapest
    /// model, without saving a session), the same thing running `claude` in a terminal does. Dashbar never
    /// touches the token itself. Returns an error message, or nil when Claude Code ran and exited cleanly.
    static func refreshSignIn() async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                // A login shell, so `claude` is found wherever the user installed it.
                p.arguments = ["-lc", "claude -p ok --model haiku --no-session-persistence"]
                p.currentDirectoryURL = FileManager.default.temporaryDirectory
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: "Couldn't start Claude Code. Run `claude` in a terminal once, then retry."); return }
                let deadline = Date().addingTimeInterval(60)
                while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
                if p.isRunning { p.terminate(); cont.resume(returning: "Claude Code took too long to answer. Run `claude` in a terminal once, then retry."); return }
                cont.resume(returning: p.terminationStatus == 0 ? nil
                    : "Claude Code couldn't refresh the sign-in (it may need you to sign in again). Run `claude` in a terminal, then retry.")
            }
        }
    }

    private static func currentCredentials(forceReread: Bool) -> Read {
        lock.lock(); defer { lock.unlock() }
        if !forceReread, let c = cached, (c.expiresAt ?? .distantFuture) > Date() { return .success(c) }
        let read = readCredentials()
        if case .success(let c) = read { cached = c } else { cached = nil }
        return read
    }

    private static func request(with read: Read) async -> (result: Result, rejected: Bool) {
        let creds: Credentials
        switch read {
        case .failure(let message): return (Result(problem: message), false)
        case .success(let c): creds = c
        }
        if let expiry = creds.expiresAt, expiry < Date() {
            return (Result(plan: creds.plan, problem: expiredMessage(expiry), needsSignIn: true), false)
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Dashbar", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                let limits = parse(data)
                return (limits.isEmpty
                    ? Result(plan: creds.plan, problem: "Claude's usage response had no limits Dashbar recognises. The format may have changed.")
                    : Result(limits: limits, plan: creds.plan), false)
            case 429:
                let wait = retryAfter((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"))
                return (Result(plan: creds.plan, problem: rateLimitedMessage, transient: true, retryAfter: wait), false)
            case 500...599:
                return (Result(plan: creds.plan, problem: "Anthropic's usage service had a problem (HTTP \(status)).", transient: true), false)
            case 401, 403:
                return (Result(plan: creds.plan, problem: "Claude didn't accept the sign-in. Run `claude` in a terminal once to refresh it, then retry.", needsSignIn: true), true)
            default:
                return (Result(plan: creds.plan, problem: "Couldn't load Claude plan limits (HTTP \(status)). The endpoint may have changed."), false)
            }
        } catch {
            return (Result(plan: creds.plan, problem: "Couldn't reach Anthropic to load plan limits. Check your connection.", transient: true), false)
        }
    }

    // MARK: Waiting out failures

    static let rateLimitedMessage = "Claude is limiting how often plan usage can be read. This often happens when another app, or another copy of Dashbar, is asking too."

    /// `Retry-After` as seconds, from either form the header allows: a number of seconds or an HTTP date.
    static func retryAfter(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = Double(header) { return max(0, seconds) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: header).map { max(0, $0.timeIntervalSince(now)) }
    }

    /// How long to wait after the `failures`-th failure in a row: what Anthropic asked for if it said
    /// (but at least a minute), else 2, 4, 8… minutes, up to half an hour.
    static func backoff(failures: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter { return min(max(retryAfter, 60), 3600) }
        return min(120 * pow(2, Double(max(failures, 1) - 1)), 1800)
    }

    /// What to show after a fetch: a transient failure keeps the last good limits, with a note, instead of
    /// replacing them with an error. Anything else (success, or a problem the user has to fix) is shown as is.
    static func keepingLastGood(_ previous: Result?, _ new: Result, now: Date = Date()) -> Result {
        guard new.transient, let previous, previous.problem == nil, !previous.limits.isEmpty else { return new }
        var kept = previous
        kept.stale = new.problem == rateLimitedMessage ? .rateLimited : .failed
        return kept
    }

    // MARK: Keychain (read-only)

    enum Read { case success(Credentials), failure(String) }

    /// Claude Code saves its sign-in as "Claude Code-credentials", or with a suffix when it runs with a
    /// custom config folder. There can be several, some stale, so read each and use the best one.
    static func readCredentials() -> Read {
        let services = credentialServices()
        guard !services.isEmpty else {
            return .failure("No Claude Code sign-in found in your Keychain. Run `claude` in a terminal and sign in, then retry.")
        }
        // Try the entry that worked last time first; only fall back to reading the others if it's missing or stale.
        let remembered = UserDefaults.standard.string(forKey: rememberedServiceKey)
        let ordered = services.sorted { a, _ in a == remembered }
        var found: [Credentials] = []
        var denied = false
        for service in ordered {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data, var creds = parseCredentials(data) {
                creds.service = service
                found.append(creds)
                if service == remembered, (creds.expiresAt ?? .distantFuture) > Date() { break }   // good enough
            } else if [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed].contains(status) {
                denied = true
            }
        }
        if let best = best(of: found) {
            if let service = best.service { UserDefaults.standard.set(service, forKey: rememberedServiceKey) }
            return .success(best)
        }
        return .failure(denied
            ? "Keychain access wasn't allowed. Turn the setting off and on to be asked again."
            : "Found Claude Code's sign-in but couldn't read it. Its format may have changed.")
    }

    /// Names of every Claude Code sign-in entry. Listing names reads no secrets and needs no permission.
    static func credentialServices() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let list = items as? [[String: Any]] else { return [] }
        let names = list.compactMap { $0[kSecAttrService as String] as? String }
            .filter { $0 == keychainService || $0.hasPrefix(keychainService + "-") }
        return Array(Set(names)).sorted { $0 == keychainService ? true : ($1 == keychainService ? false : $0 < $1) }
    }

    /// The sign-in to use: an unexpired one if any, latest expiry first; otherwise the most recent expired one,
    /// so the message can say how stale it is.
    static func best(of candidates: [Credentials], now: Date = Date()) -> Credentials? {
        let valid = candidates.filter { ($0.expiresAt ?? .distantFuture) > now }
        let pool = valid.isEmpty ? candidates : valid
        return pool.max { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    static func expiredMessage(_ expiry: Date, now: Date = Date()) -> String {
        let ago = RelativeDateTimeFormatter().localizedString(for: expiry, relativeTo: now)
        return "The Claude Code sign-in in your Keychain expired \(ago). Run `claude` in a terminal once to refresh it, then retry. (The Desktop app doesn't update this sign-in.)"
    }

    static func parseCredentials(_ data: Data) -> Credentials? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return Credentials(token: token, expiresAt: expires, plan: planName(oauth))
    }

    /// "Max 20x", "Max 5x", "Pro"
    static func planName(_ oauth: [String: Any]) -> String? {
        guard let type = (oauth["subscriptionType"] as? String)?.lowercased(), !type.isEmpty else { return nil }
        var name = type.prefix(1).uppercased() + type.dropFirst()
        if let tier = (oauth["rateLimitTier"] as? String)?.lowercased(),
           let multiplier = tier.split(separator: "_").last(where: { $0.hasSuffix("x") && Int($0.dropLast()) != nil }) {
            name += " " + multiplier
        }
        return name
    }

    // MARK: Response

    /// Reads every window in the response that has a utilization, e.g. `five_hour`, `seven_day`,
    /// `seven_day_opus`. Utilization is a percentage; reset times are ISO 8601.
    static func parse(_ data: Data) -> [RateLimit] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let order = ["five_hour": 0, "seven_day": 1, "seven_day_sonnet": 2, "seven_day_opus": 3]
        return obj.compactMap { key, value -> (Int, RateLimit)? in
            guard let window = value as? [String: Any],
                  let used = (window["utilization"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (window["resets_at"] as? String).flatMap(Date.fromISO)
            return (order[key] ?? 9, RateLimit(label: label(for: key), usedPercent: used, resetsAt: reset, window: Self.window(for: key)))
        }
        .sorted { ($0.0, $0.1.label) < ($1.0, $1.1.label) }
        .map(\.1)
    }

    /// Window length by key: "five_hour" and "seven_day…". Unknown windows get no pace.
    static func window(for key: String) -> TimeInterval? {
        if key == "five_hour" { return 5 * 3600 }
        if key.hasPrefix("seven_day") { return 7 * 86400 }
        return nil
    }

    /// What the menu bar shows: the most-used 5-hour or weekly window, as what is left of it.
    struct MenuBarReading: Equatable {
        let name: String        // "5h" or "week"
        let leftPercent: Int
        /// Nearly used up, or on course to run out before it resets.
        let atRisk: Bool
    }

    static func menuBarReading(_ limits: [RateLimit], now: Date = Date()) -> MenuBarReading? {
        let candidates = limits.filter { $0.label == "5-hour" || $0.label == "Weekly" }
        guard let top = candidates.max(by: { $0.usedPercent < $1.usedPercent }) else { return nil }
        let used = min(max(top.usedPercent, 0), 100)
        let risky: Bool
        switch top.pace(now: now) {
        case .runsOut?, .usedUp?: risky = true
        default: risky = used >= 90
        }
        return MenuBarReading(name: top.label == "5-hour" ? "5h" : "week",
                              leftPercent: Int((100 - used).rounded()), atRisk: risky)
    }

    static func label(for key: String) -> String {
        switch key {
        case "five_hour": return "5-hour"
        case "seven_day": return "Weekly"
        case "seven_day_opus": return "Weekly · Opus"
        case "seven_day_sonnet": return "Weekly · Sonnet"
        default:
            let words = key.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()   // "extra_usage" -> "Extra usage"
        }
    }
}
