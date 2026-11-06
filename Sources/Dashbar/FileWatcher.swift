import Foundation
import CoreServices

/// Calls `onChange` (on `queue`) when anything under the watched folders changes, with FSEvents
/// coalescing bursts into one callback per `latency` seconds. Missing folders are skipped,
/// and `restart()` picks them up once they exist (e.g. Codex installed later).
final class FileWatcher {
    private let paths: [String]
    private let latency: CFTimeInterval
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private(set) var watching: [String] = []

    init(paths: [String], latency: CFTimeInterval = 1.5, queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.paths = paths
        self.latency = latency
        self.queue = queue
        self.onChange = onChange
        start()
    }

    deinit { stop() }

    func restart() {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard existing != watching else { return }
        stop()
        start()
    }

    private func start() {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let s = FSEventStreamCreate(nil, callback, &context, existing as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
        watching = existing
    }

    private func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        watching = []
    }
}
