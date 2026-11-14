import SwiftUI
import AppKit

// MARK: - System tab

struct SystemPage: View {
    @EnvironmentObject var store: Store
    let query: String

    var body: some View {
        let s = store.system
        let h = store.history
        VStack(spacing: UI.gap) {
            // CPU
            MetricCard(title: "CPU", icon: "cpu", tint: .secondary, trailing: "up \(Fmt.ago(Date().addingTimeInterval(-s.uptime)))",
                       caption: "\(s.cores) cores · \(s.chip)",
                       value: "\(Int((s.cpu * 100).rounded()))", unit: "%") {
                StatRow([("User", "\(Int((s.cpuUser * 100).rounded()))%"),
                         ("System", "\(Int((s.cpuSystem * 100).rounded()))%"),
                         ("Load", String(format: "%.2f", s.load[0]))])
                BarHistory(values: h.cpu, maxValue: 1, label: "CPU, last \(h.cpu.count) samples")
            }
            // Memory
            MetricCard(title: "Memory", icon: "memorychip", tint: .secondary, trailing: nil,
                       caption: "In use of \(Fmt.bytes(s.memTotal))",
                       value: Fmt.bytesSplit(s.memUsed, style: .memory).0, unit: Fmt.bytesSplit(s.memUsed, style: .memory).1,
                       badge: PressureBadge(pressure: s.pressure)) {
                StatRow([("App", Fmt.bytes(s.memApp)), ("Wired", Fmt.bytes(s.memWired)),
                         ("Compressed", Fmt.bytes(s.memCompressed))] + (s.swapUsed > 0 ? [("Swap", Fmt.bytes(s.swapUsed))] : []))
                BarHistory(values: h.memory, maxValue: 1, label: "Memory, last \(h.memory.count) samples")
            }
            // Network
            MetricCard(title: "Network", icon: "network", tint: .secondary, trailing: nil,
                       caption: "Download", value: Fmt.rate(s.netDown).split(separator: " ").first.map(String.init) ?? "0",
                       unit: Fmt.rate(s.netDown).split(separator: " ").dropFirst().joined(separator: " ")) {
                StatRow([("Upload", Fmt.rate(s.netUp)),
                         ("Peak download", Fmt.rate(h.down.max() ?? 0))])
                BarHistory(values: h.down, maxValue: nil, label: "Download, last \(h.down.count) samples")
            }
            // GPU
            if let gpu = s.gpu {
                MetricCard(title: "GPU", icon: "square.stack.3d.up.fill", tint: .secondary, trailing: nil,
                           caption: s.chip, value: "\(Int((gpu * 100).rounded()))", unit: "%") {
                    StatRow([("Average", "\(Int(((h.gpu.reduce(0, +) / Double(max(h.gpu.count, 1))) * 100).rounded()))%"),
                             ("Peak", "\(Int(((h.gpu.max() ?? 0) * 100).rounded()))%")])
                    BarHistory(values: h.gpu, maxValue: 1, label: "GPU, last \(h.gpu.count) samples")
                }
            }
            // Disk and battery
            HStack(spacing: UI.gap) {
                if s.diskTotal > 0 {
                    // The figure is the free space, so the bar fills the free share, as Battery's fills the charge left.
                    let free = Double(s.diskFree) / Double(s.diskTotal)
                    MiniMetric(title: "Disk", icon: "internaldrive", tint: free < 0.10 ? UI.textDanger : UI.meterFill,
                               value: Self.split(Fmt.driveBytes(s.diskFree)).0, unit: Self.split(Fmt.driveBytes(s.diskFree)).1 + " free",
                               fraction: free, detail: "of \(Fmt.driveBytes(s.diskTotal))",
                               spokenValue: "\(Fmt.driveBytes(s.diskFree)) free of \(Fmt.driveBytes(s.diskTotal))")
                }
                if let b = s.battery {
                    MiniMetric(title: s.charging ? "Battery · charging" : "Battery", icon: s.charging ? "battery.100.bolt" : "battery.75",
                               tint: b < 20 && !s.charging ? UI.textDanger : UI.meterFill,
                               value: "\(b)", unit: "%", fraction: Double(b) / 100,
                               detail: s.batteryMinutes.map { Fmt.minutes($0) + (s.charging ? " to full" : " left") }
                                   ?? (s.onAC ? "On power" : "Estimating…"))
                }
            }
            BusiestApps(apps: store.topApps, query: query)
        }
    }
}

extension SystemPage {
    /// "421 GB" → ("421", "GB").
    static func split(_ s: String) -> (String, String) {
        let parts = s.split(separator: " ", maxSplits: 1)
        return (String(parts.first ?? ""), parts.count > 1 ? String(parts[1]) : "")
    }
}

struct MetricCard<Badge: View, Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    let trailing: String?
    let caption: String
    let value: String
    let unit: String
    var badge: Badge
    @ViewBuilder var content: Content

    init(title: String, icon: String, tint: Color, trailing: String?, caption: String, value: String, unit: String,
         badge: Badge = EmptyView(), @ViewBuilder content: () -> Content) {
        self.title = title; self.icon = icon; self.tint = tint; self.trailing = trailing
        self.caption = caption; self.value = value; self.unit = unit; self.badge = badge; self.content = content()
    }

    var body: some View {
        Card(title: title, icon: icon, tint: tint, count: nil, trailing: trailing) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(caption).font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary).lineLimit(1)
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(value).font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                        Text(unit).font(.system(size: UI.Size.emphasis, weight: .semibold)).foregroundStyle(UI.textSecondary)
                        Spacer()
                        badge
                    }
                }
                content
            }
        }
    }
}

/// Memory pressure with an icon and a word, so it never relies on colour alone.
struct PressureBadge: View {
    let pressure: MemoryPressure
    var body: some View {
        let (symbol, color): (String, Color) = {
            switch pressure {
            // Green is for working agents, so a normal reading stays neutral; amber is "soon", red a real problem.
            case .normal: return ("checkmark", UI.textSecondary)
            case .warning: return ("exclamationmark", UI.textAttention)
            case .critical: return ("exclamationmark.triangle.fill", UI.textDanger)
            }
        }()
        Label(pressure.label, systemImage: symbol)
            .font(.system(size: UI.Size.caption, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(pressure == .warning ? UI.attention.opacity(0.16) : pressure == .normal ? Color.primary.opacity(0.07) : color.opacity(0.14)))
            .help("Memory pressure: how hard macOS is working to find free memory. Normal is fine even when usage looks high.")
    }
}

struct StatRow: View {
    let items: [(String, String)]
    init(_ items: [(String, String)]) { self.items = items }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.0).font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                    Text(item.1).font(.system(size: UI.Size.body, weight: .semibold).monospacedDigit()).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Recent samples as small vertical bars, newest on the right and darkest; empty slots show as faint stubs.
/// Neutral: a system figure isn't an agent's, so it takes no colour.
struct BarHistory: View {
    let values: [Double]
    /// Fixed scale (e.g. 1 for percentages); nil scales to the largest value shown.
    let maxValue: Double?
    let label: String
    var height: CGFloat = 32

    var body: some View {
        let n = SystemHistory.length
        let peak = maxValue ?? max(values.max() ?? 0, 1)
        GeometryReader { g in
            let spacing: CGFloat = 2
            let w = max(1, (g.size.width - spacing * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<n, id: \.self) { i in
                    let index = i - (n - values.count)
                    let v = index >= 0 ? values[index] : 0
                    RoundedRectangle(cornerRadius: min(1.5, w / 2))
                        .fill(index >= 0 ? (i == n - 1 ? UI.dataNow : UI.dataPast) : Color.primary.opacity(0.06))
                        .frame(width: w, height: index >= 0 ? max(2, height * min(v / peak, 1)) : 2)
                }
            }
            .frame(height: height, alignment: .bottom)
        }
        .frame(height: height)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous).fill(Color.primary.opacity(0.04)))
        .accessibilityElement()
        .accessibilityLabel(label)
    }
}

struct MiniMetric: View {
    let title: String
    let icon: String
    let tint: Color
    let value: String
    let unit: String
    let fraction: Double
    let detail: String
    /// What VoiceOver reads as the value; by default the figure and its unit.
    var spokenValue: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                IconChip(symbol: icon, tint: tint)
                Text(title).font(.system(size: UI.Size.body, weight: .semibold)).lineLimit(1)
            }
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value).font(.system(size: UI.Size.numeral, weight: .semibold, design: .rounded).monospacedDigit())
                Text(unit).font(.system(size: UI.Size.caption, weight: .semibold)).foregroundStyle(UI.textSecondary).lineLimit(1)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(UI.track)
                    Capsule().fill(tint).frame(width: Meter.width(fraction, in: g.size.width, minimum: 3))
                }
            }
            .frame(height: 5)
            Text(detail).font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary).lineLimit(1)
        }
        .padding(UI.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue((spokenValue ?? "\(value) \(unit)") + ", " + detail)
    }
}

struct BusiestApps: View {
    let apps: [AppUsage]
    let query: String

    var body: some View {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let shown = q.isEmpty ? apps : apps.filter { $0.name.lowercased().contains(q) }
        let peak = max(shown.first?.cpu ?? 0, 0.01)
        Card(title: "Busiest right now", icon: "flame", tint: .secondary, count: nil, trailing: "share of all CPU") {
            if apps.isEmpty {
                EmptyRow(text: "Measuring… this fills in after a few seconds.")
            } else if shown.isEmpty {
                EmptyRow(text: "No busy apps match “\(query)”")
            } else {
                VStack(spacing: 6) {
                    ForEach(shown) { app in
                        HStack(spacing: 9) {
                            AppIcon(path: app.appPath)
                            Text(app.name).font(.system(size: UI.Size.body, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 8)
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(UI.track)
                                    Capsule().fill(UI.meterFill).frame(width: Meter.width(app.cpu / peak, in: g.size.width, minimum: 3))
                                }
                            }
                            .frame(width: 70, height: 5)
                            Text(String(format: "%.1f%%", app.cpu * 100))
                                .font(.system(size: UI.Size.body, weight: .semibold).monospacedDigit())
                                .frame(width: 48, alignment: .trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(String(format: "%@, %.1f percent of CPU", app.name, app.cpu * 100))
                    }
                }
            }
        }
    }
}

/// The app's own icon when it lives in a bundle, a terminal glyph for command-line tools.
struct AppIcon: View {
    let path: String?
    private static var cache: [String: NSImage] = [:]

    var body: some View {
        Group {
            if let path {
                Image(nsImage: Self.icon(for: path)).resizable()
            } else {
                Image(systemName: "terminal").font(.system(size: UI.Size.caption, weight: .semibold))
                    .foregroundStyle(UI.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    private static func icon(for path: String) -> NSImage {
        if let hit = cache[path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}
