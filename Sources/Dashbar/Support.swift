import Foundation

enum Shell {
    /// Runs a binary and returns stdout. Never throws; returns "" on failure.
    static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

enum Fmt {
    /// "999", "1.2K", "25M", "2.34B", "12.4B", "1.20T": at most five characters before the unit, so a figure never
    /// outgrows the narrow columns it sits in.
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        switch n {
        case 100_000_000_000_000...: return String(format: "%.0fT", d / 1e12)
        case 10_000_000_000_000...: return String(format: "%.1fT", d / 1e12)
        case 1_000_000_000_000...: return String(format: "%.2fT", d / 1e12)
        case 100_000_000_000...: return String(format: "%.0fB", d / 1e9)
        case 10_000_000_000...: return String(format: "%.1fB", d / 1e9)
        case 1_000_000_000...: return String(format: "%.2fB", d / 1e9)
        case 10_000_000...: return String(format: "%.0fM", d / 1e6)
        case 1_000_000...: return String(format: "%.1fM", d / 1e6)
        case 10_000...: return String(format: "%.0fK", d / 1e3)
        case 1_000...: return String(format: "%.1fK", d / 1e3)
        default: return "\(n)"
        }
    }

    /// Memory (RAM, a process's resident size): binary units, as Activity Monitor counts them.
    static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .memory)
    }

    /// Space on disk (clean-up folders, free space): decimal units, as Finder counts them. Every clean-up figure uses
    /// this, so the tile, the list and the sidebar agree.
    static func diskBytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    /// A whole drive's space, as Finder counts it but without the hundredths: "421 GB", "995 GB", "1.2 TB".
    static func driveBytes(_ n: UInt64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.isAdaptive = false
        return f.string(fromByteCount: Int64(n))
    }

    /// "15% used". The real figure, above 100 too: a limit some way over is shown as it is, never as a flat 100%.
    static func usedPercent(_ p: Double) -> String {
        "\(Int(max(0, p).rounded()))% used"
    }

    /// When a limit resets: "resets in 2h 10m" within a day, "resets Thu 09:00" within six days, "resets 21 Nov" after
    /// that. Day and time follow the locale and its 12- or 24-hour clock.
    static func resets(_ date: Date, now: Date = Date(), locale: Locale = .autoupdatingCurrent,
                       timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let left = date.timeIntervalSince(now)
        if left < 86400 { return "resets in " + duration(left) }
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone)
        // Within six days the weekday can't be today's, so it never reads as a time that has already passed.
        if left < 6 * 86400 { return "resets " + date.formatted(style.weekday(.abbreviated).hour().minute()) }
        return "resets " + date.formatted(style.day().month(.abbreviated))
    }

    /// How long since `date`: "45s", "4m", "20h", "2h 5m", "1d 4h". The same shape as `duration`.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        span(Int(now.timeIntervalSince(date)))
    }

    /// A span of time ahead, for sentences: "less than a minute", "45m", "2h 5m", "3d 4h".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s < 60 ? "less than a minute" : span(s)
    }

    /// Every duration the app shows: the two largest parts, leaving out a part that is zero ("20h", not "20h 0m").
    static func span(_ seconds: Int) -> String {
        let s = max(0, seconds)
        switch s {
        case ..<60: return "\(s)s"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return s % 3600 / 60 == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(s % 3600 / 60)m"
        default: return s % 86400 / 3600 == 0 ? "\(s / 86400)d" : "\(s / 86400)d \(s % 86400 / 3600)h"
        }
    }

    /// "claude-opus-5-5" -> "Opus 5.5", "claude-sonnet-4-5-20250929" -> "Sonnet 4.5", "gpt-5-codex" stays.
    /// A model's name short enough for a list row: drops a parenthetical ("Gemini 4 Argon (Medium)" → "Gemini 4 Argon")
    /// and a trailing date ("gpt-5-2025-08-07" → "gpt-5", "gemini-3.8-flash-20260101" → "gemini-3.8-flash").
    static func shortModel(_ name: String) -> String {
        var s = name
        if let paren = s.firstIndex(of: "("), paren > s.startIndex { s = String(s[..<paren]) }
        s = s.trimmingCharacters(in: .whitespaces)
        let dated = [#"[-@_ ]\d{4}-\d{2}-\d{2}$"#, #"[-@_ ]\d{8}$"#]
        for pattern in dated {
            if let r = s.range(of: pattern, options: .regularExpression), r.lowerBound > s.startIndex {
                s = String(s[..<r.lowerBound])
            }
        }
        return s.isEmpty ? name : s
    }

    static func model(_ raw: String) -> String {
        guard raw.hasPrefix("claude-") else { return raw }
        var parts = raw.dropFirst("claude-".count).split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first else { return raw }
        let version = parts.dropFirst().joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " " + version)
    }

    /// Repo root for a cwd: collapses Claude worktrees, then walks up to the nearest `.git`.
    static func root(fromCwd cwd: String) -> String {
        if let r = cwd.range(of: "/.claude/worktrees/") { return String(cwd[..<r.lowerBound]) }
        let fm = FileManager.default
        let home = homeDir.path
        var url = URL(fileURLWithPath: cwd)
        while url.path != "/" && url.path != home && url.path.count > 1 {
            if fm.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            url.deleteLastPathComponent()
        }
        return cwd
    }

    static func tilde(_ path: String) -> String {
        path.hasPrefix(homeDir.path) ? "~" + path.dropFirst(homeDir.path.count) : path
    }

    /// "16.6 GB" -> ("16.6", "GB"). Disk space by default (`diskBytes`); pass `.memory` for memory, to match `bytes`.
    static func bytesSplit(_ n: UInt64, style: ByteCountFormatter.CountStyle = .file) -> (String, String) {
        let parts = ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: style).split(separator: " ")
        return (String(parts.first ?? "0"), parts.count > 1 ? String(parts[1]) : "")
    }

    /// Project name from a cwd, collapsing Claude worktrees back to their repo.
    static func project(fromCwd cwd: String) -> String {
        if let r = cwd.range(of: "/.claude/worktrees/") {
            return URL(fileURLWithPath: String(cwd[..<r.lowerBound])).lastPathComponent
        }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}

extension Date {
    static func fromISO(_ s: String) -> Date? {
        ISOParsers.frac.date(from: s) ?? ISOParsers.plain.date(from: s)
    }
}

private enum ISOParsers {
    static let frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain = ISO8601DateFormatter()
}

let homeDir = FileManager.default.homeDirectoryForCurrentUser
