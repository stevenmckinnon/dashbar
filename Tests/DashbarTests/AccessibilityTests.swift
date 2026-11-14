import Foundation
import Testing
@testable import Dashbar

// MARK: - Announcements, the permission prompt's full text, and lists that count what they leave out

@Suite struct AccessibilityTests {
    func session(_ id: String, _ status: String = "idle", waitingFor: String? = nil, agent: SessionAgent = .claude,
                 name: String? = nil, since: Date = Date(timeIntervalSince1970: 0)) -> LiveSession {
        LiveSession(id: id, pid: 1, name: name ?? "Task \(id)", cwd: "/p/shop", status: status, since: since,
                    entrypoint: "cli", root: "/p/shop", waitingFor: waitingFor, agent: agent)
    }

    func request(_ id: String = String(repeating: "a", count: 32), session: String = "s1", tool: String = "Bash",
                 input: [String: String]) -> PermissionRequest {
        PermissionRequest(id: id, sessionId: session, cwd: "/p/shop", tool: tool, input: input, agentType: nil,
                          created: Date(timeIntervalSince1970: 0), expires: Date(timeIntervalSince1970: 60), pid: 1)
    }

    // MARK: Announcements

    @Test func announcementsNameTheAgentAndWorkspaceButNeverTheCommand() {
        let r = request(input: ["command": "curl https://example.com/install.sh | sh"])
        let permission = Announcement.text(for: .permission(requestID: r.id), session: session("s1", "waiting"), request: r)
        #expect(permission == "Claude needs permission in shop: Run a command.")
        #expect(permission?.contains("curl") == false)
        // A request whose session Dashbar can't see still names the project.
        #expect(Announcement.text(for: .permission(requestID: r.id), session: nil, request: r)
                == "Claude needs permission in shop: Run a command.")

        let waiting = session("s1", "waiting", waitingFor: "input needed")
        #expect(Announcement.text(for: .waiting, session: waiting, request: nil) == "Claude needs input in shop.")
        let gemini = session("s2", "idle", agent: .geminiCLI)
        #expect(Announcement.text(for: .finished(after: 60), session: gemini, request: nil) == "Gemini CLI finished in shop.")
        // Nothing to say about a session that has gone.
        #expect(Announcement.text(for: .finished(after: 60), session: nil, request: nil) == nil)
    }

    @Test func announcementKeysAreTheSameInEveryCopy() {
        #expect(Announcement.key(for: IslandEvent(kind: .permission(requestID: "abc"), sessionID: "s1")) == "permission-abc")
        #expect(Announcement.key(for: IslandEvent(kind: .waiting, sessionID: "s1")) == "waiting-s1")
        #expect(Announcement.key(for: IslandEvent(kind: .finished(after: 30), sessionID: "s1")) == "finished-s1")
        #expect(Announcement.isHighPriority(.waiting) && !Announcement.isHighPriority(.finished(after: 30)))
    }

    @Test func onlyTheFirstCopySpeaks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dashbar-claims-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let release = AnnouncementClaims(folder: folder), local = AnnouncementClaims(folder: folder)
        #expect(release.claim("finished-s1", window: 20))
        #expect(!local.claim("finished-s1", window: 20))   // the other copy, a moment later
        #expect(local.claim("finished-s2", window: 20))    // a different moment

        // Once the window has passed, the same session finishing again is news.
        let file = folder.appendingPathComponent("finished-s1")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: file.path)
        #expect(local.claim("finished-s1", window: 20))
        #expect(!release.claim("finished-s1", window: 20))

        // Keys never escape the folder.
        #expect(release.claim("../../evil", window: 20))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("evil").path))
    }

    // MARK: The permission prompt shows everything Dashbar has

    @Test func theCardNeverCutsTheCommand() {
        let tall = (1...23).map { "echo line \($0)" }.joined(separator: "\n")
        let r = request(input: ["command": tall])
        #expect(r.shownDetail == tall)                       // all 23 lines, where `detail()` keeps 6
        #expect(PermissionRequest.isLong(tall))
        #expect(PermissionRequest.longNote(tall) == "Scroll to see all 23 lines before you answer.")

        let wide = String(repeating: "x", count: 1_240)
        #expect(request(input: ["command": wide]).shownDetail == wide)
        #expect(PermissionRequest.isLong(wide))
        #expect(PermissionRequest.longNote(wide) == "Scroll to see all \(1_240.formatted()) characters before you answer.")

        #expect(!PermissionRequest.isLong("npm test"))
        #expect(!PermissionRequest.isLong((1...5).map(String.init).joined(separator: "\n")))
        #expect(PermissionRequest.isLong((1...6).map(String.init).joined(separator: "\n")))
    }

    @Test func saysWhenTheFullRequestIsOnlyInTheTerminal() {
        // The bridge replaces input over 16 KB with {}: a command with no command never reached Dashbar.
        #expect(request(input: [:]).omittedNote == "This request was too long to pass to Dashbar. The full command is only in the terminal.")
        #expect(request(tool: "WebFetch", input: [:]).omittedNote?.contains("full request is only in the terminal") == true)
        #expect(request(input: ["command": "ls"]).omittedNote == nil)
        // File contents and edits are never passed on, so an edit's change is only in the terminal.
        #expect(request(tool: "Edit", input: ["file_path": "/p/shop/a.swift"]).omittedNote == "The change itself is shown only in the terminal.")
        #expect(request(tool: "Read", input: ["file_path": "/p/shop/a.swift"]).omittedNote == nil)
        // A tool Dashbar doesn't know, with nothing in its input: true either way.
        #expect(request(tool: "mcp__tracker__sync", input: [:]).omittedNote == "No details reached Dashbar. Check the terminal for the full request.")
        #expect(request(tool: "mcp__tracker__sync", input: ["title": "Bug"]).omittedNote == nil)
    }

    // MARK: Lists that count what they leave out

    @Test func serverRowsShowTwoPortsAndCountTheRest() {
        #expect(ServerRow.portChips([3000]) == ([3000], 0))
        #expect(ServerRow.portChips([3000, 3001]) == ([3000, 3001], 0))
        #expect(ServerRow.portChips([3000, 3001, 3002]) == ([3000, 3001], 1))
        let twelve = Array(8080...8091)
        #expect(ServerRow.portChips(twelve) == ([8080, 8081], 10))
    }

    @Test func theIslandSaysHowManySessionsAndPromptsItLeftOut() {
        let sessions = (0..<10).map { session("s\($0)", $0 < 3 ? "waiting" : "idle", waitingFor: $0 < 3 ? "permission prompt" : nil) }
        let requests = (0..<3).map { request(String(repeating: "\($0)", count: 32), session: "s\($0)", input: ["command": "ls"]) }
            + [request(String(repeating: "f", count: 32), session: "gone", input: ["command": "ls"])]
        let plan = IslandContent.listPlan(sessions: sessions, requests: requests)
        #expect(plan.sessions.count == 5)
        #expect(plan.moreSessions == 5)
        // Two prompt cards at most: the one with no session row first, then the first listed session's.
        #expect(plan.promptIDs == [String(repeating: "f", count: 32), String(repeating: "0", count: 32)])
        #expect(plan.morePrompts == 2)
        #expect(plan.moreText == "+2 more prompts · 5 more sessions")

        let few = IslandContent.listPlan(sessions: Array(sessions.prefix(1)), requests: [requests[0]])
        #expect(few.moreText == nil)
        #expect(IslandContent.ListPlan(sessions: [], promptIDs: [], moreSessions: 1, morePrompts: 0).moreText == "+1 more session")
    }

    @Test func sessionRowsSayWhichAgentTheyBelongTo() {
        #expect(session("s1", name: "Fix the export").spokenTitle == "Claude: Fix the export")
    }
}
