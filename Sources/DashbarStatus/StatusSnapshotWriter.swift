import Foundation
import Darwin

/// Saves snapshots for the command-line tool, only when what they say has changed: a reading that differs only in its
/// `generatedAt` writes nothing. Each write is atomic (a temporary file renamed into place), the file is readable only
/// by the user (0600) and its folder only openable by the user (0700).
///
/// Not thread-safe: the app calls it from the main actor.
public final class StatusSnapshotWriter {
    public let url: URL
    /// What the last write said, with `generatedAt` left out.
    private var lastContent: Data?
    /// Writes made so far, for measuring.
    public private(set) var writeCount = 0

    public init(url: URL) {
        self.url = url
    }

    /// Writes `snapshot` stamped with `now` if its content differs from the last write, or the file has gone (a cache
    /// clean-up). Returns whether it wrote.
    @discardableResult
    public func write(_ snapshot: StatusSnapshot, now: Date = Date()) -> Bool {
        var unstamped = snapshot
        unstamped.generatedAt = Date(timeIntervalSince1970: 0)
        let encoder = StatusSnapshot.encoder()
        guard let content = try? encoder.encode(unstamped) else { return false }
        if content == lastContent, FileManager.default.fileExists(atPath: url.path) { return false }
        var stamped = snapshot
        stamped.generatedAt = now
        guard let data = try? encoder.encode(stamped), (try? Self.writePrivately(data, to: url)) != nil else { return false }
        lastContent = content
        writeCount += 1
        return true
    }

    /// Writes `data` to a temporary file created 0600 beside `url`, then renames it over `url`, so a reader never sees
    /// half a file and the content is never readable by anyone else, even for a moment.
    static func writePrivately(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        unlink(temp.path)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == data.count, rename(temp.path, url.path) == 0 else {
            let code = errno
            unlink(temp.path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
