import SwiftUI
import Charts
import AppKit

// MARK: - Usage tab

/// One tool on the Usage tab, as its card shows it. Built from the store by `Store.usageServices`.
struct ServiceUsage: Identifiable {
    let service: UsageRules.Service
    var id: UsageRules.Service { service }
    /// "Claude Code · Max 5x", "Codex", "Gemini CLI · Antigravity".
    let title: String
    let icon: String
    /// The glyph's colour, and the fill for the card's meters and bars.
    let tint: Color
    let fill: Color
    let summary: UsageSummary
    var loading = false
    /// Each account's share, listed only with more than one account.
    var accounts: [AccountUsage] = []
    /// Added to the cost's explanation (Antigravity's own estimates).
    var costNote: String? = nil
    /// Every limit the card's rows show, across accounts.
    var limits: [RateLimit] = []
    /// Something the card must say, so it never folds (`UsageRules.Digest.hasNotice`).
    var hasNotice = false
    /// A small label after the title: "Experimental" for Claude's plan limits read from the endpoint.
    var badge: String? = nil
    /// Billed by a plan, not by token (Copilot): no cost is shown or estimated, and no "no price for" line.
    var planBilled = false
    /// Premium requests in each period, for a tool that counts them (Copilot), by `UsagePeriod.rawValue`.
    var premiumRequests: [Double]? = nil
    /// A line under the figures saying when they arrive ("Updated when a session ends").
    var caption: String? = nil
    /// Why some usage can't be known (sessions with no log), shown instead of a quiet zero.
    var unknownNote: String? = nil
    /// Plan limits are loading.
    var busy = false

    func digest(_ period: UsagePeriod) -> UsageRules.Digest {
        let usage = summary.period(period)
        return UsageRules.Digest(service: service, limits: limits, tokens: summary.found ? usage.totals.total : 0,
                                 cost: summary.found ? usage.cost : 0, hasNotice: hasNotice)
    }
}

extension Store {
    /// The tools the Usage tab has a card for, in Claude Code, Codex, Google, opencode, Copilot order (`UsageRules.order`
    /// sorts them). Claude Code always has one; the others only for someone who uses them and hasn't switched them off.
    func usageServices(settings: AppSettings, antigravityInstalled: Bool) -> [ServiceUsage] {
        let shows = settings.visibility
        let oneAccount = claudePlanLabel == nil && claudeAccountLimits.isEmpty
        let experimental = claudePlan.map { $0.source == .endpoint } ?? (!settings.claudeStatusLine && settings.claudeLimits)
        var out = [ServiceUsage(
            service: .claude,
            title: (["Claude Code", oneAccount ? claudePlan?.plan : nil] as [String?]).compactMap { $0 }.joined(separator: " · "),
            icon: "asterisk", tint: UI.claude, fill: UI.claudeFill, summary: claude, loading: usageLoading,
            accounts: claudeAccountUsage,
            limits: (settings.showsClaudeLimits && claudePlan?.problem == nil ? claudePlan?.limits ?? [] : [])
                + claudeAccountLimits.filter { $0.problem == nil }.flatMap(\.limits),
            hasNotice: usageLoading || claude.warning != nil || !claude.found || !settings.showsClaudeLimits
                || claudePlan?.problem != nil || claudeAccountLimits.contains { $0.problem != nil },
            badge: oneAccount && settings.showsClaudeLimits && experimental ? "Experimental" : nil,
            busy: oneAccount && settings.claudeLimits && claudePlanLoading)]
        if shows.shows(.codex), codex.found || !codexAccountLimits.isEmpty {
            out.append(ServiceUsage(
                service: .codex, title: "Codex", icon: "chevron.left.forwardslash.chevron.right", tint: UI.codex, fill: UI.codex,
                summary: codex, accounts: codexAccountUsage,
                limits: codexAccountLimits.isEmpty ? codexLimits : codexAccountLimits.flatMap(\.limits),
                hasNotice: codex.warning != nil))
        }
        // Only for someone with Google's tools: their transcripts, or the Antigravity CLI's bridge or a reading it left.
        if shows.shows(.google), google.found || antigravityLimits != nil || antigravityInstalled {
            let name = google.found ? GoogleUsage.title(googleSources) : "Antigravity CLI"
            // The plan tier names Antigravity's plan, so it joins the title only when the card is Antigravity's alone.
            let tier = name.hasPrefix("Antigravity") ? antigravityLimits?.planTier : nil
            out.append(ServiceUsage(
                service: .google, title: ([name, tier] as [String?]).compactMap { $0 }.joined(separator: " · "),
                icon: UI.googleSymbol, tint: UI.google, fill: UI.google, summary: google,
                costNote: GoogleUsage.costNote(googleSources),
                limits: antigravityLimits?.problem == nil ? antigravityLimits?.flattened ?? [] : [],
                hasNotice: google.warning != nil || antigravityLimits?.problem != nil))
        }
        // Only for someone with opencode's database. No limits: it runs on the user's own providers.
        if shows.shows(.opencode), opencode.found {
            out.append(ServiceUsage(
                service: .opencode, title: "OpenCode", icon: UI.openCodeSymbol, tint: UI.neutralTool, fill: UI.neutralTool,
                summary: opencode, costNote: OpenCodeUsageText.costNote, hasNotice: opencode.warning != nil))
        }
        // Only for someone with Copilot's session logs (the CLI, its agent in VS Code, the Copilot app). No limits: its premium-request allowance lives on GitHub,
        // which Dashbar never asks. Tokens arrive when a session ends, as Copilot writes them only then.
        if shows.shows(.copilot), copilot.shows {
            out.append(ServiceUsage(
                service: .copilot, title: CopilotCLI.displayName, icon: UI.copilotSymbol, tint: UI.neutralTool,
                fill: UI.neutralTool, summary: copilot.summary, costNote: CopilotUsageText.costNote,
                hasNotice: copilot.summary.warning != nil || copilot.unknownSessions > 0,
                planBilled: true, premiumRequests: UsagePeriod.allCases.map { copilot.premium($0) },
                caption: CopilotUsageText.caption, unknownNote: CopilotUsageText.unknown(copilot.unknownSessions)))
        }
        return out
    }
}

/// The Usage tab, in the panel and the window: one period choice for every card, a line across tools, then one card
/// per tool, the one closest to running out first (`UsageRules`).
struct UsageTab: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var antigravity = AntigravitySettings.shared
    @AppStorage(UsagePeriod.storageKey) private var periodRaw = UsagePeriod.today.rawValue
    @AppStorage(CostLine.showKey) private var showCost = true
    /// The window: two columns when there's room, and each card lists its workspaces and models.
    var wide = false

    var body: some View {
        let period = UsagePeriod(rawValue: periodRaw) ?? .today
        let now = Date()
        let services = store.usageServices(settings: settings, antigravityInstalled: antigravity.status.isInstalled)
        let digests = UsageRules.order(services.map { $0.digest(period) }, now: now)
        let ordered = digests.compactMap { d in services.first { $0.service == d.service } }
        let idle = Set(digests.filter(UsageRules.isIdle).map(\.service))
        // Which ticks the bars draw: the even pace, or on weekly rows today's share.
        let marks = ordered.filter { !idle.contains($0.service) }.flatMap { service in
            let history = store.shareHistory(for: service.service)
            return service.limits.map { l in (l, history[l.label].flatMap { TodayShare.compute(l, samples: $0, now: now) } != nil) }
        }
        VStack(alignment: .leading, spacing: UI.gap) {
            controls(period: period, digests: digests,
                     paceMark: marks.contains { !$0.1 && $0.0.paceMark(now: now) != nil },
                     shareMark: marks.contains { $0.1 })
            if wide && ordered.count > 1 {
                // Two columns when both fit at the panel's width or more; cards alternate so the first two sit side by side.
                let left = ordered.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
                let right = ordered.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: UI.gap) {
                        VStack(spacing: UI.gap) { cards(left, period: period, idle: idle) }.frame(minWidth: 400)
                        VStack(spacing: UI.gap) { cards(right, period: period, idle: idle) }.frame(minWidth: 400)
                    }
                    VStack(spacing: UI.gap) { cards(ordered, period: period, idle: idle) }
                }
            } else {
                cards(ordered, period: period, idle: idle)
            }
        }
    }

    private func cards(_ list: [ServiceUsage], period: UsagePeriod, idle: Set<UsageRules.Service>) -> some View {
        ForEach(list) { ServiceUsageCard(service: $0, period: period, idle: idle.contains($0.service), detailed: wide) }
    }

    /// The period picker with the key to the meters' tick, and with two or more tools in use, their total.
    private func controls(period: UsagePeriod, digests: [UsageRules.Digest], paceMark: Bool, shareMark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Period", selection: $periodRaw) {
                    ForEach(UsagePeriod.allCases) { Text($0.short).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 168)
                .help("The span every card below shows: today, the last 7 days or the last 14")
                Spacer(minLength: 8)
                if paceMark { PaceKey() }
                if shareMark { TodayShareKey() }
            }
            if UsageRules.showsSummary(digests) {
                let totals = UsageRules.totals(digests)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Fmt.tokens(totals.tokens)).font(.system(size: UI.Size.body, weight: .semibold).monospacedDigit())
                    Text("tokens \(period.span) across \(totals.tools) tools")
                        .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                    Spacer(minLength: 6)
                    if showCost && totals.cost > 0 {
                        Text("\u{2248} \(Fmt.usd(totals.cost))").font(.system(size: UI.Size.body, weight: .semibold).monospacedDigit())
                        Text("at API prices").font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                    }
                }
                .lineLimit(1)
                .help(CostLine.help(note: nil, missing: []))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// One tool's card: its plan limits, then the period's tokens with a chart and where they went. The header opens the
/// History page. An idle tool (no usage in the period, no limits) folds to the header alone.
struct ServiceUsageCard: View {
    @EnvironmentObject var store: Store
    let service: ServiceUsage
    let period: UsagePeriod
    var idle = false
    /// The window: the period's workspaces and models too.
    var detailed = false
    @AppStorage(CostLine.showKey) private var showCost = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !idle {
                // The limits and the tokens are two groups: more space between them than inside either.
                VStack(alignment: .leading, spacing: 18) {
                    ServiceLimits(service: service)
                    if service.service == .claude || service.summary.found || service.summary.warning != nil
                        || service.unknownNote != nil { tokens }
                }
            }
        }
        .padding(.horizontal, UI.cardPadding)
        .padding(.vertical, idle ? 9 : UI.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }

    private var header: some View {
        Button { AppWindow.shared.show(store: store, page: .history) } label: {
            HStack(spacing: 7) {
                IconChip(symbol: service.icon, tint: service.tint)
                Text(service.title).font(.system(size: UI.Size.body, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                if let badge = service.badge { ExperimentalBadge(text: badge) }
                Spacer(minLength: 6)
                if service.busy { ProgressView().controlSize(.mini) }
                if idle {
                    Text(period.noUsage).font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary).lineLimit(1)
                }
                Image(systemName: "chevron.right").font(.system(size: UI.Size.micro, weight: .semibold))
                    .foregroundStyle(UI.textSecondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help("Open History: 30 days of usage and how full each plan window got")
        .accessibilityLabel(idle ? "\(service.title), \(period.noUsage)" : service.title)
        .accessibilityHint("Opens the History page")
        .accessibilityAddTraits(.isHeader)   // the headings rotor still jumps between tools
    }

    @ViewBuilder private var tokens: some View {
        let summary = service.summary
        if service.loading {
            HStack { ProgressView().controlSize(.small); Text("Scanning transcripts…").font(.caption).foregroundStyle(UI.textSecondary) }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let warning = summary.warning {
            // Never a quiet zero: say the figure is unknown, with the reason in the tooltip.
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(UI.textDanger).accessibilityHidden(true)
                Text("Usage unknown: Dashbar can't read these logs.").fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: UI.Size.caption))
            .help(warning)
            .accessibilityElement(children: .combine)
            .accessibilityHint(warning)
        } else if !summary.found {
            if let note = service.unknownNote { UnknownUsageNote(text: note) } else { EmptyRow(text: "No transcripts found") }
        } else {
            let usage = summary.period(period)
            VStack(alignment: .leading, spacing: 8) {
                headline(usage)
                VStack(alignment: .leading, spacing: 4) {
                    Text(period == .today ? "By hour, last 24 hours · \(Self.sessions(summary.sessions24))" : "By day, last \(period.days) days")
                        .font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary)
                    if period == .today {
                        HourBars(points: summary.last24, tint: service.fill)
                    } else {
                        DayBars(points: Array(summary.last14.suffix(period.days)), tint: service.fill, height: 40, stretch: true,
                                label: "\(service.title) tokens by day, last \(period.days) days")
                    }
                }
                Text(Self.split(usage.totals))
                    .font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.9)
                    .help("Input, output, and cache reads and writes, which together make the total")
                if let premium = service.premiumRequests, premium.indices.contains(period.rawValue),
                   let line = CopilotUsageText.premiumLine(premium[period.rawValue], period: period) {
                    Text(line)
                        .font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary)
                        .help(service.costNote ?? "")
                }
                if let caption = service.caption {
                    Text(caption).font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = service.unknownNote { UnknownUsageNote(text: note) }
                if showCost && !service.planBilled && usage.totals.total > 0 && !usage.unpriced.isEmpty {
                    Text("No price for \(usage.unpriced.joined(separator: ", ")), so it's left out of the cost")
                        .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if usage.subagentTokens > 0 { SubagentShare(usage: usage, showCost: showCost) }
                if detailed && !usage.projects.isEmpty {
                    HStack(alignment: .top, spacing: 14) {
                        RankList(title: "Workspaces", items: usage.projects, tint: service.fill, showCost: showCost)
                        RankList(title: "Models", items: RankList.shortModels(usage.models), tint: service.fill, showCost: showCost)
                    }
                    .padding(.top, 4)
                }
                if service.accounts.count > 1 {
                    RankList(title: "Accounts", items: Self.byAccount(service.accounts, period), tint: service.fill, showCost: showCost)
                        .padding(.top, 4)
                }
            }
        }
    }

    /// "153M tokens today" with the estimated cost on the right.
    private func headline(_ usage: PeriodUsage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(Fmt.tokens(usage.totals.total))
                .font(.system(size: UI.Size.numeral, weight: .semibold, design: .rounded).monospacedDigit()).lineLimit(1)
            Text("tokens \(period.span)").font(.system(size: UI.Size.caption, weight: .semibold)).foregroundStyle(UI.textSecondary)
                .fixedSize()
            Spacer(minLength: 6)
            if showCost && usage.cost > 0 {
                Text("\u{2248} \(Fmt.usd(usage.cost))").font(.system(size: UI.Size.body, weight: .semibold).monospacedDigit())
                Text("at API prices").font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary).fixedSize()
            }
        }
        .help(service.planBilled ? service.costNote ?? "" : showCost ? CostLine.help(note: service.costNote, missing: usage.unpriced) : "")
        .accessibilityElement(children: .combine)
    }

    /// "In 1.2M · Out 640K · Cache read 148M · Cache write 2.9M": the total's parts on one line.
    static func split(_ t: TokenTotals) -> String {
        "In \(Fmt.tokens(t.input)) · Out \(Fmt.tokens(t.output)) · Cache read \(Fmt.tokens(t.cacheRead)) · Cache write \(Fmt.tokens(t.cacheWrite))"
    }

    static func sessions(_ n: Int) -> String { n == 1 ? "1 session" : "\(n) sessions" }

    /// Each account's tokens (and cost) for the period, largest first.
    static func byAccount(_ accounts: [AccountUsage], _ period: UsagePeriod) -> [Ranked] {
        accounts.map { a in
            let usage = a.summary.period(period)
            return Ranked(name: a.label, value: usage.totals.total, cost: usage.cost > 0 ? usage.cost : nil)
        }
        .sorted { ($0.value, $1.name) > ($1.value, $0.name) }
    }
}

/// Tokens by hour over the last 24 hours: the current hour in the tool's colour and earlier ones neutral, as the day
/// bars draw today against earlier days.
struct HourBars: View {
    let points: [HourPoint]
    let tint: Color

    var body: some View {
        let peak = Double(points.map(\.tokens).max() ?? 0)
        Chart(points) { p in
            BarMark(x: .value("Hour", p.date, unit: .hour),
                    yStart: .value("Base", 0),
                    yEnd: .value("Tokens", max(Double(p.tokens), peak * 0.035)))
                .foregroundStyle(p.tokens == 0 ? Color.primary.opacity(0.1) : (p.isNow ? tint : UI.dataPast))
                .cornerRadius(2)
        }
        .chartYScale(domain: 0...max(peak, 1))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .abbreviated))).font(.system(size: UI.Size.micro))
            }
        }
        .frame(height: 56)
        .accessibilityLabel("Tokens by hour, last 24 hours")
    }
}

/// The period's estimated cost at API list prices. Neutral on purpose: it is an estimate, not a bill or a warning.
enum CostLine {
    static let showKey = "showCost"

    /// The tooltip on every cost figure.
    static func help(note: String?, missing: [String]) -> String {
        "An estimate of what these tokens would cost on the pay-as-you-go API, at list prices from \(Pricing.asOf). "
            + "On a Claude, ChatGPT or Google AI plan you pay the plan's price, not this."
            + (missing.isEmpty ? "" : " Usage on models without a known price is left out.")
            + (note.map { " " + $0 } ?? "")
    }
}

struct ExperimentalBadge: View {
    var text = "Experimental"
    var body: some View {
        Text(text).font(.system(size: UI.Size.micro, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .foregroundStyle(UI.textSecondary)
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
                    .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)   // one stop: the name with its figure
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LimitBar: View {
    let limit: RateLimit
    let tint: Color
    /// The weekly series' readings behind today's share (`Store.shareHistory`); nil for a row without one.
    var samples: [PlanHistory.Sample]? = nil
    /// The countdown, the pace line and the mark follow the clock, not the reading: a limit can sit at the same percent
    /// for hours, and nothing else would redraw the row (issue #3). Same 30-second tick as the Overview's plan strip.
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in row(now: ctx.date) }
    }

    private func row(now: Date) -> some View {
        let used = min(max(limit.usedPercent, 0), 100)
        let pace = limit.pace(now: now)
        // A weekly row shows today's share instead of the even pace: its tick and its caption.
        let share = samples.flatMap { TodayShare.compute(limit, samples: $0, now: now) }
        // The even-pace mark only where there's a pace reading to go with it (never on a row whose caption is hidden).
        let mark = share == nil ? limit.paceMark(now: now) : nil
        let fillState = Self.fillState(used: used, pace: pace)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.label).font(.system(size: UI.Size.caption, weight: .medium))
                if let r = limit.resetsAt {
                    Text(Fmt.resets(r, now: now))
                        .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                } else if let credits = limit.credits {
                    Text(credits.text)
                        .font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(Fmt.usedPercent(limit.usedPercent))
                    .font(.system(size: UI.Size.caption, weight: .semibold).monospacedDigit())
                    .foregroundStyle(used >= 90 ? UI.textDanger : Color.primary)
            }
            .padding(.bottom, 2)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(UI.track).frame(height: 6)
                    // Drawn from the figure as shown, so "0% used" draws nothing and "1% used" a sliver.
                    let width = Meter.width(Self.shownFraction(limit.usedPercent), in: g.size.width, minimum: 3)
                    if let share, fillState == .normal, share.usedToday > 0 {
                        // Up to midnight in the fill colour, today's part lighter. Amber or red draw whole, as before.
                        ZStack(alignment: .leading) {
                            Rectangle().fill(tint.opacity(TodayShareKey.todayOpacity))
                            Rectangle().fill(tint).frame(width: min(width, g.size.width * share.startOfDay / 100))
                        }
                        .frame(width: width, height: 6)
                        .clipShape(Capsule())
                    } else {
                        Capsule().fill(Self.fill(used: used, pace: pace, tint: tint))
                            .frame(width: width, height: 6)
                    }
                    // Where usage would be if spread evenly over the window, or where today's share ends.
                    if let at = share?.mark ?? mark {
                        Capsule().fill(share == nil ? PaceKey.color : TodayShareKey.color)
                            .frame(width: 2, height: 10)
                            .offset(x: min(g.size.width - 2, max(0, g.size.width * at / 100 - 1)))
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 10)
            if let share {
                Text(share.caption(pace: pace, now: now))
                    .font(.system(size: UI.Size.caption))
                    .foregroundStyle(pace.map(Self.color) ?? UI.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } else if let pace {
                Text(Self.text(pace))
                    .font(.system(size: UI.Size.caption))
                    .foregroundStyle(Self.color(pace))
            }
        }
        .help(([share?.help, mark.map { "The mark shows where an even pace would be by now: \(Int($0.rounded()))% used." },
                Self.sourceNote(limit)] as [String?]).compactMap { $0 }.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(limit.label) limit, \(Int(max(0, limit.usedPercent).rounded())) percent used"
                            + (limit.credits.map { ", " + $0.text } ?? "")
                            + (share.map { ". " + $0.spoken + (pace.map { ", " + TodayShare.paceTail($0, now: now) } ?? "") }
                               ?? pace.map { ". " + Self.text($0) } ?? ""))
        .accessibilityValue(mark.map { "Even pace would be \(Int($0.rounded())) percent by now" } ?? "")
        .accessibilityHint(Self.sourceNote(limit) ?? "")
    }

    /// The share the fill draws: the percentage as the row prints it, so the bar and the figure agree.
    static func shownFraction(_ usedPercent: Double) -> Double {
        Double(Int(min(max(usedPercent, 0), 100).rounded())) / 100
    }

    /// The fill follows the colour rules: red once a limit is (nearly) used up, amber while it's on course to run
    /// out before it resets, otherwise the agent's own colour.
    static func fill(used: Double, pace: RateLimit.Pace?, tint: Color) -> Color {
        switch fillState(used: used, pace: pace) {
        case .problem: return UI.textDanger
        case .attention: return UI.attention
        case .normal: return tint
        }
    }

    enum FillState: Equatable { case normal, attention, problem }

    static func fillState(used: Double, pace: RateLimit.Pace?) -> FillState {
        if used >= 90 || pace == .usedUp { return .problem }
        if case .runsOut? = pace { return .attention }
        return .normal
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

/// One tool's limit rows. In a list of more than three, two or more at 0% used fold into a quiet "N more at 0%" line that opens to show them, so the
/// card leads with the limits in use; the tightest limit always keeps its row (`RateLimit.fold`).
struct LimitList: View {
    let limits: [RateLimit]
    let tint: Color
    /// Each weekly row's readings, by label, for its today's share (`Store.shareHistory`).
    var history: [String: [PlanHistory.Sample]] = [:]
    @State private var expanded = false

    var body: some View {
        let fold = RateLimit.fold(limits)
        // Rows sit apart from each other while each pace caption stays tight under its own bar.
        VStack(alignment: .leading, spacing: 10) {
            ForEach(expanded ? limits : fold.shown) { LimitBar(limit: $0, tint: tint, samples: history[$0.label]) }
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
}

/// The key to the mark on limit bars: a tick, then "even pace". Shown once, at the top of the Usage tab, only when a bar draws the mark.
struct PaceKey: View {
    static let color = Color.primary.opacity(0.55)
    var body: some View {
        HStack(spacing: 4) {
            Capsule().fill(Self.color).frame(width: 2, height: 9)
            Text("even pace").font(.system(size: UI.Size.micro)).foregroundStyle(UI.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The tick on each bar marks an even pace")
        .help("The tick on a bar shows where usage would be by now if it were spread evenly until the reset.")
    }
}

/// The key to the today's share tick on weekly bars. Shown beside the even-pace key when a bar draws it.
struct TodayShareKey: View {
    /// Full text colour, so it reads apart from the even-pace mark's grey (`PaceKey.color`).
    static let color = Color.primary
    /// Today's part of a weekly bar's fill: lighter than the rest, still clear on the dark track.
    static let todayOpacity = 0.5
    var body: some View {
        HStack(spacing: 4) {
            Capsule().fill(Self.color).frame(width: 2, height: 9)
            Text("today's share").font(.system(size: UI.Size.micro)).foregroundStyle(UI.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The tick on a weekly bar marks how far today's share goes")
        .help("On a weekly bar, the tick shows how far today's share goes: what was left at midnight, spread evenly over the days until it resets. The lighter part of the fill is what today has used.")
    }
}

// MARK: - Plan limits (inside each tool's card)

/// Wording shared by the Usage cards and the Overview's plan limits strip.
enum PlanLimitsText {
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
}

/// A tool's plan limit rows in its Usage card, with the notes that go with them: setup, problems, the reading's age.
/// With more than one account, each account's rows sit under its name.
struct ServiceLimits: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var antigravity = AntigravitySettings.shared
    let service: ServiceUsage

    var body: some View {
        switch service.service {
        case .claude:
            VStack(alignment: .leading, spacing: 16) {
                ClaudeLimitsSection()
                ForEach(store.claudeAccountLimits) { ClaudeAccountLimitsView(account: $0) }
            }
        case .codex:
            if !store.codexAccountLimits.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(store.codexAccountLimits) { CodexLimitsSection(label: $0.label, limits: $0.limits, history: store.shareHistory(codexAccount: $0)) }
                }
            } else if store.codex.found {
                CodexLimitsSection(label: nil, limits: store.codexLimits, history: store.shareHistory(store.codexLimits, provider: .codex, account: nil))
            }
        case .google:
            // Only for someone with the Antigravity CLI's bridge added, or a reading it left.
            if store.antigravityLimits != nil || antigravity.status.isInstalled {
                // Under "Gemini CLI · Antigravity" the rows say whose limits they are; an Antigravity card already does.
                AntigravityLimitsBlock(limits: store.antigravityLimits, connected: antigravity.status.isInstalled,
                                       showsHeader: !service.title.hasPrefix("Antigravity"))
            }
        case .opencode:
            EmptyView()   // no plan limits: opencode runs on the user's own providers
        case .copilot:
            EmptyView()   // its premium-request allowance is only on GitHub, which Dashbar doesn't ask
        }
    }
}

/// An account's name over its limit rows, with more than one account: "Work · Max 5x".
struct LimitsSubheader: View {
    let text: String
    var badge: String? = nil
    var busy = false

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: UI.Size.body, weight: .semibold)).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if let badge { ExperimentalBadge(text: badge) }
            Spacer(minLength: 4)
            if busy { ProgressView().controlSize(.mini) }
        }
    }
}

/// Claude's limits (the default account's), or why there are none yet.
struct ClaudeLimitsSection: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // With one account the card's title names the plan and carries the badge; with more, the account does.
            if let label = store.claudePlanLabel {
                let experimental = store.claudePlan.map { $0.source == .endpoint } ?? (!settings.claudeStatusLine && settings.claudeLimits)
                LimitsSubheader(text: ([label, store.claudePlan?.plan] as [String?]).compactMap { $0 }.joined(separator: " · "),
                                badge: settings.showsClaudeLimits && experimental ? "Experimental" : nil,
                                busy: settings.claudeLimits && store.claudePlanLoading)
            }
            content
        }
    }

    @ViewBuilder private var content: some View {
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
                            Text(retryAt > ctx.date ? "Trying again in \(PlanLimitsText.countdown(retryAt.timeIntervalSince(ctx.date)))"
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
            LimitList(limits: limits, tint: UI.claudeFill, history: store.shareHistory(limits, provider: .claude, account: nil))
            if let stale = store.claudePlan?.stale, let fetched = store.claudePlan?.fetchedAt {
                // Worked out live, so "2m ago" keeps counting and the countdown says when it will refresh.
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    HStack(spacing: 5) {
                        Image(systemName: "clock").accessibilityHidden(true)
                        Text(PlanLimitsText.staleLine(fetched: fetched, retryAt: store.claudePlanRetryAt, now: ctx.date))
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

/// One Codex account's limits; `label` names the account when there is more than one.
struct CodexLimitsSection: View {
    let label: String?
    let limits: [RateLimit]
    var history: [String: [PlanHistory.Sample]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label { LimitsSubheader(text: label) }
            if limits.isEmpty {
                Text("Codex hasn't reported limits yet. They appear after your next Codex session.")
                    .font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LimitList(limits: limits, tint: UI.codex, history: history)
            }
        }
    }
}

/// Another Claude Code account's limits, from its own status line bridge (Settings → Accounts adds it).
struct ClaudeAccountLimitsView: View {
    @EnvironmentObject var store: Store
    let account: AccountLimits

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LimitsSubheader(text: ([account.label, account.plan] as [String?]).compactMap { $0 }.joined(separator: " · "))
            if let problem = account.problem {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(UI.textDanger).accessibilityHidden(true)
                    Text(problem).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: UI.Size.caption))
            } else if !account.limits.isEmpty {
                LimitList(limits: account.limits, tint: UI.claudeFill, history: store.shareHistory(claudeAccount: account))
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

/// Wording for GitHub Copilot CLI's Usage card.
enum CopilotUsageText {
    static let caption = "Updated as Copilot works; totals are confirmed when a session ends."
    static let costNote = "GitHub Copilot is billed by your plan's premium requests, not by token, so Dashbar shows no cost "
        + "for it. Tokens come from each model call as Copilot logs it, replaced by the session's own totals when it ends. Premium requests are Copilot's own count, saved when each session ends. Your plan's allowance is only on GitHub."

    /// "12 premium requests today", "1 premium request in 7 days", "2.5 premium requests …". Nil for none: Copilot
    /// saves the count only when a session ends, so mid-session a zero means "not known yet", never "none used".
    static func premiumLine(_ n: Double, period: UsagePeriod) -> String? {
        guard n > 0 else { return nil }
        let figure = n == n.rounded() ? String(Int(n)) : String(format: "%.1f", n)
        return "\(figure) premium request\(n == 1 ? "" : "s") \(period.span)"
    }

    /// Nil with none.
    static func unknown(_ sessions: Int) -> String? {
        guard sessions > 0 else { return nil }
        return sessions == 1
            ? "Usage unknown for 1 session: Copilot saved no event log for it."
            : "Usage unknown for \(sessions) sessions: Copilot saved no event log for them."
    }
}

/// A line saying some usage can't be known, never a quiet zero.
struct UnknownUsageNote: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "questionmark.circle").foregroundStyle(UI.textSecondary).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: UI.Size.caption))
        .foregroundStyle(UI.textSecondary)
        .accessibilityElement(children: .combine)
    }
}

/// Wording for opencode's Usage card.
enum OpenCodeUsageText {
    static let costNote = "OpenCode's own cost is used where it recorded one; otherwise list prices, and models without a known price are left out."
}
