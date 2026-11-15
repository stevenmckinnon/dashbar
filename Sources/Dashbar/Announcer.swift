import SwiftUI
import AppKit

// MARK: - VoiceOver announcements

/// What VoiceOver says when the island would open: an agent finishing, stopping for you, or a permission prompt.
/// The island is a window VoiceOver never moves to, and notifications can be off or held back, so without this a
/// VoiceOver user would not hear the app's main moment. It names the agent and the workspace, and for a prompt what
/// kind of thing Claude wants to do ("Run a command"), never the command, a path or a file's contents.
enum Announcement {
    /// The sentence for a moment, or nil when there is nothing worth saying (a session that has already gone).
    static func text(for kind: IslandBanner.Kind, session: LiveSession?, request: PermissionRequest?) -> String? {
        let project = session?.project ?? request?.project ?? ""
        let place = project.isEmpty ? "" : " in \(project)"
        let account = session?.account.map { " (\($0))" } ?? ""
        switch kind {
        case .permission:
            let agent = session?.agent.name ?? "Claude"
            return "\(agent) needs permission\(place)\(account)" + (request.map { ": \($0.action)." } ?? ".")
        case .waiting:
            guard let session else { return nil }
            return "\(session.waitingSentence)\(place)\(account)."
        case .finished:
            guard let session else { return nil }
            return "\(session.agent.name) finished\(place)\(account)."
        }
    }

    /// The same moment seen by every running copy of Dashbar (the release and a local build both watch the same
    /// sessions): the first copy to claim this key speaks, the other stays quiet.
    static func key(for event: IslandEvent) -> String {
        switch event.kind {
        case .permission(let id): return "permission-" + id
        case .waiting: return "waiting-" + event.sessionID
        case .finished: return "finished-" + event.sessionID
        }
    }

    /// How long a claim holds. A prompt lives at most as long as the hook waits; the other moments only need to cover
    /// the gap between two copies reading the same change.
    static func claimWindow(for kind: IslandBanner.Kind) -> TimeInterval {
        if case .permission = kind { return TimeInterval(PermissionBridge.hookTimeout) }
        return 20
    }

    /// A prompt or a waiting agent interrupts what VoiceOver is reading; a finished agent waits its turn.
    static func isHighPriority(_ kind: IslandBanner.Kind) -> Bool {
        if case .finished = kind { return false }
        return true
    }

    /// Asks VoiceOver to speak.
    @MainActor static func post(_ text: String, high: Bool) {
        var s = AttributedString(text)
        s.accessibilitySpeechAnnouncementPriority = high ? .high : .default
        AccessibilityNotification.Announcement(s).post()
    }
}

/// One small empty file per announced moment, in the cache folder every copy of Dashbar shares, created exclusively
/// so only one copy wins. Holds no names, paths or text: the file name is the moment's key (an id) and nothing else.
struct AnnouncementClaims {
    let folder: URL

    static let `default` = AnnouncementClaims(folder: homeDir.appendingPathComponent("Library/Caches/Dashbar/announced"))

    /// True for the first copy to claim `key` within `window` seconds.
    func claim(_ key: String, window: TimeInterval, now: Date = Date()) -> Bool {
        let name = String(key.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }.map(Character.init))
        guard !name.isEmpty else { return true }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        prune(now: now)
        let path = folder.appendingPathComponent(name).path
        if create(path) { return true }
        // Taken: by the other copy just now, or long ago by a moment that has passed.
        guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
              now.timeIntervalSince(modified) >= window else { return false }
        try? fm.removeItem(atPath: path)
        return create(path)
    }

    private func create(_ path: String) -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// Claims older than any window (the longest, a plan limit's, is 6 hours) are only clutter.
    private func prune(now: Date) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for url in files {
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               now.timeIntervalSince(modified) > 86400 { try? fm.removeItem(at: url) }
        }
    }
}

extension Store {
    /// Speaks an island moment, once per moment across every running copy. Only while VoiceOver is on, and only for
    /// the moments whose notification toggle is on ("Notify when an agent finishes", "… needs you").
    func announce(_ event: IslandEvent, claims: AnnouncementClaims = .default) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        let defaults = UserDefaults.standard
        switch event.kind {
        case .finished(let after):
            // As for notifications: a quick answer isn't worth interrupting for.
            guard after >= SessionTransitions.notifyAfter, defaults.bool(forKey: Notifier.defaultsKey) else { return }
        case .waiting, .permission:
            guard defaults.bool(forKey: Notifier.waitingKey) else { return }
        }
        let session = sessions.first { $0.id == event.sessionID }
        if case .waiting = event.kind, session?.waitingFor == "permission prompt" {
            // The hook's request may be a moment behind Claude Code's session file; when it arrives it is announced
            // with what Claude wants to do, so this one would only repeat it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !self.permissionRequests.contains(where: { $0.sessionId == event.sessionID }),
                      let still = self.sessions.first(where: { $0.id == event.sessionID }), still.isWaiting else { return }
                self.speak(event, session: still, claims: claims)
            }
            return
        }
        speak(event, session: session, claims: claims)
    }

    private func speak(_ event: IslandEvent, session: LiveSession?, claims: AnnouncementClaims) {
        let request: PermissionRequest? = {
            if case .permission(let id) = event.kind { return permissionRequests.first { $0.id == id } }
            return nil
        }()
        guard let text = Announcement.text(for: event.kind, session: session, request: request),
              claims.claim(Announcement.key(for: event), window: Announcement.claimWindow(for: event.kind)) else { return }
        Announcement.post(text, high: Announcement.isHighPriority(event.kind))
    }
}
