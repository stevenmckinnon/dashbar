import SwiftUI
import AppKit

/// Settings → Integrations → Command-line tool: where the bundled `dashbar` is and, unless it's already on the PATH,
/// a command to link it there. Dashbar runs nothing itself, so it never asks for an administrator password.
struct CommandLineToolSection: View {
    @State private var copied = false

    /// `Contents/Helpers/dashbar` inside this app. Nil in a development build run outside a bundle.
    static var bundledTool: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/dashbar")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// A `dashbar` on the usual PATH folders that leads to this app's tool (a Homebrew link, or one made before).
    static func linked(to tool: URL) -> String? {
        let target = tool.resolvingSymlinksInPath().path
        return ["/opt/homebrew/bin/dashbar", "/usr/local/bin/dashbar"].first {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == target
        }
    }

    static func linkCommand(_ tool: URL) -> String {
        "sudo mkdir -p /usr/local/bin && sudo ln -sf '\(tool.path)' /usr/local/bin/dashbar"
    }

    var body: some View {
        if let tool = Self.bundledTool {
            Section {
                if let link = Self.linked(to: tool) {
                    LabeledContent {
                        EmptyView()
                    } label: {
                        Text("dashbar is on your PATH")
                        Text(link)
                    }
                } else {
                    LabeledContent {
                        Button(copied ? "Copied" : "Copy Command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.linkCommand(tool), forType: .string)
                            copied = true
                        }
                        .help(Self.linkCommand(tool))
                    } label: {
                        Text("Add dashbar to your PATH")
                        Text("Copies a command to run in Terminal. It asks for your password.")
                    }
                }
            } header: {
                Text("Command-line tool")
            } footer: {
                Text("Run dashbar in Terminal to see which agents need you, which are working and your plan limits. dashbar line prints one line for a tmux status bar or a shell prompt. It reads what Dashbar already shows, from a file only you can read, so Dashbar has to be running. Installing with Homebrew adds it for you.")
                    .settingsFooter()
            }
        }
    }
}
