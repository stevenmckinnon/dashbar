import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Jump to the agent that needs you

/// Which session the jump shortcut goes to. Pure, so the order is tested (`JumpTargetTests`).
///
/// 1. The session that has waited for you longest (a permission prompt, a question, any "needs you"), across every tool
///    with live sessions (Claude Code, Gemini CLI and Antigravity, OpenCode, GitHub Copilot).
/// 2. Otherwise the session that finished most recently (the same "finished" the island and the menu bar's "Done" use:
///    a stretch of work of at least `SessionTransitions.minimumWork`), as long as it is still there and hasn't started
///    working again.
/// 3. Otherwise nothing.
///
/// A tool switched off in Show in Dashbar never counts, whatever its sessions say.
enum JumpTarget {
    enum Reason: Equatable { case needsYou, finished }

    struct Choice: Equatable {
        let session: LiveSession
        let reason: Reason
    }

    /// `waitingSince` and `finishedAt` come from `SessionTransitions`; a waiting session it hasn't timed yet (just seen)
    /// falls back to the session's own `since`.
    static func choose(sessions: [LiveSession], waitingSince: [String: Date], finishedAt: [String: Date],
                       visibility: ToolVisibility) -> Choice? {
        let shown = visibility.filter(sessions)
        let waiting = shown.filter(\.isWaiting)
        if let longest = waiting.min(by: { a, b in
            let ta = waitingSince[a.id] ?? a.since, tb = waitingSince[b.id] ?? b.since
            return ta != tb ? ta < tb : a.id < b.id   // a stable answer for a tie
        }) {
            return Choice(session: longest, reason: .needsYou)
        }
        let finished = shown.filter { !$0.isBusy && finishedAt[$0.id] != nil }
        if let latest = finished.max(by: { a, b in
            let ta = finishedAt[a.id]!, tb = finishedAt[b.id]!
            return ta != tb ? ta < tb : a.id > b.id
        }) {
            return Choice(session: latest, reason: .finished)
        }
        return nil
    }
}

// MARK: - A key combination

/// A key and its modifiers, as Carbon's hot key API takes them. `key` is what the key printed when it was recorded
/// ("J"), kept only to show it; the key code is what's registered.
struct KeyCombo: Codable, Equatable, Sendable {
    var keyCode: UInt32
    /// Carbon modifier mask: `cmdKey`, `optionKey`, `controlKey`, `shiftKey`.
    var modifiers: UInt32
    var key: String

    /// "⌃⌥J", in the order macOS menus use.
    var display: String { Self.symbols(modifiers) + keyName(spoken: false) }

    /// "Control Option J", for VoiceOver.
    var spoken: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("Control") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("Command") }
        return (parts + [keyName(spoken: true)]).joined(separator: " ")
    }

    static func symbols(_ modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }

    private func keyName(spoken: Bool) -> String {
        if let f = Self.functionKeys[Int(keyCode)] { return "F\(f)" }
        if let named = Self.namedKeys[Int(keyCode)] { return spoken ? named.spoken : named.symbol }
        return key.uppercased()
    }

    private static let namedKeys: [Int: (symbol: String, spoken: String)] = [
        kVK_Return: ("↩", "Return"), kVK_Tab: ("⇥", "Tab"), kVK_Space: ("Space", "Space"), kVK_Delete: ("⌫", "Delete"),
        kVK_Escape: ("⎋", "Escape"), kVK_ForwardDelete: ("⌦", "Forward Delete"), kVK_LeftArrow: ("←", "Left Arrow"),
        kVK_RightArrow: ("→", "Right Arrow"), kVK_UpArrow: ("↑", "Up Arrow"), kVK_DownArrow: ("↓", "Down Arrow"),
        kVK_Home: ("↖", "Home"), kVK_End: ("↘", "End"), kVK_PageUp: ("⇞", "Page Up"), kVK_PageDown: ("⇟", "Page Down"),
        kVK_ANSI_KeypadEnter: ("⌤", "Enter"),
    ]

    private static let functionKeys: [Int: Int] = [
        kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6, kVK_F7: 7, kVK_F8: 8, kVK_F9: 9, kVK_F10: 10,
        kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14, kVK_F15: 15, kVK_F16: 16, kVK_F17: 17, kVK_F18: 18,
        kVK_F19: 19, kVK_F20: 20,
    ]

    var isFunctionKey: Bool { Self.functionKeys[Int(keyCode)] != nil }

    /// Carbon's mask from AppKit's flags. Caps Lock, Fn and the rest are left out: hot keys ignore them.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// What the recorder does with a key press.
    enum Recorded: Equatable {
        case combo(KeyCombo)
        /// Escape: stop recording, keep what was there.
        case cancel
        /// Delete or Forward Delete on its own: remove the shortcut.
        case clear
        /// Fewer than two of Control, Option and Command: it would clash with typing (⌥E types é) or an app's own
        /// shortcuts (⌘S, ⌃A), everywhere, since a hot key is system-wide.
        case needsModifiers
    }

    /// What the recorder says after a `needsModifiers` press.
    static let modifiersHint = "Use at least two of Control, Option and Command, so it can't clash with typing or an app's own shortcuts."

    static func record(keyCode: UInt32, modifiers: UInt32, characters: String?) -> Recorded {
        let combo = KeyCombo(keyCode: keyCode, modifiers: modifiers, key: (characters ?? "").uppercased())
        if modifiers == 0 {
            if keyCode == UInt32(kVK_Escape) { return .cancel }
            if keyCode == UInt32(kVK_Delete) || keyCode == UInt32(kVK_ForwardDelete) { return .clear }
        }
        // F-keys are free enough to stand alone; anything else needs two of Control, Option and Command (Shift
        // doesn't count).
        let strong = [cmdKey, optionKey, controlKey].filter { modifiers & UInt32($0) != 0 }.count
        if strong < 2 && !combo.isFunctionKey { return .needsModifiers }
        return .combo(combo)
    }
}

// MARK: - The saved shortcut and its registration

/// The jump shortcut: none by default, recorded in Settings → General, saved in this copy's own preferences (the
/// release and a local build each have theirs) and registered as a hot key while set.
@MainActor
final class JumpShortcut: ObservableObject {
    static let shared = JumpShortcut()
    nonisolated static let key = "jumpShortcut"
    /// `--demo` renders read this instead, in memory only: "1" for ⌃⌥J, "taken" for ⌃⌥J refused by the system,
    /// "othercopy" for ⌃⌥J also saved by the other copy of Dashbar.
    nonisolated static let demoVariable = "DASHBAR_DEMO_JUMP_SHORTCUT"

    /// Why the saved shortcut isn't working, in words, or nil when it is (or none is set).
    enum Problem: Equatable {
        case takenByOtherApp
        case takenByWindowShortcut
        case usedByMacOS
        /// The other copy (the release, or a local build) has saved the same shortcut. Both copies register it (macOS
        /// lets two apps hold one combination), so this is a warning, not a failure.
        case sharedWithOtherCopy(name: String)
    }

    @Published private(set) var combo: KeyCombo?
    @Published private(set) var problem: Problem?

    /// What a press does; set by the store.
    var action: (() -> Void)?

    private let isDemo = CommandLine.arguments.contains("--demo")

    private init() {
        if isDemo {
            let value = ProcessInfo.processInfo.environment[Self.demoVariable]
            if value != nil { combo = KeyCombo(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | optionKey), key: "J") }
            if value == "taken" { problem = .takenByOtherApp }
            if value == "othercopy" { problem = .sharedWithOtherCopy(name: Self.otherCopy.name) }
            return
        }
        combo = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
    }

    /// Registers the saved shortcut, if any. Called at launch, after a change, and when the window shortcut turns on or off.
    func apply() {
        guard !isDemo else { return }
        HotKeys.shared.unregister(.jump)
        guard let combo else { problem = nil; return }
        if GlobalShortcut.isEnabled && combo == GlobalShortcut.combo { problem = .takenByWindowShortcut; return }
        if Self.macOSUses(combo) { problem = .usedByMacOS; return }
        let ok = HotKeys.shared.register(.jump, keyCode: combo.keyCode, modifiers: combo.modifiers) { [weak self] in
            self?.action?()
        }
        // macOS refuses a combination this process already holds; another process holding it is usually not refused
        // (checked on macOS 27), so the other copy of Dashbar is asked directly.
        problem = !ok ? .takenByOtherApp : Self.otherCopyCombo() == combo ? .sharedWithOtherCopy(name: Self.otherCopy.name) : nil
    }

    /// The other copy of Dashbar: the release looks at the local build, and the other way round.
    nonisolated static var otherCopy: (id: String, name: String) {
        BuildInfo.isLocal ? ("fun.dashbar.app", "Dashbar") : ("fun.dashbar.app.local", "Dashbar Local")
    }

    /// The jump shortcut the other copy saved, read from its own preferences, if that copy is installed.
    private static func otherCopyCombo() -> KeyCombo? {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: otherCopy.id) != nil,
              let data = UserDefaults(suiteName: otherCopy.id)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    func set(_ new: KeyCombo?) {
        guard !isDemo else { combo = new; return }
        combo = new
        if let new, let data = try? JSONEncoder().encode(new) {
            UserDefaults.standard.set(data, forKey: Self.key)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
        apply()
    }

    /// The sentence under the recorder when the shortcut can't work.
    nonisolated static func message(_ problem: Problem, combo: KeyCombo) -> String {
        switch problem {
        case .takenByOtherApp:
            return "Another app is using \(combo.display), so it won't jump to your agents. Pick another shortcut."
        case .takenByWindowShortcut:
            return "\(combo.display) already opens the Dashbar window. Pick another shortcut."
        case .usedByMacOS:
            return "macOS uses \(combo.display) for one of its own shortcuts. Pick another, or turn that one off in System Settings → Keyboard."
        case .sharedWithOtherCopy(let name):
            return "\(name) uses \(combo.display) too. Give each copy its own shortcut, so a press goes to the one you mean."
        }
    }

    /// A shortcut macOS keeps for itself and has switched on (Spotlight, Mission Control, screenshots, input sources).
    /// Registering one of those succeeds but never fires, so it's caught here instead.
    private static func macOSUses(_ combo: KeyCombo) -> Bool {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let items = list?.takeRetainedValue() as? [[String: Any]] else { return false }
        return items.contains { item in
            guard (item[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = (item[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                  let mods = (item[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value else { return false }
            let mask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
            return code == combo.keyCode && mods & mask == combo.modifiers & mask
        }
    }
}

extension HostApp {
    /// Brings a session's app forward, as clicking its row in the panel does.
    @MainActor static func open(_ session: LiveSession) {
        open(info(for: session)?.bundle, root: session.root, session: session.agent == .claude ? session.id : nil)
    }

    /// A workspace's host button: the most urgent of its sessions that runs in that app.
    @MainActor static func open(_ host: Info, in workspace: Workspace) {
        if let session = workspace.sessions.first(where: { info(for: $0) == host }) { open(session) }
        else { open(host.bundle, root: workspace.root) }
    }
}
