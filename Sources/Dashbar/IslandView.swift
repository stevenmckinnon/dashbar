import SwiftUI
import AppKit

// MARK: - Dashbar Island: how it looks

/// The island's outline. Attached to the top edge it flares out at the top corners, the way the notch meets the
/// screen, so it reads as part of the hardware; floating, it is a plain rounded shape.
struct IslandShape: Shape {
    var bottomRadius: CGFloat
    /// Concave curve where the island meets the top edge; 0 when floating.
    var flare: CGFloat
    var topRadius: CGFloat
    /// Beside the notch, the side touching it stays square and unflared, so the two join.
    var squareLeading = false
    var squareTrailing = false

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(bottomRadius, AnimatablePair(flare, topRadius)) }
        set { bottomRadius = newValue.first; flare = newValue.second.first; topRadius = newValue.second.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let lf = squareLeading ? 0 : flare, tf = squareTrailing ? 0 : flare
        let left = r.minX + lf, right = r.maxX - tf
        let br = min(bottomRadius, (right - left) / 2, r.height / 2)
        let brL = squareLeading ? 0 : br, brT = squareTrailing ? 0 : br
        if flare > 0 || squareLeading || squareTrailing {
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            if lf > 0 { p.addQuadCurve(to: CGPoint(x: left, y: r.minY + lf), control: CGPoint(x: left, y: r.minY)) }
            p.addLine(to: CGPoint(x: left, y: r.maxY - brL))
            p.addQuadCurve(to: CGPoint(x: left + brL, y: r.maxY), control: CGPoint(x: left, y: r.maxY))
            p.addLine(to: CGPoint(x: right - brT, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: right, y: r.maxY - brT), control: CGPoint(x: right, y: r.maxY))
            p.addLine(to: CGPoint(x: right, y: r.minY + tf))
            if tf > 0 { p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: right, y: r.minY)) }
            p.closeSubpath()
        } else {
            p.addRoundedRect(in: r, cornerSize: CGSize(width: min(topRadius, r.height / 2), height: min(topRadius, r.height / 2)),
                             style: .continuous)
        }
        return p
    }
}

/// Sizes shared by the island's views and the window that holds them.
enum IslandMetrics {
    static let flare: CGFloat = 7
    static let bannerWidth: CGFloat = 380
    static let floatingHeight: CGFloat = 30
    static let statusFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    /// Each wing beside the notch, wide enough for the status (both wings match, so the island stays centred on it).
    static func wing(for status: IslandStatus) -> CGFloat {
        let text = (status.label as NSString).size(withAttributes: [.font: statusFont]).width
        return max(44, ceil(text) + 10 + 6 + 14) + flare
    }
}

/// The island itself, sized to its content. Always black, so it is drawn in the dark appearance whatever the system's.
struct IslandContent: View {
    @EnvironmentObject var store: Store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let mode: IslandMode
    let style: IslandStyle
    var onOpenSession: (LiveSession) -> Void = { _ in }
    var onOpenDashbar: () -> Void = {}
    /// A click on the collapsed pill opens the session list.
    var onExpand: () -> Void = {}

    /// One black shape whose size springs between modes, with the content cross-fading inside it.
    var body: some View {
        let s = shape(expanded: isExpanded)
        ZStack(alignment: .top) {
            switch mode {
            case .hidden:
                Color.clear.frame(width: 1, height: 1)
            case .collapsed(let status):
                collapsed(status).transition(.opacity)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onExpand)
            case .banner(let banner):
                expanded { bannerBody(banner) }.transition(.opacity)
            case .list:
                expanded { listBody }.transition(.opacity)
            }
        }
        .background(s.fill(.black))
        .overlay { if case .floating = style { s.stroke(Color.white.opacity(0.14), lineWidth: 0.5) } }
        .clipShape(s)
        .contentShape(s)
        .environment(\.colorScheme, .dark)
    }

    private var isExpanded: Bool {
        switch mode {
        case .banner, .list: return true
        case .hidden, .collapsed: return false
        }
    }

    // MARK: Shape

    private var topInset: CGFloat {
        if case .notch(_, let h) = style { return h }
        return 0
    }

    private func shape(expanded: Bool) -> IslandShape {
        switch style {
        case .notch:
            return IslandShape(bottomRadius: expanded ? 22 : 11, flare: IslandMetrics.flare, topRadius: 0)
        case .beside(let leading, _):
            return IslandShape(bottomRadius: expanded ? 22 : 11, flare: IslandMetrics.flare, topRadius: 0,
                               squareLeading: !leading, squareTrailing: leading)
        case .floating:
            return IslandShape(bottomRadius: expanded ? 22 : IslandMetrics.floatingHeight / 2, flare: 0,
                               topRadius: expanded ? 22 : IslandMetrics.floatingHeight / 2)
        }
    }

    /// Horizontal room taken by the flares, so content lines up with the island's visible body.
    private var flareInset: (leading: CGFloat, trailing: CGFloat) {
        switch style {
        case .notch: return (IslandMetrics.flare, IslandMetrics.flare)
        case .beside(let leading, _): return leading ? (IslandMetrics.flare, 0) : (0, IslandMetrics.flare)
        case .floating: return (0, 0)
        }
    }

    // MARK: Collapsed

    @ViewBuilder private func collapsed(_ status: IslandStatus) -> some View {
        switch style {
        case .notch(let width, let height):
            let wing = IslandMetrics.wing(for: status)
            HStack(spacing: 0) {
                BrandMarkView(size: 17)
                    .padding(.leading, 12 + IslandMetrics.flare)
                    .frame(width: wing, alignment: .leading)
                Color.clear.frame(width: width)
                statusLabel(status)
                    .padding(.trailing, 12 + IslandMetrics.flare)
                    .frame(width: wing, alignment: .trailing)
            }
            .frame(height: height)
        case .beside(_, let height):
            HStack(spacing: 8) {
                BrandMarkView(size: 16)
                statusLabel(status)
            }
            .padding(.leading, 12 + flareInset.leading).padding(.trailing, 12 + flareInset.trailing)
            .frame(height: height)
        case .floating:
            HStack(spacing: 8) {
                BrandMarkView(size: 16)
                statusLabel(status)
            }
            .padding(.horizontal, 12)
            .frame(height: IslandMetrics.floatingHeight)
        }
    }

    private func statusLabel(_ status: IslandStatus) -> some View {
        HStack(spacing: 6) {
            switch status {
            case .needsYou:
                Image(systemName: "hand.raised.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(UI.attention)
            case .working:
                StatusDot(active: true, size: 6).frame(width: 10, height: 10)
            case .idle:
                EmptyView()
            }
            Text(status.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusColor(status))
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Dashbar: \(status.label)")
    }

    private func statusColor(_ status: IslandStatus) -> Color {
        switch status {
        case .needsYou: return UI.textAttention
        case .working: return UI.textSuccess
        case .idle: return .white.opacity(0.6)
        }
    }

    // MARK: Expanded

    private func expanded<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        // On the notch it opens at least as wide as the collapsed pill, so it only ever grows out of it.
        let status = IslandStatus.of(sessions: store.sessions, permissionRequests: store.permissionRequests)
        let width = max(IslandMetrics.bannerWidth, styleNotchWidth.map { $0 + 2 * IslandMetrics.wing(for: status) + 16 } ?? 0)
        return VStack(spacing: 0) {
            if topInset > 0 { Color.clear.frame(height: topInset) }
            content()
                .padding(.leading, 16 + flareInset.leading).padding(.trailing, 16 + flareInset.trailing)
                .padding(.top, topInset > 0 ? 6 : 12).padding(.bottom, 14)
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var styleNotchWidth: CGFloat? {
        if case .notch(let w, _) = style { return w }
        return nil
    }

    @ViewBuilder private func bannerBody(_ banner: IslandBanner) -> some View {
        let session = store.sessions.first { $0.id == banner.sessionID }
        let request: PermissionRequest? = {
            if case .permission(let id) = banner.kind { return store.permissionRequests.first { $0.id == id } }
            return nil
        }()
        VStack(alignment: .leading, spacing: 10) {
            Button { if let session { onOpenSession(session) } } label: {
                HStack(alignment: .center, spacing: 11) {
                    Monogram(name: session?.project ?? request?.project ?? "?", root: session?.root,
                             active: false, waiting: false, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(heading(banner, session: session))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isAttention(banner) ? UI.textAttention : UI.textSuccess)
                        Text(verbatim: session?.name ?? request?.oneLine ?? "Claude Code")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                            .lineLimit(1).truncationMode(.tail)
                        Text(verbatim: subtitle(banner, session: session, request: request))
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if request == nil {
                        Text(isAttention(banner) ? "Open" : "Done")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isAttention(banner) ? UI.textAttention : UI.textSuccess)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .disabled(session == nil)
            .help(session.map { "Go to this session in \(HostApp.info(for: $0)?.name ?? "its app")" } ?? "")
            if let request {
                PermissionPrompt(request: request)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func isAttention(_ banner: IslandBanner) -> Bool {
        if case .finished = banner.kind { return false }
        return true
    }

    private func heading(_ banner: IslandBanner, session: LiveSession?) -> String {
        switch banner.kind {
        case .finished: return "Claude finished"
        case .waiting: return session?.waitingSentence ?? "Claude is waiting for you"
        case .permission: return "Claude needs permission"
        }
    }

    /// "docs-site · VS Code · after 12m"
    private func subtitle(_ banner: IslandBanner, session: LiveSession?, request: PermissionRequest?) -> String {
        var parts: [String] = []
        if let p = session?.project ?? request?.project, !p.isEmpty { parts.append(p) }
        if let s = session, let host = HostApp.info(for: s)?.name { parts.append(host) }
        if let a = session?.account { parts.append(a) }
        if case .finished(let after) = banner.kind, after > 0 { parts.append("after \(Fmt.duration(after))") }
        return parts.joined(separator: " · ")
    }

    // MARK: List

    @ViewBuilder private var listBody: some View {
        let shown = Self.listSessions(store.sessions)
        let prompts = store.unmatchedPermissionRequests
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                BrandMarkView(size: 16)
                Text(IslandStatus.of(sessions: store.sessions, permissionRequests: store.permissionRequests).label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(statusColor(IslandStatus.of(sessions: store.sessions, permissionRequests: store.permissionRequests)))
                Spacer()
                Button(action: onOpenDashbar) {
                    Text("Open Dashbar").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(PressStyle())
            }
            .padding(.bottom, 2)
            ForEach(prompts) { PermissionPrompt(request: $0, showsProject: true) }
            ForEach(shown) { s in
                VStack(alignment: .leading, spacing: 6) {
                    IslandRow(session: s) { onOpenSession(s) }
                    if let r = store.permissionRequest(for: s) { PermissionPrompt(request: r) }
                }
            }
            if shown.isEmpty && prompts.isEmpty {
                Text("No agents working").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    /// Waiting and working sessions, then the most recent idle ones, five at most.
    static func listSessions(_ sessions: [LiveSession]) -> [LiveSession] {
        let sorted = sessions.sorted { ($0.urgency, $1.since) < ($1.urgency, $0.since) }
        return Array(sorted.prefix(5))
    }
}

/// One live session in the island's list: its state, its title, its project, and a click goes back to it.
private struct IslandRow: View {
    let session: LiveSession
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                StatusDot(active: session.isBusy, waiting: session.isWaiting, size: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: session.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        .lineLimit(1).truncationMode(.tail)
                    Text(verbatim: [session.project, HostApp.info(for: session)?.name, session.account].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(session.isWaiting ? session.waitingLabel : session.isBusy ? "Working" : Fmt.ago(session.since))
                    .font(.system(size: 11, weight: session.isWaiting || session.isBusy ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(session.isWaiting ? UI.textAttention : session.isBusy ? UI.textSuccess : .white.opacity(0.55))
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(hover ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .padding(.horizontal, -8)
        .onHover { hover = $0 }
        .help("Go to this session")
    }
}

/// The island in its window: content pinned to the edge it grows from, animating between modes.
struct IslandRoot: View {
    @ObservedObject var model: IslandModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        IslandContent(mode: model.mode, style: model.placement.style,
                      onOpenSession: model.openSession, onOpenDashbar: model.openDashbar,
                      onExpand: model.expand)
            .id(model.placement.style == .floating ? "floating" : "attached")
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            .opacity(model.mode == .hidden ? 0 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.82), value: model.mode)
    }

    private var alignment: Alignment {
        if case .beside(let leading, _) = model.placement.style { return leading ? .topTrailing : .topLeading }
        return .top
    }
}
