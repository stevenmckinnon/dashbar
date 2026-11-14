import SwiftUI
import Charts
import AppKit

// MARK: - Usage

struct UsageCard: View {
    @EnvironmentObject var store: Store
    let title: String
    var icon: String? = nil
    let tint: Color
    let summary: UsageSummary
    let loading: Bool
    var limits: [RateLimit] = []
    /// Each account's share, shown only with more than one account.
    var accounts: [AccountUsage] = []
    /// Added to the cost's explanation (Antigravity's own estimates).
    var costNote: String? = nil
    @State private var period = UsagePeriod.today
    @AppStorage(CostLine.showKey) private var showCost = true

    var body: some View {
        let usage = summary.period(period)
        Card(title: title, icon: icon, tint: tint, count: nil, trailing: period.tokensLine(usage.totals.total)) {
            if loading {
                HStack { ProgressView().controlSize(.small); Text("Scanning transcripts…").font(.caption).foregroundStyle(UI.textSecondary) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !summary.found {
                EmptyRow(text: "No transcripts found")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Period", selection: $period) {
                        ForEach(UsagePeriod.allCases) { Text($0.short).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    HStack(spacing: 6) {
                        MiniStat(label: "In", value: usage.totals.input)
                        MiniStat(label: "Out", value: usage.totals.output)
                        MiniStat(label: "Cache read", value: usage.totals.cacheRead)
                        MiniStat(label: "Cache write", value: usage.totals.cacheWrite)
                    }
                    if showCost && usage.totals.total > 0 { CostLine(usage: usage, note: costNote) }
                    if usage.subagentTokens > 0 { SubagentShare(usage: usage, showCost: showCost) }
                    HStack {
                        Text(period == .today ? "By hour, last 24 hours" : "By day, last \(period.days) days")
                            .font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(UI.textSecondary)
                        if period == .today {
                            Text("· \(summary.sessions24) sessions").font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary)
                        }
                        Spacer()
                        Button { AppWindow.shared.show(store: store, page: .history) } label: {
                            HStack(spacing: 2) {
                                Text("History")
                                Image(systemName: "chevron.right").font(.system(size: UI.Size.micro - 1, weight: .semibold))
                            }
                        }
                        .buttonStyle(PressStyle())
                        .font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(UI.textInfo)
                        .help("Open the History page: 30 days of usage and how full each plan window got")
                    }
                    if period == .today { hourly } else { daily(Array(summary.last14.suffix(period.days))) }
                    if !usage.projects.isEmpty {
                        HStack(alignment: .top, spacing: 14) {
                            RankList(title: "Workspaces", items: usage.projects, tint: tint, showCost: showCost)
                            RankList(title: "Models", items: RankList.shortModels(usage.models), tint: tint, showCost: showCost)
                        }
                    }
                    if accounts.count > 1 {
                        RankList(title: "Accounts", items: Self.byAccount(accounts, period), tint: tint, showCost: showCost)
                    }
                    if !limits.isEmpty {
                        VStack(spacing: 6) { LimitList(limits: limits, tint: tint) }
                    }
                }
            }
        }
    }

    /// Each account's tokens (and cost) for the period, largest first.
    static func byAccount(_ accounts: [AccountUsage], _ period: UsagePeriod) -> [Ranked] {
        accounts.map { a in
            let usage = a.summary.period(period)
            return Ranked(name: a.label, value: usage.totals.total, cost: usage.cost > 0 ? usage.cost : nil)
        }
        .sorted { ($0.value, $1.name) > ($1.value, $0.name) }
    }

    private var hourly: some View {
        let peak = Double(summary.last24.map(\.tokens).max() ?? 0)
        return Chart(summary.last24) { p in
            BarMark(x: .value("Hour", p.date, unit: .hour),
                    yStart: .value("Base", 0),
                    yEnd: .value("Tokens", max(Double(p.tokens), peak * 0.035)))
                .foregroundStyle(p.tokens == 0 ? Color.primary.opacity(0.1) : (p.isNow ? tint : tint.opacity(0.45)))
                .cornerRadius(2)
        }
        .chartYScale(domain: 0...max(peak, 1))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .abbreviated))).font(.system(size: UI.Size.micro))
            }
        }
        .frame(height: 64)
    }

    private func daily(_ points: [DayPoint]) -> some View {
        Chart(points) { p in
            BarMark(x: .value("Day", p.date, unit: .day), y: .value("Tokens", p.tokens))
                .foregroundStyle(p.isToday ? tint : tint.opacity(0.4))
                .cornerRadius(2)
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel { if let n = v.as(Int.self) { Text(Fmt.tokens(n)).font(.system(size: UI.Size.micro)) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: points.count > 7 ? 3 : 1)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.system(size: UI.Size.micro))
            }
        }
        .frame(height: 78)
    }
}

struct MiniStat: View {
    let label: String
    let value: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: UI.Size.micro)).foregroundStyle(UI.textSecondary)
            Text(Fmt.tokens(value)).font(.system(size: UI.Size.body, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

/// The period's estimated cost at API list prices. Neutral on purpose: it is an estimate, not a bill or a warning.
struct CostLine: View {
    static let showKey = "showCost"
    let usage: PeriodUsage
    var note: String? = nil

    var body: some View {
        let missing = usage.unpriced
        let priced = usage.cost > 0 || missing.isEmpty
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if priced {
                Text("\u{2248} \(Fmt.usd(usage.cost))").font(.system(size: UI.Size.body, weight: .semibold).monospacedDigit())
                Text("at API prices").font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
            }
            Spacer(minLength: 4)
            if !missing.isEmpty {
                Text("no price for \(missing.joined(separator: ", "))")
                    .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .help("An estimate of what these tokens would cost on the pay-as-you-go API, at list prices from \(Pricing.asOf). "
              + "On a Claude, ChatGPT or Google AI plan you pay the plan's price, not this."
              + (missing.isEmpty ? "" : " Usage on models without a known price is left out.")
              + (note.map { " " + $0 } ?? ""))
        .accessibilityElement(children: .combine)
    }
}

/// "Of which subagents 41M · ≈ $12 · 27%": their share, already inside the totals above.
struct SubagentShare: View {
    let usage: PeriodUsage
    let showCost: Bool

    var body: some View {
        let share = Int((Double(usage.subagentTokens) / Double(max(usage.totals.total, 1)) * 100).rounded())
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: UI.Size.micro, weight: .semibold)).accessibilityHidden(true)
            Text(([("Of which subagents " + Fmt.tokens(usage.subagentTokens)),
                   showCost && usage.subagentCost > 0 ? "\u{2248} " + Fmt.usd(usage.subagentCost) : nil,
                   "\(share)%"] as [String?]).compactMap { $0 }.joined(separator: " · "))
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
        .help("Tokens used by subagents (Agent and Task tool runs). They are part of the totals above, counted once, "
              + "in the project each subagent worked in.")
        .accessibilityElement(children: .combine)
    }
}

struct RankList: View {
    /// Models under their short names (`Fmt.shortModel`). Names that become the same ("… (Thinking)" and the plain
    /// one) are added together, largest first, so a row is never listed twice.
    static func shortModels(_ items: [Ranked]) -> [Ranked] {
        var order: [String] = []
        var merged: [String: (value: Int, cost: Double?)] = [:]
        for item in items {
            let name = Fmt.shortModel(item.name)
            if let m = merged[name] {
                let cost: Double? = (m.cost == nil && item.cost == nil) ? nil : (m.cost ?? 0) + (item.cost ?? 0)
                merged[name] = (m.value + item.value, cost)
            } else {
                order.append(name)
                merged[name] = (item.value, item.cost)
            }
        }
        return order.map { Ranked(name: $0, value: merged[$0]!.value, cost: merged[$0]!.cost) }.sorted { $0.value > $1.value }
    }

    let title: String
    let items: [Ranked]
    let tint: Color
    var showCost = false
    var body: some View {
        let maxV = Double(items.first?.value ?? 1)
        VStack(alignment: .leading, spacing: 4) {
            Text(title).textCase(.uppercase).tracking(0.5).font(.system(size: UI.Size.micro, weight: .semibold)).foregroundStyle(UI.textSecondary)
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(item.name).font(.system(size: UI.Size.caption)).lineLimit(1)
                            .minimumScaleFactor(0.85).truncationMode(.middle).help(item.name)
                        Spacer(minLength: 4)
                        Text(Fmt.tokens(item.value) + (showCost ? item.cost.map { " \u{00B7} " + Fmt.usd($0) } ?? "" : ""))
                            .font(.system(size: UI.Size.micro).monospacedDigit()).foregroundStyle(UI.textSecondary)
                            .fixedSize()
                    }
                    GeometryReader { g in
                        Capsule().fill(tint.opacity(0.6))
                            .frame(width: max(3, g.size.width * Double(item.value) / max(maxV, 1)))
                    }
                    .frame(height: 3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LimitBar: View {
    let limit: RateLimit
    let tint: Color
    var body: some View {
        let used = min(max(limit.usedPercent, 0), 100)
        let expected = limit.expectedPercent()
        let pace = limit.pace()
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.label).font(.system(size: UI.Size.caption, weight: .medium))
                if let r = limit.resetsAt {
                    Text(Fmt.resets(r))
                        .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                }
                Spacer()
                Text(Fmt.usedPercent(limit.usedPercent))
                    .font(.system(size: UI.Size.caption, weight: .semibold).monospacedDigit())
                    .foregroundStyle(used >= 90 ? UI.textDanger : Color.primary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.16)).frame(height: 6)
                    Capsule().fill(used >= 90 ? UI.textDanger : tint).frame(width: max(4, g.size.width * used / 100), height: 6)
                    // Where usage would be if spread evenly over the window.
                    if let expected {
                        Capsule().fill(Color.primary.opacity(0.55))
                            .frame(width: 2, height: 10)
                            .offset(x: min(g.size.width - 2, max(0, g.size.width * expected / 100 - 1)))
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 10)
            if let pace {
                Text(Self.text(pace))
                    .font(.system(size: UI.Size.caption))
                    .foregroundStyle(Self.color(pace))
            }
        }
        .help(([expected.map { "The mark shows where an even pace would be by now: \(Int($0.rounded()))% used." },
                Self.sourceNote(limit)] as [String?]).compactMap { $0 }.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(limit.label) limit, \(Int(max(0, limit.usedPercent).rounded())) percent used" + (pace.map { ". " + Self.text($0) } ?? ""))
        .accessibilityHint(Self.sourceNote(limit) ?? "")
    }

    /// The provider's own name for a limit whose label was made from it: "Reported as gemini-argon-wtu-weekly".
    static func sourceNote(_ limit: RateLimit) -> String? {
        limit.source.map { "Reported as \($0)" }
    }

    /// A forecast of running out is a heads-up (amber); only a limit that's actually used up is a problem (red).
    static func color(_ pace: RateLimit.Pace) -> Color {
        switch pace {
        case .usedUp: return UI.textDanger
        case .runsOut: return UI.textAttention
        case .under, .onPace: return UI.textSecondary
        }
    }

    static func text(_ pace: RateLimit.Pace) -> String {
        switch pace {
        case .under: return "At this rate, plenty left when it resets"
        case .onPace: return "At this rate, lasts until it resets"
        case .usedUp: return "Used up until it resets"
        case .runsOut(let date):
            let when = Calendar.current.isDateInToday(date)
                ? "at " + date.formatted(date: .omitted, time: .shortened)
                : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            return "At this rate, runs out \(when)"
        }
    }
}

/// One tool's limit rows. Two or more at 0% used fold into a quiet "N more at 0%" line that opens to show them, so the
/// card leads with the limits in use; the tightest limit always keeps its row (`RateLimit.fold`).
struct LimitList: View {
    let limits: [RateLimit]
    let tint: Color
    @State private var expanded = false

    var body: some View {
        let fold = RateLimit.fold(limits)
        ForEach(expanded ? limits : fold.shown) { LimitBar(limit: $0, tint: tint) }
        if !fold.folded.isEmpty {
            Button { expanded.toggle() } label: {
                HStack(spacing: 3) {
                    Text(expanded ? "Show fewer" : "\(fold.folded.count) more at 0%")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: UI.Size.micro - 1, weight: .semibold))
                }
                .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .help(expanded ? "Hide the limits at 0% used" : fold.folded.map(\.label).joined(separator: ", "))
        }
    }
}

// MARK: - Plan limits (Agents tab)

struct PlanLimitsCard: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var antigravity = AntigravitySettings.shared

    var body: some View {
        Card(title: "Plan limits", icon: "gauge.with.needle", tint: .green, count: nil) {
            VStack(alignment: .leading, spacing: 12) {
                claude
                ForEach(store.claudeAccountLimits) { ClaudeAccountLimitsView(account: $0) }
                if !store.codexAccountLimits.isEmpty {
                    ForEach(store.codexAccountLimits) { a in codexBlock(label: a.label, limits: a.limits) }
                } else if store.codex.found {
                    codex
                }
                // Only for someone with the Antigravity CLI's bridge added, or a reading it left.
                if store.antigravityLimits != nil || antigravity.status.isInstalled {
                    AntigravityLimitsBlock(limits: store.antigravityLimits, connected: antigravity.status.isInstalled)
                }
            }
        }
    }

    /// Under limits kept from an earlier reading: "Updated 2m ago · trying again in 3m".
    static func staleLine(fetched: Date, retryAt: Date?, now: Date) -> String {
        let updated = "Updated \(Fmt.ago(fetched, now: now)) ago"
        guard let retryAt else { return updated }
        return updated + (retryAt > now ? " · trying again in \(countdown(retryAt.timeIntervalSince(now)))" : " · refreshing…")
    }

    /// "45s" under a minute, then the usual "4m", "1h 5m".
    static func countdown(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(max(1, Int(seconds.rounded(.up))))s" : Fmt.duration(seconds)
    }

    @ViewBuilder private var claude: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "asterisk").font(.system(size: UI.Size.caption, weight: .bold)).foregroundStyle(UI.claude)
                    .accessibilityHidden(true)
                Text(["Claude", store.claudePlanLabel, store.claudePlan?.plan].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: UI.Size.body, weight: .medium))
                if store.claudePlan.map({ $0.source == .endpoint }) ?? (!settings.claudeStatusLine && settings.claudeLimits) {
                    Text("Experimental").font(.system(size: UI.Size.micro, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .foregroundStyle(UI.textSecondary)
                }
                Spacer()
                if settings.claudeLimits, store.claudePlanLoading { ProgressView().controlSize(.mini) }
            }
            if !settings.showsClaudeLimits {
                HStack(alignment: .firstTextBaseline) {
                    Text("Claude doesn't save plan limits on your Mac. Dashbar can read them from Claude Code's status line.")
                        .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SettingsButton(tab: .claudeLimits) { Text("Settings…") }
                        .help("Opens Settings at Integrations, where Claude plan limits are set up")
                        .buttonStyle(.link).font(.system(size: UI.Size.caption, weight: .medium))
                }
            } else if let problem = store.claudePlan?.problem {
                // A temporary wait (rate limited, server trouble, offline) gets a quiet clock and a countdown under
                // the message; a problem the user has to fix keeps the red triangle and its action on the right.
                let waiting = store.claudePlan?.transient == true
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: waiting ? "clock" : "exclamationmark.triangle.fill")
                        .foregroundStyle(waiting ? AnyShapeStyle(UI.textSecondary) : AnyShapeStyle(UI.textDanger))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(problem).fixedSize(horizontal: false, vertical: true)
                        if waiting, let retryAt = store.claudePlanRetryAt {
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                Text(retryAt > ctx.date ? "Trying again in \(Self.countdown(retryAt.timeIntervalSince(ctx.date)))"
                                                        : "Trying again…")
                                    .monospacedDigit().foregroundStyle(UI.textSecondary)
                            }
                        }
                    }
                    .font(.system(size: UI.Size.caption))
                    Spacer(minLength: 4)
                    if store.claudeSigningIn {
                        HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Refreshing…").font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary) }
                    } else if store.claudePlan?.needsSignIn == true {
                        Button("Refresh") { store.refreshClaudeSignIn() }
                            .buttonStyle(.link).font(.system(size: UI.Size.caption, weight: .medium))
                            .help("Runs Claude Code once in the background, which refreshes its sign-in. Uses a few tokens.")
                    } else if !waiting {
                        Button("Retry") { store.refreshClaudePlan(force: true) }
                            .buttonStyle(.link).font(.system(size: UI.Size.caption, weight: .medium))
                    }
                }
            } else if let limits = store.claudePlan?.limits, !limits.isEmpty {
                LimitList(limits: limits, tint: UI.claude)
                if let stale = store.claudePlan?.stale, let fetched = store.claudePlan?.fetchedAt {
                    // Worked out live, so "2m ago" keeps counting and the countdown says when it will refresh.
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        HStack(spacing: 5) {
                            Image(systemName: "clock").accessibilityHidden(true)
                            Text(Self.staleLine(fetched: fetched, retryAt: store.claudePlanRetryAt, now: ctx.date))
                                .monospacedDigit().lineLimit(1)
                        }
                    }
                    .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                    .help(stale.explanation)
                } else if store.claudePlan?.source == .statusLine, let fetched = store.claudePlan?.fetchedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        if let line = ClaudeStatusLine.ageLine(writtenAt: fetched, now: ctx.date) {
                            HStack(spacing: 5) {
                                Image(systemName: "clock").accessibilityHidden(true)
                                Text(line).fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                        }
                    }
                }
            } else if settings.claudeStatusLine && !store.claudePlanLoading {
                Text("Limits appear after your next Claude Code reply.")
                    .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Loading plan limits…").font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
            }
        }
    }

    private var codex: some View { codexBlock(label: nil, limits: store.codexLimits) }

    private func codexBlock(label: String?, limits: [RateLimit]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: UI.Size.caption, weight: .bold))
                    .foregroundStyle(.teal).accessibilityHidden(true)
                Text(["Codex", label].compactMap { $0 }.joined(separator: " · ")).font(.system(size: UI.Size.body, weight: .medium))
            }
            if limits.isEmpty {
                Text("Codex hasn't reported limits yet. They appear after your next Codex session.")
                    .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
            } else {
                LimitList(limits: limits, tint: .teal)
            }
        }
    }
}

/// Another Claude Code account's limits, from its own status line bridge (Settings → Accounts adds it).
struct ClaudeAccountLimitsView: View {
    let account: AccountLimits

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "asterisk").font(.system(size: UI.Size.caption, weight: .bold)).foregroundStyle(UI.claude)
                    .accessibilityHidden(true)
                Text(["Claude", account.label, account.plan].compactMap { $0 }.joined(separator: " · ")).font(.system(size: UI.Size.body, weight: .medium))
            }
            if let problem = account.problem {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(UI.textDanger).accessibilityHidden(true)
                    Text(problem).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: UI.Size.caption))
            } else if !account.limits.isEmpty {
                LimitList(limits: account.limits, tint: UI.claude)
                if let fetched = account.fetchedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        if let line = ClaudeStatusLine.ageLine(writtenAt: fetched, now: ctx.date) {
                            HStack(spacing: 5) {
                                Image(systemName: "clock").accessibilityHidden(true)
                                Text(line).fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                        }
                    }
                }
            } else if account.connected {
                Text("Limits appear after this account's next Claude Code reply.")
                    .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("Add Dashbar to this account's status line to see its limits.")
                        .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SettingsButton(tab: .otherAccounts) { Text("Settings…") }
                        .buttonStyle(.link).font(.system(size: UI.Size.caption, weight: .medium))
                }
            }
        }
    }
}
