import Foundation
import Testing
@testable import Dashbar

// MARK: - One rounding rule per kind of figure

@Suite struct ByteRoundingTests {
    @Test func cleanUpSizesUseOneRuleEverywhere() {
        // The tile splits the same text the list and the sidebar show, so "7 GB" never sits beside "6.52 GB".
        let total: UInt64 = 7_000_000_000
        let (value, unit) = Fmt.bytesSplit(total)
        #expect(value + " " + unit == Fmt.diskBytes(total))
    }

    @Test func memorySplitsTheWayMemoryIsWritten() {
        let mem: UInt64 = 1_190_000_000
        let (value, unit) = Fmt.bytesSplit(mem, style: .memory)
        #expect(value + " " + unit == Fmt.bytes(mem))
    }
}

// MARK: - Clean-up order and per-workspace folders

@Suite struct CleanupOrderTests {
    private func item(_ path: String, _ size: UInt64) -> CleanupItem {
        CleanupItem(path: path, kind: URL(fileURLWithPath: path).lastPathComponent, project: "p", size: size)
    }

    @Test func largestFirstWithTiesInPathOrder() {
        let sorted = Cleanup.sorted([item("/a/node_modules", 10), item("/c/.next", 30), item("/b/node_modules", 10)])
        #expect(sorted.map(\.path) == ["/c/.next", "/a/node_modules", "/b/node_modules"])
    }

    @Test func aWorkspaceGetsOnlyTheFoldersInsideIt() {
        let all = [
            item("/dev/shop/node_modules", 5),
            item("/dev/shop/.claude/worktrees/x/node_modules", 9),
            item("/dev/shop-admin/node_modules", 50),   // a sibling whose name starts the same
            item("/dev/notes/.build", 7),
        ]
        #expect(Cleanup.items(in: "/dev/shop", from: all).map(\.path)
                == ["/dev/shop/.claude/worktrees/x/node_modules", "/dev/shop/node_modules"])
        #expect(Cleanup.items(in: "/dev/shop/", from: all).count == 2)
        #expect(Cleanup.items(in: "", from: all).isEmpty)
    }
}

// MARK: - Which processes the window may quit

@Suite struct QuitPolicyTests {
    let me: uid_t = 501
    let own: pid_t = 400

    @Test func theUsersOwnToolsMayBeQuit() {
        #expect(QuitPolicy.allows(pid: 1234, path: "/opt/homebrew/bin/node", uid: me, ownPID: own, ownUID: me))
        #expect(QuitPolicy.allows(pid: 1234, path: "/Users/me/.local/share/claude/versions/2.1.318", uid: me, ownPID: own, ownUID: me))
    }

    @Test func systemAndOtherUsersProcessesAreLeftAlone() {
        #expect(!QuitPolicy.allows(pid: 1, path: "/sbin/launchd", uid: 0, ownPID: own, ownUID: me))
        #expect(!QuitPolicy.allows(pid: 1234, path: "/usr/libexec/trustd", uid: me, ownPID: own, ownUID: me))
        #expect(!QuitPolicy.allows(pid: 1234, path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", uid: me, ownPID: own, ownUID: me))
        #expect(!QuitPolicy.allows(pid: 1234, path: "/opt/homebrew/bin/node", uid: 502, ownPID: own, ownUID: me))
        #expect(!QuitPolicy.allows(pid: 1234, path: "/opt/homebrew/bin/node", uid: nil, ownPID: own, ownUID: me))
        #expect(!QuitPolicy.allows(pid: 1234, path: nil, uid: me, ownPID: own, ownUID: me))
    }

    @Test func dashbarNeverQuitsItselfOrItsOtherCopy() {
        #expect(!QuitPolicy.allows(pid: own, path: "/opt/homebrew/bin/node", uid: me, ownPID: own, ownUID: me))
        #expect(!QuitPolicy.allows(pid: 1234, path: "/Applications/Dashbar.app/Contents/MacOS/Dashbar", uid: me, ownPID: own, ownUID: me))
        #expect(!QuitPolicy.allows(pid: 1234, path: "/Applications/Dashbar Local.app/Contents/MacOS/Dashbar Local", uid: me, ownPID: own, ownUID: me))
    }

    @Test func theConfirmNamesWhatItQuits() {
        #expect(ProcessRow.confirmTitle(.init(name: "node", count: 1, pids: [10])) == "Quit node")
        #expect(ProcessRow.confirmTitle(.init(name: "node", count: 3, pids: [10, 11, 12])) == "Quit 3 node processes")
    }
}

// MARK: - The host app's name

@Suite struct HostShortcutTests {
    let vscode = Launcher.App(url: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"), name: "VS Code")
    let ghostty = Launcher.App(url: URL(fileURLWithPath: "/Applications/Ghostty.app"), name: "Ghostty")
    let orca = HostApp.Info(bundle: "/Applications/Orca.app", name: "Orca")

    @Test func theAgentsAppGetsAButtonOnceAndTheChosenEditorAndTerminalDont() {
        let code = HostApp.Info(bundle: "/Applications/Visual Studio Code.app", name: "Visual Studio Code")
        let ghosttyHost = HostApp.Info(bundle: "/Applications/Ghostty.app/", name: "Ghostty")
        let t3 = HostApp.Info(bundle: "/Applications/T3 Code (Beta).app", name: "T3 Code")
        let hosts = [code, orca, ghosttyHost, orca, t3]
        #expect(HostApp.shortcuts(hosts: hosts, excluding: [vscode, ghostty], limit: 2) == [orca, t3])
        #expect(HostApp.shortcuts(hosts: hosts, excluding: [vscode, ghostty], limit: 1) == [orca])
        #expect(HostApp.shortcuts(hosts: [code, ghosttyHost], excluding: [vscode, ghostty], limit: 2).isEmpty)
    }

    @Test func aHostWithNoAppToOpenGetsNoButton() {
        // demo renders' invented hosts: the button would only open the editor again
        let claude = HostApp.Info(bundle: nil, name: "Claude")
        #expect(HostApp.shortcuts(hosts: [claude, orca], excluding: [vscode], limit: 2) == [orca])
    }
}

@Suite struct HostAppNameTests {
    @Test func theBundleNameWithoutItsExtensionOrChannel() {
        #expect(HostApp.name(ofBundle: "/Applications/T3 Code (Beta).app") == "T3 Code")   // no release channel
        #expect(HostApp.name(ofBundle: "/Applications/Utilities/Terminal.app") == "Terminal")
    }

    @Test func demoHostsAreInventedFromTheEntrypoint() {
        #expect(HostApp.demoInfo(entrypoint: "cli")?.name == "Terminal")
        #expect(HostApp.demoInfo(entrypoint: "claude-desktop")?.name == "Claude")
        #expect(HostApp.demoInfo(entrypoint: "claude-vscode")?.name == "VS Code")
        #expect(HostApp.demoInfo(entrypoint: "cli")?.bundle == nil)
    }
}
