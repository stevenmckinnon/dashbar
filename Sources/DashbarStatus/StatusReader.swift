import Foundation
import Darwin

/// Finds the snapshot of a running copy of Dashbar. A snapshot is current while the process that wrote it is still
/// running: the app rewrites it whenever anything in it changes, and writes nothing while nothing does.
public struct StatusReader {
    public enum Failure: Error, Equatable {
        /// No copy has written a snapshot: Dashbar has never run, or it is older than 0.7.1. `appName` is the copy asked
        /// for, or "Dashbar" when either would do.
        case missing(appName: String)
        /// A snapshot exists but the copy that wrote it has quit. `lastWritten` is when it last wrote.
        case notRunning(appName: String, lastWritten: Date)
        /// The file can't be read, or a newer Dashbar wrote it in a shape this tool doesn't know.
        case unreadable(path: String, reason: String)
    }

    public var home: URL
    /// Whether `pid` is a running process named `name`.
    public var isRunning: (_ pid: Int32, _ name: String) -> Bool
    /// A file to read in place of the copies' own, as is, without checking that its app is running (for tests).
    public var overrideFile: String?

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                isRunning: @escaping (_ pid: Int32, _ name: String) -> Bool = StatusReader.processIsRunning,
                overrideFile: String? = nil) {
        self.home = home
        self.isRunning = isRunning
        self.overrideFile = overrideFile
    }

    /// The snapshot of the first running copy in `order`.
    public func read(order: [StatusSnapshot.Copy]) -> Result<StatusSnapshot, Failure> {
        let wanted = order.count == 1 ? order[0].appName : StatusSnapshot.Copy.release.appName
        if let overrideFile { return load(URL(fileURLWithPath: overrideFile)) ?? .failure(.missing(appName: wanted)) }
        var latestStopped: (name: String, at: Date)?
        for copy in order {
            let url = StatusSnapshot.fileURL(appName: copy.appName, home: home)
            guard let result = load(url) else { continue }
            guard case .success(let snapshot) = result else { return result }
            if isRunning(snapshot.app.pid, copy.appName) { return .success(snapshot) }
            if latestStopped.map({ snapshot.generatedAt > $0.at }) ?? true {
                latestStopped = (copy.appName, snapshot.generatedAt)
            }
        }
        if let latestStopped { return .failure(.notRunning(appName: latestStopped.name, lastWritten: latestStopped.at)) }
        return .failure(.missing(appName: wanted))
    }

    /// Nil when there is no file.
    private func load(_ url: URL) -> Result<StatusSnapshot, Failure>? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        struct Header: Decodable { let schema: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
            return .failure(.unreadable(path: url.path, reason: "it isn't a Dashbar status file"))
        }
        guard header.schema <= StatusSnapshot.currentSchema else {
            return .failure(.unreadable(path: url.path, reason: "a newer Dashbar wrote it; use the dashbar command inside that app"))
        }
        do {
            return .success(try StatusSnapshot.decoder().decode(StatusSnapshot.self, from: data))
        } catch {
            return .failure(.unreadable(path: url.path, reason: "it isn't a Dashbar status file"))
        }
    }

    /// Whether `pid` is alive and named `name`, so a pid reused by another program since doesn't count.
    public static func processIsRunning(_ pid: Int32, _ name: String) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let actual = String(cString: buffer)
        // The kernel keeps at most 16 bytes of a process name.
        return actual == name || (actual.utf8.count >= 15 && name.hasPrefix(actual))
    }
}
