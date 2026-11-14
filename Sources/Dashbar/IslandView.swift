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

    static let markSize: CGFloat = 15
    /// Padding inside an ear: next to the notch, and at its outer end.
    static let earInner: CGFloat = 7
    static let earOuter: CGFloat = 10
    static let glyph: CGFloat = 9

    static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: statusFont]).width)
    }

    /// What each form of the ears needs for this status, flare included.
    static func earWidths(for status: IslandStatus) -> IslandEars.Widths {
        let base = flare + earInner + glyph + earOuter
        return IslandEars.Widths(mark: flare + earOuter + markSize + earInner,
                                 full: base + 5 + textWidth(status.label),
                                 count: base + 4 + textWidth(status.countText),
                                 dot: base)
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
    /// On the notch, which ears the collapsed island shows and how wide each is.
    var ears: IslandEars? = nil
    /// The shape's size while animating (set by the window); nil sizes it to its content.
    var size: CGSize? = nil

    /// One black shape whose size springs between modes, with the content cross-fading inside it.
    var body: some View {
        let s = shape(expanded: isExpanded)
        ZStack(alignment: contentAlignment) {
            switch mode {
            case .hidden:
                Color.clear.frame(width: 1, height: 1)
            case .collapsed(let status):
                collapsed(status).transition(fade)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onExpand)
            case .banner(let banner):
                expanded { bannerBody(banner) }.transition(fade)
            case .list:
                expanded { listBody }.transition(fade)
            }
        }
        .fixedSize()
        .frame(width: size?.width, height: size?.height, alignment: contentAlignment)
        .background(s.fill(.black))
        .overlay { if case .floating = style { s.stroke(Color.white.opacity(0.14), lineWidth: 0.5) } }
        .clipShape(s)
        .contentShape(s)
        .environment(\.colorScheme, .dark)
    }

    /// Content arrives once the shape has started growing, sliding down a touch; it leaves quickly.
    private var fade: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(y: -6)).animation(.easeOut(duration: 0.22).delay(0.1)),
                           removal: .opacity.animation(.easeOut(duration: 0.1)))
    }

    /// Content stays pinned to the top, and beside the notch to the notch's edge, while the shape grows around it.
    private var contentAlignment: Alignment {
        if case .beside(let leading, _) = style { return leading ? .topTrailing : .topLeading }
        return .top
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
            // The notch plus two small ears, each only as wide as the menu bar beside it allows.
            let ears = ears ?? IslandEars.fit(leftGap: .infinity, rightGap: .infinity,
                                              widths: IslandMetrics.earWidths(for: status), allowFull: false)
            HStack(spacing: 0) {
                Group {
                    if ears.showsMark {
                        BrandMarkView(size: IslandMetrics.markSize)
                            .padding(.leading, IslandMetrics.flare + IslandMetrics.earOuter)
                            .padding(.trailing, IslandMetrics.earInner)
                    }
                }
                .frame(width: ears.leftWidth, alignment: .leading)
                Color.clear.frame(width: width)
                Group {
                    if ears.right != .none {
                        statusLabel(status, form: ears.right)
                            .padding(.leading, IslandMetrics.earInner)
                            .padding(.trailing, IslandMetrics.flare + IslandMetrics.earOuter)
                    }
                }
                .frame(width: ears.rightWidth, alignment: .leading)
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

    private func statusLabel(_ status: IslandStatus, form: IslandEars.Right = .full) -> some View {
        HStack(spacing: form == .full ? 5 : 4) {
            switch status {
            case .needsYou:
                Image(systemName: "hand.raised.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(UI.attention)
                    .frame(width: IslandMetrics.glyph)
            case .working:
                Circle().fill(Color.green).frame(width: 6, height: 6).frame(width: IslandMetrics.glyph)
            case .idle:
                EmptyView()
            }
            if form == .full || form == .count {
                Text(form == .full ? status.label : status.countText)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(statusColor(status))
                    .fixedSize()
            }
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
        let width = max(IslandMetrics.bannerWidth, styleNotchWidth.map { $0 + 150 } ?? 0)
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
                        Text(verbatim: session?.title ?? request?.oneLine ?? "Claude Code")
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
                    Text(verbatim: session.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        .lineLimit(1).truncationMode(.tail)
                    Text(verbatim: (session.identityParts + [HostApp.info(for: session)?.name, session.account].compactMap { $0 }).joined(separator: " · "))
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

/// The island in its window. The panel is a fixed canvas while the island animates: the shape's top stays pinned to
/// the canvas top (the screen edge), and its size and centre spring, so it grows down and out of the notch and folds
/// back into it. The panel only changes size before growing and after shrinking, never during.
struct IslandRoot: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        IslandContent(mode: model.mode, style: model.placement.style,
                      onOpenSession: model.openSession, onOpenDashbar: model.openDashbar,
                      onExpand: model.expand, ears: model.ears, size: model.size)
            .opacity(model.visible ? 1 : 0)
            .offset(x: model.anchorInPanel + model.offsetX - model.size.width / 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
