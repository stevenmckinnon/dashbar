import SwiftUI

/// A Claude Code permission prompt, answered from Dashbar: what Claude wants to do, Allow once, Deny, or go to the session
/// (which hands the prompt back to the terminal, with every option Claude Code offers there).
struct PermissionPrompt: View {
    @EnvironmentObject var store: Store
    @Environment(\.promptFocusScope) private var focusScope
    let request: PermissionRequest
    /// Name the project, where the prompt isn't already under its workspace.
    var showsProject = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: UI.Size.caption, weight: .semibold))
                    .foregroundStyle(UI.attention)
                    .accessibilityHidden(true)
                Text(heading).font(.system(size: UI.Size.body, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Self.remaining(request.expires, now: ctx.date))
                        .font(.system(size: UI.Size.caption).monospacedDigit())
                        .foregroundStyle(UI.textSecondary)
                        .help("Time left to answer here. The session's terminal is asking too, and still will after this")
                }
            }
            // Never cut here: a person must see everything they are allowing. A long request scrolls in a box of
            // fixed height (the island sizes itself once per state) and says it is longer than the box.
            if let detail = request.shownDetail {
                if PermissionRequest.isLong(detail) {
                    ScrollView(.vertical) { detailText(detail) }
                        .scrollIndicators(.visible)
                        .frame(height: Self.longHeight)
                        .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous).fill(Color.primary.opacity(0.06)))
                    Text(PermissionRequest.longNote(detail))
                        .font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(.primary)
                } else {
                    detailText(detail)
                        .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous).fill(Color.primary.opacity(0.06)))
                }
            }
            if let note = request.omittedNote {
                Text(note).font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let why = request.why {
                Text(verbatim: why).font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary).lineLimit(2)
            }
            HStack(spacing: 6) {
                PromptButton(title: "Allow once", prominent: true) { store.answer(request, .allow) }
                    .help("Let Claude do this once. Nothing is added to your permission rules.")
                PromptButton(title: "Deny", prominent: false) { store.answer(request, .deny) }
                    .help("Tell Claude no. It carries on with your reply in mind.")
                Spacer(minLength: 6)
                Button { store.openSession(for: request) } label: {
                    Text("Open session").font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(UI.textSecondary)
                }
                .buttonStyle(PressStyle())
                .help("Answer in the session instead, with every option Claude Code offers")
                // Where keyboard focus starts on Overview while a prompt waits: one Shift-Tab from Deny, two from
                // Allow once. Never on Allow itself, so no single key press approves anything.
                .modifier(DefaultFocus(scope: store.permissionRequests.first?.id == request.id ? focusScope : nil))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: UI.innerRadius + 2, style: .continuous).fill(UI.attention.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: UI.innerRadius + 2, style: .continuous).strokeBorder(UI.attention.opacity(0.35)))
        .accessibilityElement(children: .contain)
        // The request itself is read from the text inside, in full; a one-line summary here would be cut short.
        .accessibilityLabel("Claude needs permission" + (request.project.isEmpty ? "" : " in \(request.project)") + ": \(request.action)")
    }

    /// About six lines of the monospaced caption text.
    static let longHeight: CGFloat = 96

    private func detailText(_ detail: String) -> some View {
        Text(verbatim: detail)
            .font(.system(size: UI.Size.caption, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private var heading: String {
        var text = request.action
        if showsProject, !request.project.isEmpty { text += " in \(request.project)" }
        if let agent = request.agentType { text += " (\(agent))" }
        // Under a session row the row already names the account.
        if showsProject, let account = store.accountLabel(for: request) { text += " · \(account)" }
        return text
    }

    /// "0:42": time left to answer here (the terminal asks too, and keeps asking after).
    static func remaining(_ expires: Date, now: Date) -> String {
        let s = max(0, Int(expires.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d left", s / 60, s % 60)
    }
}

/// Takes the default keyboard focus in `scope`, when there is one.
private struct DefaultFocus: ViewModifier {
    let scope: Namespace.ID?
    func body(content: Content) -> some View {
        if let scope { content.prefersDefaultFocus(true, in: scope) } else { content }
    }
}

extension PermissionRequest {
    /// Up to this much shows as plain text in the card; anything longer scrolls in a box and says so.
    static let shownLines = 5
    static let shownCharacters = 300

    /// Everything Dashbar has of the request, uncut. The bridge's own limits (file contents and edits left out, input
    /// over 16 KB dropped) are the only cut, and `omittedNote` says when one applied.
    var shownDetail: String? { detail(limit: .max, maxLines: .max) }

    /// Longer than the card shows at a glance.
    static func isLong(_ text: String) -> Bool {
        text.components(separatedBy: "\n").count > shownLines || text.count > shownCharacters
    }

    /// "Scroll to see all 23 lines" under a long request, so nobody answers having read only the top of it.
    static func longNote(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").count
        if lines > shownLines { return "Scroll to see all \(lines) lines before you answer." }
        return "Scroll to see all \(text.count.formatted()) characters before you answer."
    }

    /// Said when part of the request never reached Dashbar, so the full version is only in the terminal: the bridge
    /// drops input over 16 KB (or input it can't read), and always leaves out file contents and edits.
    var omittedNote: String? {
        let tooLong = "This request was too long to pass to Dashbar. The full "
            + (["Bash", "Monitor", "PowerShell"].contains(tool) ? "command" : "request") + " is only in the terminal."
        switch tool {
        case "Bash", "Monitor", "PowerShell": return input["command"] == nil ? tooLong : nil
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            if input["file_path"] == nil && input["notebook_path"] == nil { return tooLong }
            return "The change itself is shown only in the terminal."
        case "Read": return input["file_path"] == nil ? tooLong : nil
        case "WebFetch": return input["url"] == nil ? tooLong : nil
        case "WebSearch": return input["query"] == nil ? tooLong : nil
        case "Glob", "Grep": return input["pattern"] == nil ? tooLong : nil
        case "Agent", "Task": return input["description"] == nil && input["prompt"] == nil ? tooLong : nil
        default:
            // Some tools take nothing, so this can't tell a dropped input from an empty one: it says only what is true.
            return input.isEmpty ? "No details reached Dashbar. Check the terminal for the full request." : nil
        }
    }
}

/// A small text button drawn by hand, so it also renders in offline snapshots. Prominent is filled with the text
/// colour; neither uses a status colour, since answering isn't a status.
private struct PromptButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: UI.Size.caption, weight: .semibold))
                .foregroundStyle(prominent ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.primary))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(prominent ? Color.primary.opacity(hover ? 0.75 : 0.88)
                                                      : Color.primary.opacity(hover ? 0.14 : 0.08)))
                .touchTarget()
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
    }
}

/// A session's row, with its permission prompt under it while one is waiting.
struct SessionBlock: View {
    @EnvironmentObject var store: Store
    @Environment(\.inWindow) private var inWindow
    let session: LiveSession
    var body: some View {
        SessionLine(session: session, context: store.contexts[session.id])
        let agents = store.subagents(for: session)
        if !agents.isEmpty {
            // The window lists each one; the panel says how many, and opens into the list.
            if inWindow { SubagentList(agents: agents) } else { SubagentSummary(agents: agents).padding(.leading, 1) }
        }
        if let request = store.permissionRequest(for: session) {
            PermissionPrompt(request: request).padding(.bottom, 4)
        }
    }
}

/// Prompts listed on their own: those whose session isn't shown elsewhere on the page.
struct PermissionPromptList: View {
    let requests: [PermissionRequest]
    var body: some View {
        if !requests.isEmpty {
            VStack(spacing: 8) {
                ForEach(requests) { PermissionPrompt(request: $0, showsProject: true) }
            }
        }
    }
}
