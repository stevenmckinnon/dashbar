import SwiftUI
import Charts

/// The window's History page: how the plan has been used over time, and where the tokens went.
/// Everything comes from what Dashbar already keeps: the plan history it records and the usage scan's day ledger.
struct HistoryPage: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        if let warning = store.formatWarning { NoticeBanner(text: warning, dismiss: nil) }
        HistoryHeading(text: "Plan limits")
        if settings.showsClaudeLimits || store.planHistory.windows().contains(where: { $0.series.provider == .claude }) {
            PlanHistoryCard(provider: .claude, label: store.defaultAccountLabel(.claude),
                            current: store.claudePlan?.problem == nil ? store.claudePlan?.limits ?? [] : [])
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text("Claude doesn't save plan limits on your Mac. Once Dashbar reads them from Claude Code's status line, it keeps their history here.")
                    .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                SettingsButton(tab: .claudeLimits) { Text("Settings…") }
                    .buttonStyle(.link).font(.system(size: UI.Size.caption, weight: .medium))
            }
            .padding(UI.cardPadding).surface()
        }
        // With more than one account, each has its own card after the default one, in the order of Settings → Accounts.
        ForEach(store.historyAccounts(.claude)) { a in
            PlanHistoryCard(provider: .claude, account: a.key, label: a.label, current: a.limits)
        }
        if store.codex.found || !store.codexLimits.isEmpty {
            PlanHistoryCard(provider: .codex, label: store.defaultAccountLabel(.codex), current: store.codexLimits)
        }
        ForEach(store.historyAccounts(.codex)) { a in
            PlanHistoryCard(provider: .codex, account: a.key, label: a.label, current: a.limits)
        }
        // Antigravity: a card per model group ("Antigravity · Gemini"), only once its CLI's status line has reported.
        ForEach(store.historyAccounts(.antigravity)) { a in
            PlanHistoryCard(provider: .antigravity, account: a.key, label: a.label, current: a.limits)
        }
        HistoryHeading(text: "Usage, last 30 days").padding(.top, 10)
        UsageHistorySection(claude: store.claude.history, codex: store.codex.found ? store.codex.history : nil,
                            google: store.google.found ? store.google.history : nil, googleName: GoogleUsage.title(store.googleSources),
                            loading: store.usageLoading)
    }
}

private struct HistoryHeading: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: UI.Size.emphasis, weight: .semibold)).padding(.horizontal, 4)
    }
}

extension PlanHistory.Provider {
    var title: String {
        switch self { case .claude: return "Claude"; case .codex: return "Codex"; case .antigravity: return "Antigravity" }
    }
    var icon: String {
        switch self { case .claude: return "asterisk"; case .codex: return "chevron.left.forwardslash.chevron.right"; case .antigravity: return UI.googleSymbol }
    }
    var tint: Color {
        switch self { case .claude: return UI.claude; case .codex: return UI.codex; case .antigravity: return UI.google }
    }
    /// Under a window with no reading yet: when one arrives.
    var noReadingYet: String {
        switch self {
        case .claude: return "No reading for this window yet. One arrives with your next Claude Code reply."
        case .codex: return "No reading for this window yet. One arrives with your next Codex session."
        case .antigravity: return "No reading for this window yet. One arrives with your next Antigravity CLI session."
        }
    }
}

// MARK: - Plan limits

/// One provider's 5-hour and weekly windows: the current one against an even pace, and how full past ones got.
private struct PlanHistoryCard: View {
    @EnvironmentObject var store: Store
    let provider: PlanHistory.Provider
    /// The account's key (nil: the default) and, with more than one account, its name.
    var account: String? = nil
    var label: String? = nil
    let current: [RateLimit]

    var body: some View {
        let windows = store.planHistory.windows()
        Card(title: provider.title + (label.map { " · " + $0 } ?? ""), icon: provider.icon, tint: provider.tint, count: nil, trailing: "Kept for 90 days") {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) { columns(windows) }
                VStack(alignment: .leading, spacing: 18) { columns(windows) }
            }
        }
    }

    @ViewBuilder private func columns(_ windows: [PlanHistory.Window]) -> some View {
        ForEach(PlanHistory.Kind.allCases, id: \.self) { kind in
            let series = PlanHistory.Series(provider, kind, account: account)
            WindowHistory(series: series,
                          limit: current.first { PlanHistory.kind(of: $0) == kind },
                          samples: store.planHistory.current(series),
                          past: windows.filter { $0.series == series && $0.end <= Date() },
                          summary: store.planHistory.summary(series))
                .frame(minWidth: 320, maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct WindowHistory: View {
    let series: PlanHistory.Series
    let limit: RateLimit?
    let samples: [PlanHistory.Sample]
    let past: [PlanHistory.Window]
    let summary: PlanHistory.Summary

    private var tint: Color { series.provider.tint }
    private var name: String { RateLimit.name(window: series.kind.length) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.system(size: UI.Size.body, weight: .semibold))
                Spacer()
                if let limit {
                    let used = min(max(limit.usedPercent, 0), 100)
                    Text(Fmt.usedPercent(limit.usedPercent)).font(.system(size: UI.Size.caption, weight: .semibold).monospacedDigit())
                        .foregroundStyle(used >= PlanHistory.limitHit ? UI.textDanger : Color.primary)
                    if let r = limit.resetsAt {
                        Text("· " + Fmt.resets(r))
                            .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                    }
                }
            }
            burnDown
            pastWindows
        }
    }

    // MARK: Current window

    private var span: (start: Date, end: Date)? {
        guard let reset = limit?.resetsAt ?? samples.last?.resetsAt else { return nil }
        return (reset.addingTimeInterval(-series.kind.length), reset)
    }

    /// The window so far against the even pace (0% at the start, 100% at the reset), with where this rate leads.
    @ViewBuilder private var burnDown: some View {
        if let span, limit != nil || !samples.isEmpty {
            let points = burnPoints(span)
            let pace = limit?.pace()
            Chart {
                LineMark(x: .value("Time", span.start), y: .value("Used", 0), series: .value("Line", "pace"))
                    .foregroundStyle(Color.primary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                LineMark(x: .value("Time", span.end), y: .value("Used", 100), series: .value("Line", "pace"))
                    .foregroundStyle(Color.primary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                ForEach(points, id: \.0) { p in
                    LineMark(x: .value("Time", p.0), y: .value("Used", p.1), series: .value("Line", "used"))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.stepEnd)
                }
                if let last = points.last {
                    PointMark(x: .value("Time", last.0), y: .value("Used", last.1))
                        .foregroundStyle(last.1 >= PlanHistory.limitHit ? UI.textDanger : tint)
                        .symbolSize(28)
                    if case .runsOut(let when)? = pace {
                        // Where the current rate leads: a heads-up, so amber.
                        LineMark(x: .value("Time", last.0), y: .value("Used", last.1), series: .value("Line", "forecast"))
                            .foregroundStyle(UI.attention)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                        LineMark(x: .value("Time", min(when, span.end)), y: .value("Used", 100), series: .value("Line", "forecast"))
                            .foregroundStyle(UI.attention)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                    }
                }
            }
            .chartXScale(domain: span.start...span.end)
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, 50, 100]) { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel { if let n = v.as(Int.self) { Text("\(n)%").font(.system(size: UI.Size.micro)) } }
                }
            }
            .chartXAxis {
                if series.kind == .fiveHour {
                    AxisMarks(values: Self.ticks(from: span.start, to: span.end, every: 3600)) { _ in
                        AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .abbreviated))).font(.system(size: UI.Size.micro))
                    }
                } else {
                    AxisMarks(values: Self.ticks(from: span.start, to: span.end, every: 86400)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated)).font(.system(size: UI.Size.micro))
                    }
                }
            }
            .frame(height: 110)
            .accessibilityLabel("\(name) so far")
            .accessibilityValue(limit.map { "\(Int($0.usedPercent.rounded())) percent used" } ?? "")
            HStack(spacing: 10) {
                if let pace {
                    Text(LimitBar.text(pace)).font(.system(size: UI.Size.caption)).foregroundStyle(LimitBar.color(pace))
                } else if let expected = limit?.expectedPercent() {
                    Text("An even pace would be at \(Int(expected.rounded()))% by now")
                        .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                }
                Spacer(minLength: 4)
                Legend(items: [("Used", tint, false), ("Even pace", Color.primary.opacity(0.45), true)])
            }
        } else {
            Text(series.provider.noReadingYet)
                .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        }
    }

    /// The recorded readings, starting from 0% at the window's start, ending with the live reading.
    private func burnPoints(_ span: (start: Date, end: Date)) -> [(Date, Double)] {
        var points: [(Date, Double)] = [(span.start, 0)]
        for s in samples where s.at > span.start && s.at <= span.end { points.append((s.at, s.used)) }
        if let limit, let last = points.last {
            let now = min(Date(), span.end)
            if now > last.0 { points.append((now, min(max(limit.usedPercent, 0), 100))) }
        }
        return points
    }

    /// Whole hours (or midnights) inside the span, leaving room at the right edge so no label is cut short.
    static func ticks(from start: Date, to end: Date, every step: TimeInterval) -> [Date] {
        let cal = Calendar.current
        var t = step >= 86400 ? cal.startOfDay(for: start) : (cal.dateInterval(of: .hour, for: start)?.start ?? start)
        var out: [Date] = []
        let last = end.addingTimeInterval(-step * 0.4)
        while t <= last {
            if t > start.addingTimeInterval(step * 0.2) { out.append(t) }
            t = step >= 86400 ? (cal.date(byAdding: .day, value: Int(step / 86400), to: t) ?? t.addingTimeInterval(step)) : t.addingTimeInterval(step)
        }
        return out
    }

    // MARK: Past windows

    @ViewBuilder private var pastWindows: some View {
        let recent = past.filter { $0.end >= Date().addingTimeInterval(-30 * 86400) }
        VStack(alignment: .leading, spacing: 6) {
            Text("Peak of each window, last 30 days")
                .font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(UI.textSecondary)
            if recent.isEmpty {
                Text("Past windows appear here as they reset. Dashbar started keeping them when you turned on plan limits.")
                    .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let width: CGFloat = series.kind == .fiveHour ? 3 : 14
                Chart(recent) { w in
                    BarMark(x: .value("Ended", w.end), yStart: .value("Base", 0), yEnd: .value("Peak", max(w.peak, 1.5)), width: .fixed(width))
                        .foregroundStyle(color(w))
                        .cornerRadius(1.5)
                }
                .chartXScale(domain: Date().addingTimeInterval(-30 * 86400)...Date())
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: [0, 50, 100]) { v in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel { if let n = v.as(Int.self) { Text("\(n)%").font(.system(size: UI.Size.micro)) } }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: Self.ticks(from: Date().addingTimeInterval(-30 * 86400), to: Date(), every: 7 * 86400)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.system(size: UI.Size.micro))
                    }
                }
                .frame(height: 70)
                .accessibilityLabel("Peaks of past \(name)s")
                .accessibilityValue(summaryText)
                summaryLine
            }
        }
        .padding(.top, 6)
    }

    /// Used up is a problem (red); close to it is worth knowing (amber); the rest is just the provider's colour.
    private func color(_ w: PlanHistory.Window) -> Color {
        w.hitLimit ? UI.textDanger : w.nearLimit ? UI.attention : tint.opacity(0.55)
    }

    private var summaryText: String {
        let s = summary
        let windows = s.count == 1 ? "1 window" : "\(s.count) windows"
        var parts = [windows]
        parts.append(s.hits == 0 ? "never hit the limit" : "hit the limit in \(s.hits)")
        if s.near > 0 { parts.append("came within 10% in \(s.near)") }
        parts.append("typical peak \(Int(s.medianPeak.rounded()))%")
        return parts.joined(separator: " · ")
    }

    private var summaryLine: some View {
        let s = summary
        return HStack(spacing: 0) {
            Text(s.count == 1 ? "1 window · " : "\(s.count) windows · ")
            if s.hits == 0 {
                Text("never hit the limit")
            } else {
                Text("hit the limit in \(s.hits)").foregroundStyle(UI.textDanger)
            }
            if s.near > 0 {
                Text(" · ")
                Text("came within 10% in \(s.near)").foregroundStyle(UI.textAttention)
            }
            Text(" · typical peak \(Int(s.medianPeak.rounded()))%")
        }
        .font(.system(size: UI.Size.caption).monospacedDigit())
        .foregroundStyle(UI.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .accessibilityElement(children: .combine)
    }
}

private struct Legend: View {
    let items: [(String, Color, Bool)]
    var body: some View {
        HStack(spacing: 10) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: 4) {
                    if item.2 {
                        Capsule().stroke(item.1, style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 12, height: 1)
                    } else {
                        Capsule().fill(item.1).frame(width: 12, height: 2)
                    }
                    Text(item.0)
                }
            }
        }
        .font(.system(size: UI.Size.micro)).foregroundStyle(UI.textSecondary)
        .accessibilityHidden(true)
    }
}

// MARK: - Usage

/// Tokens and estimated cost per day over the last 30 days, split by agent, with where they went.
private struct UsageHistorySection: View {
    let claude: UsageHistory
    let codex: UsageHistory?
    var google: UsageHistory? = nil
    var googleName = "Gemini CLI"
    let loading: Bool
    @State private var selected: Date?

    private struct Bar: Identifiable {
        var id: String { key + agent }
        let key: String
        let date: Date
        let agent: String
        let tokens: Int
        let cost: Double
    }

    private var bars: [Bar] {
        var out = claude.days.map { Bar(key: $0.key, date: $0.date, agent: "Claude Code", tokens: $0.tokens, cost: $0.cost) }
        if let codex { out += codex.days.map { Bar(key: $0.key, date: $0.date, agent: "Codex", tokens: $0.tokens, cost: $0.cost) } }
        if let google { out += google.days.map { Bar(key: $0.key, date: $0.date, agent: googleName, tokens: $0.tokens, cost: $0.cost) } }
        return out
    }

    /// The agents shown, with their colours, in order.
    private var agents: [(String, Color)] {
        [("Claude Code", UI.claude)] + (codex == nil ? [] : [("Codex", UI.codex)]) + (google == nil ? [] : [(googleName, UI.google)])
    }

    var body: some View {
        if loading {
            HStack { ProgressView().controlSize(.small); Text("Scanning transcripts…").font(.caption).foregroundStyle(UI.textSecondary) }
                .padding(UI.cardPadding).frame(maxWidth: .infinity, alignment: .leading).surface()
        } else if claude.totals.total == 0 && (codex?.totals.total ?? 0) == 0 && (google?.totals.total ?? 0) == 0 {
            EmptyRow(text: "No Claude Code or Codex usage in the last 30 days.").padding(UI.cardPadding).surface()
        } else {
            let bars = bars
            Card(title: "Per day", icon: "chart.bar.xaxis", count: nil, trailing: nil) {
                VStack(alignment: .leading, spacing: 14) {
                    figures(bars)
                    chart(bars, title: "Tokens", value: { Double($0.tokens) }, label: { Fmt.tokens(Int($0)) })
                    chart(bars, title: "Estimated cost at API prices", value: \.cost, label: { Fmt.usd($0) })
                    HStack(spacing: 10) {
                        Legend(items: agents.map { ($0.0, $0.1, false) })
                        Spacer()
                        Text("Hover a day for its figures").font(.system(size: UI.Size.micro)).foregroundStyle(UI.textSecondary)
                    }
                }
            }
            HStack(alignment: .top, spacing: UI.gap) {
                Card(title: "Projects", icon: "folder", count: nil, trailing: "tokens · est. cost") {
                    ProjectRanks(claude: claude, codex: codex, google: google)
                }
                    .frame(maxHeight: .infinity, alignment: .top)
                Card(title: "Models", icon: "cpu", count: nil, trailing: "tokens · est. cost") { ModelRanks(claude: claude, codex: codex, google: google) }
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .fixedSize(horizontal: false, vertical: true)
            Text("Costs are estimates of what these tokens would cost on the pay-as-you-go API, at list prices from \(Pricing.asOf). "
                 + "On a Claude, ChatGPT or Google AI plan you pay the plan's price, not this."
                 + (google == nil ? "" : " Antigravity CLI costs are its own estimates.")
                 + (unpriced.isEmpty ? "" : " No price is known for \(unpriced.joined(separator: ", ")), so its tokens are left out of the cost.")
                 + " Dashbar reads the last 30 days of logs and keeps totals by day, project and model, not by session.")
                .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    /// Hovering a day picks it. Offline snapshots have no pointer, so they keep the whole period.
    private var hover: Binding<Date?> {
        Binding(get: { selected }, set: { if Snapshot.store == nil { selected = $0 } })
    }

    private var unpriced: [String] { Array(Set(claude.unpriced + (codex?.unpriced ?? []) + (google?.unpriced ?? []))).sorted() }

    /// The period's totals, or the hovered day's.
    private func figures(_ bars: [Bar]) -> some View {
        let day = selected.map { Calendar.current.startOfDay(for: $0) }
        let shown = day.map { d in bars.filter { Calendar.current.isDate($0.date, inSameDayAs: d) } } ?? bars
        let tokens = shown.reduce(0) { $0 + $1.tokens }
        let cost = shown.reduce(0) { $0 + $1.cost }
        let totalsByDay = Dictionary(grouping: bars, by: \.key).mapValues { $0.reduce(0) { $0 + $1.tokens } }
        let busiest = totalsByDay.max { $0.value < $1.value }
        let busiestDate = busiest.flatMap { b in bars.first { $0.key == b.key }?.date }
        let active = totalsByDay.values.filter { $0 > 0 }.count
        let claudeShare = Double(claude.totals.total)
            / Double(max(1, claude.totals.total + (codex?.totals.total ?? 0) + (google?.totals.total ?? 0)))
        return HStack(alignment: .top, spacing: 22) {
            figure(day.map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) } ?? "Tokens, 30 days", Fmt.tokens(tokens))
            figure("Estimated cost", "\u{2248} " + Fmt.usd(cost))
            if day == nil {
                figure("Busiest day", busiest.map { b in
                    (busiestDate?.formatted(.dateTime.day().month(.abbreviated)) ?? "") + " · " + Fmt.tokens(b.value)
                } ?? "–")
                figure("Days with use", "\(active) of \(UsageHistory.days)")
                if codex != nil || google != nil { figure("Claude Code share", "\(Int((claudeShare * 100).rounded()))%") }
            } else {
                ForEach(shown) { b in figure(b.agent, Fmt.tokens(b.tokens) + " · " + Fmt.usd(b.cost)) }
            }
            Spacer(minLength: 0)
        }
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
            Text(value).font(.system(size: UI.Size.title, weight: .semibold).monospacedDigit()).lineLimit(1)
        }
    }

    private func chart(_ bars: [Bar], title: String, value: @escaping (Bar) -> Double, label: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(UI.textSecondary)
            Chart(bars) { b in
                BarMark(x: .value("Day", b.date, unit: .day), y: .value(title, value(b)))
                    .foregroundStyle(by: .value("Agent", b.agent))
                    .opacity(selected.map { Calendar.current.isDate($0, inSameDayAs: b.date) ? 1 : 0.45 } ?? 1)
                    .cornerRadius(1.5)
            }
            .chartForegroundStyleScale(domain: agents.map(\.0), range: agents.map(\.1))
            .chartLegend(.hidden)
            .chartXSelection(value: hover)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel { if let n = v.as(Double.self) { Text(label(n)).font(.system(size: UI.Size.micro)) } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.system(size: UI.Size.micro))
                }
            }
            .frame(height: 120)
        }
    }
}

/// Top projects over the period, both agents together; each bar splits into Claude Code's and Codex's share.
private struct ProjectRanks: View {
    let claude: UsageHistory
    let codex: UsageHistory?
    var google: UsageHistory? = nil

    private struct Row: Identifiable {
        var id: String { name }
        let name: String
        var claude = 0
        var codex = 0
        var google = 0
        var cost: Double?
        var total: Int { claude + codex + google }
    }

    private var rows: [Row] {
        var byName: [String: Row] = [:]
        for p in claude.projects {
            var r = byName[p.name] ?? Row(name: p.name)
            r.claude += p.value
            if let c = p.cost { r.cost = (r.cost ?? 0) + c }
            byName[p.name] = r
        }
        for p in codex?.projects ?? [] {
            var r = byName[p.name] ?? Row(name: p.name)
            r.codex += p.value
            if let c = p.cost { r.cost = (r.cost ?? 0) + c }
            byName[p.name] = r
        }
        for p in google?.projects ?? [] {
            var r = byName[p.name] ?? Row(name: p.name)
            r.google += p.value
            if let c = p.cost { r.cost = (r.cost ?? 0) + c }
            byName[p.name] = r
        }
        return byName.values.sorted { ($0.total, $1.name) > ($1.total, $0.name) }.prefix(6).map { $0 }
    }

    var body: some View {
        let rows = rows
        let top = Double(rows.first?.total ?? 1)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { r in
                RankRow(name: r.name, value: Fmt.tokens(r.total) + (r.cost.map { " · " + Fmt.usd($0) } ?? "")) { width in
                    HStack(spacing: 0) {
                        if r.claude > 0 { Rectangle().fill(UI.claude.opacity(0.7)).frame(width: width * Double(r.claude) / top) }
                        if r.codex > 0 { Rectangle().fill(UI.codex.opacity(0.7)).frame(width: width * Double(r.codex) / top) }
                        if r.google > 0 { Rectangle().fill(UI.google.opacity(0.7)).frame(width: width * Double(r.google) / top) }
                    }
                    .frame(width: max(3, width * Double(r.total) / max(top, 1)), alignment: .leading)
                    .clipShape(Capsule())
                }
            }
        }
    }
}

private struct ModelRanks: View {
    let claude: UsageHistory
    let codex: UsageHistory?
    var google: UsageHistory? = nil

    var body: some View {
        let rows = (claude.models.map { ($0, UI.claude) } + (codex?.models ?? []).map { ($0, UI.codex) }
                    + (google?.models ?? []).map { ($0, UI.google) })
            .sorted { $0.0.value > $1.0.value }.prefix(6)
        let top = Double(rows.first?.0.value ?? 1)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows), id: \.0.id) { m, tint in
                RankRow(name: m.name, value: Fmt.tokens(m.value) + (m.cost.map { " · " + Fmt.usd($0) } ?? " · no price")) { width in
                    Capsule().fill(tint.opacity(0.7)).frame(width: max(3, width * Double(m.value) / max(top, 1)))
                }
            }
        }
    }
}

private struct RankRow<BarContent: View>: View {
    let name: String
    let value: String
    @ViewBuilder let bar: (CGFloat) -> BarContent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name).font(.system(size: UI.Size.body)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text(value).font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary).fixedSize()
            }
            GeometryReader { g in bar(g.size.width) }.frame(height: 4)
        }
        .accessibilityElement(children: .combine)
    }
}
