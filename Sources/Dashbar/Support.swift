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
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        switch n {
        case 1_000_000_000...: return String(format: "%.2fB", d / 1e9)
        case 10_000_000...: return String(format: "%.0fM", d / 1e6)
        case 1_000_000...: return String(format: "%.1fM", d / 1e6)
        case 10_000...: return String(format: "%.0fK", d / 1e3)
        case 1_000...: return String(format: "%.1fK", d / 1e3)
        default: return "\(n)"
        }
    }

    static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .memory)
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case ..<60: return "\(s)s"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h \(s % 3600 / 60)m"
        default: return "\(s / 86400)d"
        }
    }

    /// A span of time ahead, for sentences: "less than a minute", "45m", "2h 5m", "3d 4h".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        switch s {
        case ..<60: return "less than a minute"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return s % 3600 / 60 == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(s % 3600 / 60)m"
        default: return s % 86400 / 3600 == 0 ? "\(s / 86400)d" : "\(s / 86400)d \(s % 86400 / 3600)h"
        }
    }

    /// "claude-opus-5-5" -> "Opus 5.5", "claude-sonnet-4-5-20250929" -> "Sonnet 4.5", "gpt-5-codex" stays.
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

    /// "16.6 GB" -> ("16.6", "GB")
    static func bytesSplit(_ n: UInt64) -> (String, String) {
        let parts = ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file).split(separator: " ")
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
