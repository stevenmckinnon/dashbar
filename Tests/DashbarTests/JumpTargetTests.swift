import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Dashbar

// MARK: - Jump to the agent that needs you: which session, and the recorder's keys

@Suite struct JumpTargetTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func session(_ id: String, _ status: String, agent: SessionAgent = .claude, since: Date? = nil) -> LiveSession {
        LiveSession(id: id, pid: 1, name: "Task \(id)", cwd: "/p/\(id)", status: status, since: since ?? t0,
                    entrypoint: "cli", root: "/p/\(id)", agent: agent)
    }

    func choose(_ sessions: [LiveSession], waiting: [String: Date] = [:], finished: [String: Date] = [:],
                hidden: Set<HideableTool> = []) -> JumpTarget.Choice? {
        JumpTarget.choose(sessions: sessions, waitingSince: waiting, finishedAt: finished,
                          visibility: ToolVisibility(hidden: hidden))
    }

    @Test func longestWaitComesFirst() {
        let sessions = [session("a", "waiting"), session("b", "waiting", agent: .opencode), session("c", "waiting", agent: .copilot)]
        let pick = choose(sessions, waiting: ["a": t0.addingTimeInterval(30), "b": t0, "c": t0.addingTimeInterval(10)])
        #expect(pick == JumpTarget.Choice(session: sessions[1], reason: .needsYou))
    }

    @Test func waitingBeatsAFresherFinish() {
        let sessions = [session("done", "idle"), session("asks", "waiting", agent: .geminiCLI)]
        let pick = choose(sessions, waiting: ["asks": t0], finished: ["done": t0.addingTimeInterval(60)])
        #expect(pick?.session.id == "asks")
        #expect(pick?.reason == .needsYou)
    }

    @Test func anUntimedWaitFallsBackToTheSessionsOwnTime() {
        // Seen waiting before Dashbar timed it: its own `since` stands in.
        let sessions = [session("new", "waiting", since: t0.addingTimeInterval(50)), session("old", "waiting", since: t0)]
        #expect(choose(sessions, waiting: ["new": t0.addingTimeInterval(40)])?.session.id == "old")
    }

    @Test func aTieIsBrokenTheSameWayEveryTime() {
        let sessions = [session("b", "waiting"), session("a", "waiting")]
        #expect(choose(sessions, waiting: ["a": t0, "b": t0])?.session.id == "a")
        #expect(choose(sessions.reversed(), waiting: ["a": t0, "b": t0])?.session.id == "a")
    }

    @Test func withNobodyWaitingTheLatestFinishWins() {
        let sessions = [session("a", "idle"), session("b", "idle", agent: .antigravity), session("c", "idle")]
        let pick = choose(sessions, finished: ["a": t0, "b": t0.addingTimeInterval(20), "c": t0.addingTimeInterval(5)])
        #expect(pick == JumpTarget.Choice(session: sessions[1], reason: .finished))
    }

    @Test func aFinishedSessionWorkingAgainDoesNotCount() {
        let sessions = [session("again", "busy"), session("earlier", "idle")]
        let pick = choose(sessions, finished: ["again": t0.addingTimeInterval(60), "earlier": t0])
        #expect(pick?.session.id == "earlier")
    }

    @Test func hiddenToolsNeverCount() {
        let sessions = [session("oc", "waiting", agent: .opencode), session("cp", "idle", agent: .copilot),
                        session("gm", "waiting", agent: .antigravityCLI), session("cl", "idle")]
        let waiting = ["oc": t0, "gm": t0.addingTimeInterval(1)]
        let finished = ["cp": t0.addingTimeInterval(9), "cl": t0]
        #expect(choose(sessions, waiting: waiting, finished: finished, hidden: [.opencode])?.session.id == "gm")
        #expect(choose(sessions, waiting: waiting, finished: finished, hidden: [.opencode, .google])?.session.id == "cp")
        let onlyClaude = choose(sessions, waiting: waiting, finished: finished, hidden: [.opencode, .google, .copilot])
        #expect(onlyClaude == JumpTarget.Choice(session: sessions[3], reason: .finished))
    }

    @Test func nothingQualifies() {
        #expect(choose([]) == nil)
        // Working and idle sessions that never finished a stretch of work while Dashbar watched.
        #expect(choose([session("a", "busy"), session("b", "idle")]) == nil)
        // Only a hidden tool's session is waiting.
        #expect(choose([session("oc", "waiting", agent: .opencode)], waiting: ["oc": t0], hidden: [.opencode]) == nil)
    }

    @MainActor @Test func theDemoSessionsPickTheWaitingOne() {
        // The invented sessions screenshots use: with one agent waiting, that's where the shortcut goes.
        let store = Store(demo: true)
        let waiting = store.sessions.filter(\.isWaiting)
        let pick = JumpTarget.choose(sessions: store.sessions, waitingSince: [:], finishedAt: [:], visibility: .all)
        if let first = waiting.min(by: { $0.since != $1.since ? $0.since < $1.since : $0.id < $1.id }) {
            #expect(pick == JumpTarget.Choice(session: first, reason: .needsYou))
        } else {
            #expect(pick == nil)   // nothing finished while watched, nothing waiting
        }
    }
}

// MARK: - The timing SessionTransitions keeps for it

@Suite struct JumpTimingTests {
    func live(_ id: String, _ status: String) -> LiveSession {
        LiveSession(id: id, pid: 1, name: id, cwd: "/p", status: status, since: Date(timeIntervalSince1970: 0),
                    entrypoint: "cli", root: "/p")
    }

    @Test func waitsAreTimedFromWhenTheyBegin() {
        var t = SessionTransitions()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = t.update([live("a", "waiting")], now: start)                  // already waiting at launch: timed from then
        _ = t.update([live("a", "waiting"), live("b", "waiting")], now: start.addingTimeInterval(5))
        _ = t.update([live("a", "waiting"), live("b", "waiting")], now: start.addingTimeInterval(9))
        #expect(t.waitingSince == ["a": start, "b": start.addingTimeInterval(5)])
        _ = t.update([live("a", "busy"), live("b", "waiting")], now: start.addingTimeInterval(12))   // answered
        #expect(t.waitingSince == ["b": start.addingTimeInterval(5)])
        _ = t.update([], now: start.addingTimeInterval(13))                                          // gone
        #expect(t.waitingSince.isEmpty)
    }

    @Test func finishesAreRememberedWhileTheSessionLives() {
        var t = SessionTransitions()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = t.update([live("s", "busy")], now: start)
        _ = t.update([live("s", "idle")], now: start.addingTimeInterval(2))           // too short to count
        #expect(t.finishedAt.isEmpty)
        _ = t.update([live("s", "busy")], now: start.addingTimeInterval(10))
        _ = t.update([live("s", "idle")], now: start.addingTimeInterval(30))
        #expect(t.finishedAt == ["s": start.addingTimeInterval(30)])
        _ = t.update([], now: start.addingTimeInterval(31))
        #expect(t.finishedAt.isEmpty)
    }
}

// MARK: - Recording a key combination

@Suite struct KeyComboTests {
    let ctrlOpt = UInt32(controlKey | optionKey)

    @Test func showsAndSpeaksTheCombination() {
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey), key: "j")
        #expect(combo.display == "⌃⌥⇧⌘J")
        #expect(combo.spoken == "Control Option Shift Command J")
        let arrow = KeyCombo(keyCode: UInt32(kVK_LeftArrow), modifiers: ctrlOpt, key: "")
        #expect(arrow.display == "⌃⌥←")
        #expect(arrow.spoken == "Control Option Left Arrow")
        #expect(KeyCombo(keyCode: UInt32(kVK_F5), modifiers: 0, key: "").display == "F5")
    }

    @Test func readsAppKitsModifiers() {
        #expect(KeyCombo.carbonModifiers([.control, .option, .capsLock, .function]) == ctrlOpt)
        #expect(KeyCombo.carbonModifiers([.command, .shift]) == UInt32(cmdKey | shiftKey))
    }

    @Test func recordsOnlyCombinationsThatCantClash() {
        let j = UInt32(kVK_ANSI_J)
        #expect(KeyCombo.record(keyCode: j, modifiers: ctrlOpt, characters: "j")
                == .combo(KeyCombo(keyCode: j, modifiers: ctrlOpt, key: "J")))
        #expect(KeyCombo.record(keyCode: j, modifiers: UInt32(optionKey | cmdKey), characters: "j") != .needsModifiers)
        for one in [0, cmdKey, optionKey, controlKey, shiftKey | cmdKey, shiftKey | optionKey] {
            #expect(KeyCombo.record(keyCode: j, modifiers: UInt32(one), characters: "j") == .needsModifiers)
        }
        #expect(KeyCombo.record(keyCode: UInt32(kVK_F6), modifiers: 0, characters: nil)
                == .combo(KeyCombo(keyCode: UInt32(kVK_F6), modifiers: 0, key: "")))
    }

    @Test func escapeCancelsAndDeleteClears() {
        #expect(KeyCombo.record(keyCode: UInt32(kVK_Escape), modifiers: 0, characters: nil) == .cancel)
        #expect(KeyCombo.record(keyCode: UInt32(kVK_Delete), modifiers: 0, characters: nil) == .clear)
        #expect(KeyCombo.record(keyCode: UInt32(kVK_ForwardDelete), modifiers: 0, characters: nil) == .clear)
        // With modifiers they're ordinary keys.
        #expect(KeyCombo.record(keyCode: UInt32(kVK_Delete), modifiers: ctrlOpt, characters: nil) != .clear)
    }

    @Test func savesAndReadsBack() throws {
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_J), modifiers: ctrlOpt, key: "J")
        let data = try JSONEncoder().encode(combo)
        #expect(try JSONDecoder().decode(KeyCombo.self, from: data) == combo)
    }

    @Test func theWindowShortcutIsRecognised() {
        #expect(GlobalShortcut.combo.display == GlobalShortcut.display)
    }

    @Test func problemsAreSaidInWords() {
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_J), modifiers: ctrlOpt, key: "J")
        #expect(JumpShortcut.message(.takenByOtherApp, combo: combo).hasPrefix("Another app is using ⌃⌥J"))
        #expect(JumpShortcut.message(.takenByWindowShortcut, combo: combo).contains("opens the Dashbar window"))
        #expect(JumpShortcut.message(.usedByMacOS, combo: combo).contains("System Settings"))
        #expect(JumpShortcut.message(.sharedWithOtherCopy(name: "Dashbar Local"), combo: combo)
                == "Dashbar Local uses ⌃⌥J too. Give each copy its own shortcut, so a press goes to the one you mean.")
    }
}
