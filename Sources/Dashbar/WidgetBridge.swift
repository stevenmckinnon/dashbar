import Foundation
import WidgetKit
import DashbarStatus

/// Saves the desktop widgets' copy of the status (`StatusSnapshot.forWidget()`: plan limits and agent counts, nothing
/// that names a project) in the App Group container the sandboxed widget can read, and asks WidgetKit to redraw the
/// widgets when it changes.
///
/// It piggybacks on `CLIStatus`: called with each snapshot that rebuilds (at most every 3 s), it writes only when the
/// widget's copy differs, and asks for a reload at most once a minute (WidgetKit budgets reloads anyway). A build without
/// an App Group (ad-hoc signed, so no team to prefix one with) writes nothing, and never touches a group container: on
/// macOS 15 and later an app that reaches into one it isn't entitled to makes macOS ask the user.
@MainActor
final class WidgetBridge {
    static let reloadInterval: TimeInterval = 60

    private let writer: StatusSnapshotWriter
    private let reload: () -> Void
    private var lastReload: Date = .distantPast
    private var pendingReload = false

    init(url: URL, reload: @escaping () -> Void = { WidgetStatus.Kind.all.forEach { WidgetCenter.shared.reloadTimelines(ofKind: $0) } }) {
        writer = StatusSnapshotWriter(url: url)
        self.reload = reload
    }

    /// The bridge for this build's App Group, or nil when it has none.
    static func forThisBuild() -> WidgetBridge? {
        retireStaleExtension()
        guard let group = Bundle.main.object(forInfoDictionaryKey: WidgetStatus.groupInfoKey) as? String, !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return WidgetBridge(url: WidgetStatus.fileURL(container: container))
    }

    var url: URL { writer.url }

    // MARK: After an update

    /// The widget extension's executable inside this app.
    static var extensionExecutable: URL? {
        Bundle.main.builtInPlugInsURL?.appendingPathComponent("DashbarWidgets.appex/Contents/MacOS/DashbarWidgets")
    }

    /// A widget process that started before its executable was last written is the previous version, left running
    /// across an update (Sparkle replaces the bundle in place). WidgetKit then refuses everything it draws ("Bundle
    /// version did not match") and the widgets stay blank until it exits.
    nonisolated static func isStale(started: Date, executableModified: Date) -> Bool {
        started < executableModified
    }

    /// Stops this build's own widget processes that predate the installed extension, then asks for fresh timelines,
    /// so an update never leaves the widgets blank. Only processes running this exact executable path are touched.
    static func retireStaleExtension() {
        guard let exe = extensionExecutable,
              let modified = (try? FileManager.default.attributesOfItem(atPath: exe.path))?[.modificationDate] as? Date
        else { return }
        var stopped = false
        for pid in Proc.allPIDs() where pid != getpid() && Proc.path(pid) == exe.path {
            guard let info = Proc.bsdInfo(pid), isStale(started: info.started, executableModified: modified) else { continue }
            if kill(pid, SIGTERM) == 0 { stopped = true }
        }
        if stopped { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// Saves `snapshot`'s widget copy if it changed, then reloads the widgets (now, or once the minute is up).
    @discardableResult
    func update(_ snapshot: StatusSnapshot, now: Date = Date()) -> Bool {
        guard writer.write(snapshot.forWidget(), now: now) else { return false }
        requestReload(now: now)
        return true
    }

    private func requestReload(now: Date) {
        let wait = lastReload.addingTimeInterval(Self.reloadInterval).timeIntervalSince(now)
        if wait <= 0 {
            lastReload = now
            reload()
        } else if !pendingReload {
            pendingReload = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                self.pendingReload = false
                self.lastReload = Date()
                self.reload()
            }
        }
    }
}
