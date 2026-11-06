import SwiftUI
import Charts
import AppKit
import ServiceManagement

struct DashboardView: View {
    @EnvironmentObject var store: Store
    var scrolls = true

    var body: some View {
        VStack(spacing: 0) {
            Header()
            Divider().opacity(0.5)
            if scrolls {
                ScrollView { cards }.frame(maxHeight: 640)
            } else {
                cards
            }
            Divider().opacity(0.5)
            Footer()
        }
        .frame(width: 380)
    }

    private var cards: some View {
                VStack(spacing: 10) {
                    AgentsCard()
                    UsageCard(title: "Claude Code", icon: "asterisk", tint: .orange, summary: store.claude,
                              loading: store.usageLoading, emptyHint: "No transcripts in ~/.claude/projects")
                    if store.codex.found {
                        UsageCard(title: "Codex", icon: "chevron.left.forwardslash.chevron.right", tint: .teal,
                                  summary: store.codex, loading: false, emptyHint: "", limits: store.codexLimits)
                    }
                    ServersCard()
                    SystemCard()
                }
                .padding(12)
    }
}

// MARK: - Chrome

private struct Header: View {
    @EnvironmentObject var store: Store
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.linearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("Dashbar").font(.system(size: 14, weight: .semibold))
            Spacer()
            if store.busyCount > 0 {
                Label("\(store.busyCount) working", systemImage: "circle.fill")
                    .labelStyle(DotLabel(color: .green))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            IconButton(symbol: "arrow.clockwise", help: "Refresh") { store.refreshNow() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct Footer: View {
    @EnvironmentObject var store: Store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        HStack {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .onChange(of: launchAtLogin) { _, on in
                    do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                    catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                }
            Spacer()
            Text("Updated \(store.lastUpdated.formatted(date: .omitted, time: .standard))")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            IconButton(symbol: "power", help: "Quit Dashbar") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Agents

private struct AgentsCard: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Card(title: "Agents", icon: "sparkles", trailing: store.sessions.isEmpty ? nil : "\(store.sessions.count) live") {
            if store.sessions.isEmpty {
                EmptyRow(text: "No Claude Code sessions running")
            } else {
                VStack(spacing: 2) {
                    ForEach(store.sessions) { SessionRow(session: $0) }
                }
            }
            if !store.otherAgents.isEmpty {
                FlowChips(items: store.otherAgents.map { $0.count > 1 ? "\($0.name) ×\($0.count)" : $0.name })
                    .padding(.top, 6)
            }
        }
    }
}

private struct SessionRow: View {
    let session: LiveSession
    @State private var hover = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 9) {
                StatusDot(active: session.isBusy)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text("\(session.project) · \(session.surface)")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(session.isBusy ? "Working" : session.status.capitalized)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(session.isBusy ? Color.green : Color.secondary)
                    Text(Fmt.ago(session.since, now: ctx.date))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 5).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.06) : .clear))
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd)) }
        .help("\(session.cwd)\nClick to open folder")
    }
}

// MARK: - Usage

private struct UsageCard: View {
    let title: String
    let icon: String
    let tint: Color
    let summary: UsageSummary
    let loading: Bool
    let emptyHint: String
    var limits: [RateLimit] = []

    var body: some View {
        Card(title: title, icon: icon, trailing: "7d \(Fmt.tokens(summary.week.total))") {
            if loading {
                HStack { ProgressView().controlSize(.small); Text("Scanning transcripts…").font(.caption).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !summary.found {
                EmptyRow(text: emptyHint)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Fmt.tokens(summary.today.total))
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .contentTransition(.numericText())
                        Text("tokens today").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(summary.today.messages) msgs").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        MiniStat(label: "In", value: summary.today.input)
                        MiniStat(label: "Out", value: summary.today.output)
                        MiniStat(label: "Cache R", value: summary.today.cacheRead)
                        MiniStat(label: "Cache W", value: summary.today.cacheWrite)
                    }
                    Chart(summary.last14) { p in
                        BarMark(x: .value("Day", p.date, unit: .day), y: .value("Tokens", p.tokens))
                            .foregroundStyle(p.isToday ? tint : tint.opacity(0.35))
                            .cornerRadius(2)
                    }
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                            AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                            AxisValueLabel { if let n = v.as(Int.self) { Text(Fmt.tokens(n)).font(.system(size: 9)) } }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                            AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.system(size: 9))
                        }
                    }
                    .frame(height: 70)

                    if !summary.topProjects.isEmpty {
                        HStack(alignment: .top, spacing: 14) {
                            RankList(title: "Projects today", items: summary.topProjects, tint: tint)
                            RankList(title: "Models", items: summary.topModels, tint: tint)
                        }
                    }
                    if !limits.isEmpty {
                        VStack(spacing: 6) { ForEach(limits) { LimitBar(limit: $0, tint: tint) } }
                    }
                }
            }
        }
    }
}

private struct MiniStat: View {
    let label: String
    let value: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary)
            Text(Fmt.tokens(value)).font(.system(size: 11.5, weight: .medium, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }
}

private struct RankList: View {
    let title: String
    let items: [Ranked]
    let tint: Color
    var body: some View {
        let maxV = Double(items.first?.value ?? 1)
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(item.name).font(.system(size: 10.5)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Fmt.tokens(item.value)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
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

private struct LimitBar: View {
    let limit: RateLimit
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(limit.label).font(.system(size: 10.5))
                Spacer()
                if let r = limit.resetsAt {
                    Text("resets \(r.formatted(.relative(presentation: .named)))").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Text("\(Int(limit.usedPercent))%").font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            }
            ProgressView(value: min(limit.usedPercent, 100), total: 100).tint(limit.usedPercent > 80 ? .red : tint)
        }
    }
}

// MARK: - Servers

private struct ServersCard: View {
    @EnvironmentObject var store: Store
    @State private var showOthers = false

    var body: some View {
        Card(title: "Local servers", icon: "server.rack", trailing: store.devListeners.isEmpty ? nil : "\(store.devListeners.count)") {
            if store.devListeners.isEmpty {
                EmptyRow(text: "No dev servers listening")
            } else {
                VStack(spacing: 2) { ForEach(store.devListeners) { ServerRow(listener: $0) } }
            }
            if !store.otherListeners.isEmpty {
                DisclosureGroup(isExpanded: $showOthers) {
                    VStack(spacing: 2) { ForEach(store.otherListeners) { ServerRow(listener: $0, compact: true) } }
                        .padding(.top, 4)
                } label: {
                    Text("Other listeners (\(store.otherListeners.count))").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
    }
}

private struct ServerRow: View {
    @EnvironmentObject var store: Store
    let listener: Listener
    var compact = false
    @State private var hover = false
    @State private var confirmStop = false

    var body: some View {
        HStack(spacing: 9) {
            Text(verbatim: ":\(listener.port)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill((compact ? Color.secondary : Color.blue).opacity(0.15)))
                .foregroundStyle(compact ? Color.secondary : Color.blue)
                .frame(minWidth: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(listener.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if !compact {
                    Text(listener.hint).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if hover || confirmStop {
                if !compact {
                    IconButton(symbol: "arrow.up.right.square", help: "Open http://localhost:" + String(listener.port)) {
                        NSWorkspace.shared.open(URL(string: "http://localhost:" + String(listener.port))!)
                    }
                }
                if confirmStop {
                    Button("Stop") { store.stop(listener); confirmStop = false }
                        .buttonStyle(.borderedProminent).tint(.red).controlSize(.mini)
                } else {
                    IconButton(symbol: "stop.circle", help: "Stop process \(listener.pid)") { confirmStop = true }
                }
            }
        }
        .padding(.vertical, compact ? 2 : 5).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0; if !$0 { confirmStop = false } }
        .help("\(listener.cmdline)\n\(listener.cwd)\nPID \(listener.pid) · \(listener.address)")
    }
}

// MARK: - System

private struct SystemCard: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let s = store.system
        Card(title: "System", icon: "cpu", trailing: "up \(Fmt.ago(Date().addingTimeInterval(-s.uptime)))") {
            VStack(spacing: 9) {
                HStack(spacing: 10) {
                    Gauge(label: "CPU", value: s.cpu, detail: "\(Int(s.cpu * 100))%", tint: .purple)
                    Sparkline(values: store.cpuHistory, tint: .purple).frame(height: 26)
                }
                Gauge(label: "Memory", value: Double(s.memUsed) / Double(max(s.memTotal, 1)),
                      detail: "\(Fmt.bytes(s.memUsed)) / \(Fmt.bytes(s.memTotal))", tint: .blue)
                if s.diskTotal > 0 {
                    Gauge(label: "Disk", value: 1 - Double(s.diskFree) / Double(s.diskTotal),
                          detail: "\(Fmt.bytes(s.diskFree)) free", tint: .mint)
                }
                if let b = s.battery {
                    Gauge(label: s.charging ? "Battery ⚡︎" : "Battery", value: Double(b) / 100, detail: "\(b)%",
                          tint: b < 20 ? .red : .green)
                }
            }
        }
    }
}

private struct Gauge: View {
    let label: String
    let value: Double
    let detail: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 11))
                Spacer()
                Text(detail).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(tint.gradient).frame(width: max(4, g.size.width * min(max(value, 0), 1)))
                }
            }
            .frame(height: 5)
            .animation(.easeOut(duration: 0.4), value: value)
        }
    }
}

private struct Sparkline: View {
    let values: [Double]
    let tint: Color
    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { i, v in
            AreaMark(x: .value("t", i), y: .value("cpu", v))
                .foregroundStyle(.linearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("t", i), y: .value("cpu", v))
                .foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth: 1.2))
                .interpolationMethod(.catmullRom)
        }
        .chartYScale(domain: 0...1)
        .chartXScale(domain: 0...39)
        .chartXAxis(.hidden).chartYAxis(.hidden)
    }
}

// MARK: - Building blocks

private struct Card<Content: View>: View {
    let title: String
    let icon: String
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).kerning(0.4)
                Spacer()
                if let trailing {
                    Text(trailing).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
            content
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

private struct StatusDot: View {
    let active: Bool
    @State private var pulse = false
    var body: some View {
        ZStack {
            if active {
                Circle().fill(Color.green.opacity(0.35)).frame(width: 14, height: 14)
                    .scaleEffect(pulse ? 1 : 0.4).opacity(pulse ? 0 : 1)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
            }
            Circle().fill(active ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
        .onAppear { pulse = true }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Color.primary.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hover = $0 }
        .help(help)
    }
}

private struct EmptyRow: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FlowChips: View {
    let items: [String]
    var body: some View {
        HStack(spacing: 5) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 5, height: 5)
                    Text(item).font(.system(size: 10.5))
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
    }
}

private struct DotLabel: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            configuration.title
        }
    }
}
