import Foundation
import WidgetKit
import os
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
    /// Says only that it wrote and reloaded, never what: the unified log stays on this Mac, but it needn't hold figures.
    private static let log = Logger(subsystem: "fun.dashbar.app", category: "widgets")

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
        guard let group = Bundle.main.object(forInfoDictionaryKey: WidgetStatus.groupInfoKey) as? String, !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return WidgetBridge(url: WidgetStatus.fileURL(container: container))
    }

    var url: URL { writer.url }

    /// Saves `snapshot`'s widget copy if it changed, then reloads the widgets (now, or once the minute is up).
    @discardableResult
    func update(_ snapshot: StatusSnapshot, now: Date = Date()) -> Bool {
        guard writer.write(snapshot.forWidget(), now: now) else { return false }
        Self.log.info("saved the widgets' status (\(self.writer.writeCount, privacy: .public) so far)")
        requestReload(now: now)
        return true
    }

    private func requestReload(now: Date) {
        let wait = lastReload.addingTimeInterval(Self.reloadInterval).timeIntervalSince(now)
        if wait <= 0 {
            lastReload = now
            Self.log.info("asked WidgetKit to reload")
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
