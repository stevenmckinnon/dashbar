import SwiftUI
import AppKit

// MARK: - Plan limits strip: will I run out?

/// The Overview's answer to "will I run out of plan?": one row per account with limits, each showing its tightest limit
/// the way the full rows on the Usage tab draw it (same fill colours, same pace rule). A row carries the pace caption only
/// when its limit is on course to run out or used up; otherwise it is one line. No strip when no account has limits.
struct PlanStripCard: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var settings = AppSettings.shared
    /// Switches the panel to the Usage tab.
    let openUsage: () -> Void

    var body: some View {
        let rows = self.rows
        if !rows.isEmpty {
            Card(title: "Plan limits", icon: "gauge.with.needle", tint: .green, count: nil, accessory: AnyView(usageLink)) {
                // Shared column widths, so every row's limit name, meter and figures line up with the rows around it.
                // Measured from the text rather than laid out as a SwiftUI Grid, whose wrapping captions sized it wrongly.
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    let columns = PlanStripRow.Columns(rows, now: ctx.date)
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(rows) { PlanStripRow(row: $0, now: ctx.date, columns: columns) }
                    }
                }
            }
        }
    }

    private var usageLink: some View {
        Button(action: openUsage) {
            HStack(spacing: 2) {
                Text("Usage")
                Image(systemName: "chevron.right").font(.system(size: UI.Size.micro - 1, weight: .semibold))
            }
            .font(.system(size: UI.Size.caption, weight: .medium))
            .foregroundStyle(UI.textInfo)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help("Show every limit and your usage (⌘2)")
        .accessibilityLabel("Usage")
        .accessibilityHint("Shows every plan limit and your usage")
    }

    /// Every account with limits, in the Usage tab's order: Claude, its other accounts, Codex, Antigravity.
    private var rows: [PlanStripRow.Model] {
        var out: [PlanStripRow.Model] = []
        let claudeName = ["Claude", store.claudePlanLabel].compactMap { $0 }.joined(separator: " · ")
        if settings.showsClaudeLimits, let plan = store.claudePlan {
            if let problem = plan.problem {
                out.append(.init(id: "claude", name: claudeName, symbol: "asterisk", tint: UI.claude, fill: UI.claudeFill, limit: nil,
                                 note: plan.transient ? .waiting(problem, retryAt: store.claudePlanRetryAt) : .problem(problem)))
            } else if let limit = PlanStrip.tightest(plan.limits) {
                out.append(.init(id: "claude", name: claudeName, symbol: "asterisk", tint: UI.claude, fill: UI.claudeFill, limit: limit,
                                 note: plan.stale != nil ? .stale(plan.fetchedAt, retryAt: store.claudePlanRetryAt) : nil))
            }
        }
        for a in store.claudeAccountLimits where a.problem == nil {
            if let limit = PlanStrip.tightest(a.limits) {
                out.append(.init(id: "claude:" + a.path, name: "Claude · " + a.label, symbol: "asterisk", tint: UI.claude,
                                 fill: UI.claudeFill, limit: limit, note: nil))
            }
        }
        let codexSymbol = "chevron.left.forwardslash.chevron.right"
        if !store.codexAccountLimits.isEmpty {
            for a in store.codexAccountLimits {
                if let limit = PlanStrip.tightest(a.limits) {
                    out.append(.init(id: "codex:" + a.path, name: "Codex · " + a.label, symbol: codexSymbol, tint: UI.codex,
                                     fill: UI.codex, limit: limit, note: nil))
                }
            }
        } else if store.codex.found, let limit = PlanStrip.tightest(store.codexLimits) {
            out.append(.init(id: "codex", name: "Codex", symbol: codexSymbol, tint: UI.codex, fill: UI.codex, limit: limit, note: nil))
        }
        if let ag = store.antigravityLimits, ag.problem == nil, let limit = PlanStrip.tightest(ag.flattened) {
            out.append(.init(id: "antigravity", name: "Antigravity", symbol: UI.googleSymbol, tint: UI.google, fill: UI.google,
                             limit: limit, note: nil))
        }
        return out
    }
}

struct PlanStripRow: View {
    struct Model: Identifiable {
        enum Note {
            /// A wait that clears by itself (rate limited, offline), with when Dashbar tries again.
            case waiting(String, retryAt: Date?)
            /// Something the user has to fix (a sign-in), shown as the full card shows it.
            case problem(String)
            /// Limits kept from an earlier reading through a wait.
            case stale(Date, retryAt: Date?)
        }
        let id: String
        let name: String
        let symbol: String
        let tint: Color
        let fill: Color
        let limit: RateLimit?
        let note: Note?
    }


    /// Widths every row shares: the agent's name, the limit's name, the figure and the reset, each as wide as the widest,
    /// worked out so a row is never wider than the card. Each row's limit name as shown is in `labels`.
    struct Columns {
        var name: CGFloat = 0
        var label: CGFloat = 0
        var figure: CGFloat = 0
        var reset: CGFloat = 0
        /// The meters sit on their own line, under each row's agent name, with the limit's name before them.
        var stacked = false
        /// Each row's limit name as shown, by row id: its own, or its window's ("Weekly") when its own doesn't fit.
        var labels: [String: String] = [:]

        init(_ rows: [Model], now: Date, contentWidth: CGFloat = Self.contentWidth) {
            func width(_ s: String, _ font: NSFont) -> CGFloat {
                ceil((s as NSString).size(withAttributes: [.font: font]).width) + 1
            }
            let body = NSFont.systemFont(ofSize: UI.Size.body, weight: .medium)
            let caption = NSFont.systemFont(ofSize: UI.Size.caption)
            let figure = NSFont.monospacedDigitSystemFont(ofSize: UI.Size.caption, weight: .semibold)
            let digits = NSFont.monospacedDigitSystemFont(ofSize: UI.Size.caption, weight: .regular)
            let limited = rows.compactMap { r in r.limit.map { (id: r.id, limit: $0) } }
            for r in rows { name = max(name, width(r.name, body)) }
            for (_, l) in limited {
                self.figure = max(self.figure, width(Fmt.usedPercent(l.usedPercent), figure))
                if let at = l.resetsAt { reset = max(reset, width(Fmt.resets(at, now: now), digits)) }
            }
            let gap = PlanStripRow.spacing
            let lead = PlanStripRow.glyph + 6
            let figures = gap + self.figure + (reset > 0 ? gap + reset : 0)
            /// Each row's own limit name where it fits in `room`, else its short one; the column as wide as the widest.
            func fit(_ room: CGFloat) -> ([String: String], CGFloat) {
                var shown: [String: String] = [:], widest: CGFloat = 0
                for (id, l) in limited {
                    let text = width(l.label, caption) <= room ? l.label : PlanStrip.shortLabel(l)
                    shown[id] = text
                    widest = max(widest, width(text, caption))
                }
                return (shown, min(widest, room))
            }

            // One line: name, limit, meter, figure, reset. A long limit name ("Gemini Argon · Weekly") gives way to its
            // window's name ("Weekly") before the meter does.
            (labels, label) = fit(Self.labelLimit)
            let meter = contentWidth - (lead + name + gap + label + gap + figures)
            guard meter < Self.minimumMeter else { return }

            // Too little room for a meter worth reading (a second account's name, a long limit name): every row takes two
            // lines. The agent's name with the figures at the trailing edge, then under the name the limit's name and the
            // meter. The name truncates at its end before the figures are squeezed; the limit's name may use the room
            // the meter leaves.
            stacked = true
            name = min(name, max(0, contentWidth - lead - figures))
            (labels, label) = fit(max(0, contentWidth - lead - gap - Self.minimumMeter))
        }

        /// The card's inner width in the panel.
        static let contentWidth = UI.panelWidth - 2 * UI.gutter - 2 * UI.cardPadding
        static let minimumMeter: CGFloat = 64
        /// The widest a limit's name may be while a row is one line.
        static let labelLimit: CGFloat = 110

        /// Where the limit's name starts: past the glyph, then on a one-line row past the agent's name too.
        var captionInset: CGFloat { PlanStripRow.glyph + 6 + (stacked ? 0 : name + PlanStripRow.spacing) }

        /// How wide a row's widest line is, for checking it fits the card.
        var lineWidth: CGFloat {
            let lead = PlanStripRow.glyph + 6, gap = PlanStripRow.spacing
            let figures = gap + figure + (reset > 0 ? gap + reset : 0)
            return stacked ? max(lead + name + figures, lead + label + gap + Self.minimumMeter)
                           : lead + name + gap + label + gap + Self.minimumMeter + figures
        }
    }

    let row: Model
    let now: Date
    let columns: Columns
    static let glyph: CGFloat = 14
    static let spacing: CGFloat = 8

    /// The limit on one line (name, limit, meter, figure, reset), or on two when the card is too narrow for that (see
    /// `Columns`), then a caption under the limit's name only when it is running out, used up or kept through a wait. VoiceOver hears the line and its caption as one sentence.
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let limit = row.limit {
                let pace = limit.pace(now: now)
                let label = columns.labels[row.id] ?? limit.label
                VStack(alignment: .leading, spacing: 3) {
                    if columns.stacked {
                        HStack(spacing: Self.spacing) {
                            name
                            Spacer(minLength: 0)
                            figures(limit)
                        }
                        HStack(spacing: Self.spacing) {
                            limitName(label)
                            meter(limit, pace: pace).frame(maxWidth: .infinity)
                        }
                        .padding(.leading, columns.captionInset)
                    } else {
                        HStack(spacing: Self.spacing) {
                            name
                            limitName(label)
                            meter(limit, pace: pace).frame(maxWidth: .infinity)
                            figures(limit)
                        }
                    }
                    if let pace, PlanStrip.showsCaption(pace) {
                        Text(LimitBar.text(pace)).font(.system(size: UI.Size.caption)).foregroundStyle(LimitBar.color(pace))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, columns.captionInset)
                    }
                }
                .help([label == limit.label ? nil : limit.label, LimitBar.sourceNote(limit)].compactMap { $0 }.joined(separator: "\n"))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(PlanStrip.spoken(provider: row.name, limit: limit, now: now))
                if let note = row.note { noteView(note).padding(.leading, columns.captionInset) }
            } else if let note = row.note {
                // No limits to show (a wait, or something to fix): the message beside the name, as wide as the row.
                HStack(alignment: .firstTextBaseline, spacing: Self.spacing) {
                    name
                    noteView(note).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var name: some View {
        HStack(spacing: 6) {
            Image(systemName: row.symbol).font(.system(size: UI.Size.caption, weight: .bold)).foregroundStyle(row.tint)
                .frame(width: Self.glyph).accessibilityHidden(true)
            Text(row.name).font(.system(size: UI.Size.body, weight: .medium)).lineLimit(1).truncationMode(.tail)
                .frame(width: columns.name, alignment: .leading)
        }
    }

    private func limitName(_ text: String) -> some View {
        Text(text).font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
            .lineLimit(1).truncationMode(.tail)
            .frame(width: columns.label, alignment: .leading)
    }

    /// "11% used" and "resets in 3h 47m", each in its shared column.
    @ViewBuilder private func figures(_ limit: RateLimit) -> some View {
        Text(Fmt.usedPercent(limit.usedPercent))
            .font(.system(size: UI.Size.caption, weight: .semibold).monospacedDigit())
            .foregroundStyle(min(max(limit.usedPercent, 0), 100) >= 90 ? UI.textDanger : Color.primary)
            .lineLimit(1)
            .frame(width: columns.figure, alignment: .trailing)
        if columns.reset > 0 {
            Text(limit.resetsAt.map { Fmt.resets($0, now: now) } ?? "")
                .font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary)
                .lineLimit(1)
                .frame(width: columns.reset, alignment: .leading)
        }
    }


    private func meter(_ limit: RateLimit, pace: RateLimit.Pace?) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(UI.track)
                // Drawn from the figure as shown, as the full rows are: "0% used" draws nothing.
                Capsule().fill(LimitBar.fill(used: min(max(limit.usedPercent, 0), 100), pace: pace, tint: row.fill))
                    .frame(width: Meter.width(LimitBar.shownFraction(limit.usedPercent), in: g.size.width, minimum: 3))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func noteView(_ note: Model.Note) -> some View {
        switch note {
        case .waiting(let message, let retryAt):
            // As the Usage tab shows a temporary wait: a quiet clock, the message and a live countdown.
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "clock").foregroundStyle(UI.textSecondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    if let retryAt {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(retryAt > ctx.date ? "Trying again in \(PlanLimitsText.countdown(retryAt.timeIntervalSince(ctx.date)))"
                                                    : "Trying again…")
                                .monospacedDigit().foregroundStyle(UI.textSecondary)
                        }
                    }
                }
            }
            .font(.system(size: UI.Size.caption))
            .accessibilityElement(children: .combine)
        case .problem(let message):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(UI.textDanger).accessibilityHidden(true)
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: UI.Size.caption))
            .accessibilityElement(children: .combine)
        case .stale(let fetched, let retryAt):
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                HStack(spacing: 5) {
                    Image(systemName: "clock").accessibilityHidden(true)
                    Text(PlanLimitsText.staleLine(fetched: fetched, retryAt: retryAt, now: ctx.date)).monospacedDigit().lineLimit(1)
                }
            }
            .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Clean-up line

/// "7 GB of rebuildable caches ›": the one clean-up figure Overview keeps, as a quiet line that opens the Clean-up tab.
struct CleanupLine: View {
    let total: UInt64
    let open: () -> Void
    @State private var hover = false

    static func text(_ total: UInt64) -> String { "\(Fmt.diskBytes(total)) of rebuildable caches" }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox").font(.system(size: UI.Size.caption)).frame(width: 16, alignment: .leading)
                    .accessibilityHidden(true)
                Text(Self.text(total)).font(.system(size: UI.Size.caption).monospacedDigit())
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.system(size: UI.Size.micro, weight: .semibold)).accessibilityHidden(true)
            }
            .foregroundStyle(hover ? AnyShapeStyle(.primary) : AnyShapeStyle(UI.textSecondary))
            .padding(.horizontal, UI.cardPadding).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .help("Show the folders on the Clean-up tab (⌘5)")
        .accessibilityLabel(Self.text(total))
        .accessibilityHint("Shows the Clean-up tab")
    }
}
