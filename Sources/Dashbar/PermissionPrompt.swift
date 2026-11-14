import SwiftUI

/// A Claude Code permission prompt, answered from Dashbar: what Claude wants to do, Allow once, Deny, or go to the session
/// (which hands the prompt back to the terminal, with every option Claude Code offers there).
struct PermissionPrompt: View {
    @EnvironmentObject var store: Store
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
                        .help("If you don't answer here, Claude Code asks in the terminal")
                }
            }
            if let detail = request.detail() {
                Text(verbatim: detail)
                    .font(.system(size: UI.Size.caption, design: .monospaced))
                    .lineLimit(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous).fill(Color.primary.opacity(0.06)))
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
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: UI.innerRadius + 2, style: .continuous).fill(UI.attention.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: UI.innerRadius + 2, style: .continuous).strokeBorder(UI.attention.opacity(0.35)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude needs permission: \(request.oneLine)")
    }

    private var heading: String {
        var text = request.action
        if showsProject, !request.project.isEmpty { text += " in \(request.project)" }
        if let agent = request.agentType { text += " (\(agent))" }
        return text
    }

    /// "0:42": time left before Claude Code asks in the terminal instead.
    static func remaining(_ expires: Date, now: Date) -> String {
        let s = max(0, Int(expires.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
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
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
    }
}

/// A session's row, with its permission prompt under it while one is waiting.
struct SessionBlock: View {
    @EnvironmentObject var store: Store
    let session: LiveSession
    var body: some View {
        SessionLine(session: session, context: store.contexts[session.id])
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
