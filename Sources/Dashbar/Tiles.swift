import SwiftUI
import AppKit

// MARK: - Tiles

struct TileRow: View {
    @EnvironmentObject var store: Store
    let open: (PanelTab) -> Void

    var body: some View {
        HStack(spacing: UI.gap) {
            Button { open(.agents) } label: {
                // Someone waiting outranks work in progress: amber "needs you" until it's answered.
                Tile(title: "Agents",
                     badge: store.waitingCount > 0 ? "\(store.waitingCount) \(store.waitingCount == 1 ? "needs" : "need") you"
                          : store.busyCount > 0 ? "\(store.busyCount) working" : nil,
                     badgeTint: store.waitingCount > 0 ? UI.textAttention : UI.textSuccess,
                     value: "\(store.sessions.count)", unit: nil, selected: false) {
                    HourBars(points: Array(store.claude.last24.suffix(12)), tint: UI.accent, height: 16)
                }
            }
            .buttonStyle(PressStyle())
            .help("Show agents (⌘2)")
            .accessibilityLabel(agentsLabel)
            Button { open(.servers) } label: {
                Tile(title: "Servers", badge: store.devListeners.isEmpty ? nil : "Live",
                     value: "\(Set(store.devListeners.map(\.pid)).count)", unit: nil, selected: false) {
                    Text(store.serverMemory > 0 ? Fmt.bytes(store.serverMemory) : "—")
                        .font(.system(size: UI.Size.caption, weight: .medium).monospacedDigit()).foregroundStyle(UI.textSecondary)
                        .lineLimit(1).fixedSize()
                }
            }
            .buttonStyle(PressStyle())
            .help("Show servers (⌘3)")
            .accessibilityLabel(serversLabel)
            Button { open(.cleanup) } label: {
                let (v, u) = store.cleanupScanned ? Fmt.bytesSplit(store.cleanupTotal) : ("…", "")
                Tile(title: "Clean-up", badge: nil, value: v, unit: u, selected: false) {
                    CleanupMeter(items: store.cleanup)
                }
            }
            .buttonStyle(PressStyle())
            .help("Show clean-up (⌘5)")
            .accessibilityLabel(store.cleanupScanned ? "Clean-up, \(Fmt.diskBytes(store.cleanupTotal)) reclaimable" : "Clean-up, measuring")
        }
    }

    /// "Agents, 4 sessions, 1 needs you": the number with what it counts.
    private var agentsLabel: String {
        let n = store.sessions.count
        var text = "Agents, \(n) \(n == 1 ? "session" : "sessions")"
        if store.waitingCount > 0 { text += ", \(store.waitingCount) \(store.waitingCount == 1 ? "needs" : "need") you" }
        else if store.busyCount > 0 { text += ", \(store.busyCount) working" }
        return text
    }

    /// "Servers, 4 dev servers using 980 MB"
    private var serversLabel: String {
        let n = Set(store.devListeners.map(\.pid)).count
        return "Servers, \(n) dev \(n == 1 ? "server" : "servers")" + (store.serverMemory > 0 ? " using \(Fmt.bytes(store.serverMemory))" : "")
    }
}

struct Tile<Accessory: View>: View {
    let title: String
    let badge: String?
    var badgeTint: Color = UI.textSuccess
    let value: String
    let unit: String?
    let selected: Bool
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(selected ? .primary : .secondary)
                Spacer(minLength: 2)
                if let badge { Text(badge).font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(badgeTint).lineLimit(1) }
            }
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: UI.Size.numeral, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1).fixedSize()
                if let unit, !unit.isEmpty {
                    Text(unit).font(.system(size: UI.Size.caption, weight: .semibold)).foregroundStyle(UI.textSecondary).fixedSize()
                }
                Spacer(minLength: 6)
                accessory.frame(maxWidth: 44, maxHeight: 16, alignment: .bottomTrailing)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 10)
        .frame(minWidth: UI.column, maxWidth: .infinity, minHeight: 66, maxHeight: 66, alignment: .topLeading)
        .surface(selected: selected)
        .contentShape(Rectangle())
    }
}

/// Hourly activity: a 1pt baseline, with bars only where something happened.
struct HourBars: View {
    let points: [HourPoint]
    let tint: Color
    var height: CGFloat = 16
    var barWidth: CGFloat = 2.5

    var body: some View {
        let maxV = Double(points.map(\.messages).max() ?? 0)
        ZStack(alignment: .bottom) {
            Capsule().fill(Color.primary.opacity(0.14)).frame(height: 1)
            HStack(alignment: .bottom, spacing: barWidth * 0.6) {
                ForEach(points) { p in
                    let h = maxV > 0 ? height * Double(p.messages) / maxV : 0
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(p.isNow ? tint : Color.secondary.opacity(0.55))
                        .frame(width: barWidth, height: p.messages == 0 ? 0 : max(3, h))
                }
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityElement()
        .accessibilityLabel("Activity, last \(points.count) hours")
        .accessibilityValue("\(points.last?.messages ?? 0) messages this hour, \(points.reduce(0) { $0 + $1.messages }) in total")
    }
}

/// Reclaimable space by kind. Categories under 8% are dropped rather than drawn as dots.
struct CleanupMeter: View {
    let items: [CleanupItem]
    var body: some View {
        let total = Double(items.reduce(0) { $0 + $1.size })
        let groups = Dictionary(grouping: items, by: \.kind)
            .map { ($0.key, Double($0.value.reduce(0) { $0 + $1.size })) }
            .filter { total > 0 && $0.1 / total >= 0.08 }
            .sorted { $0.1 > $1.1 }.prefix(3)
        let shown = groups.reduce(0) { $0 + $1.1 }
        let colors: [Color] = [.blue, .purple, .orange]
        // Shrinks to whatever room the value leaves, so a wide figure never pushes it out of the tile.
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(groups.enumerated()), id: \.offset) { i, g in
                    Capsule().fill(colors[i].opacity(0.8))
                        .frame(width: max(2, (geo.size.width - 2 * CGFloat(groups.count - 1)) * g.1 / max(shown, 1)), height: 3)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(minWidth: 10, maxWidth: 32)
        .frame(height: 16, alignment: .bottom)
        .help(legend(groups.map { ($0.0, $0.1) }, colored: true))
        .accessibilityElement()
        .accessibilityLabel(legend(groups.map { ($0.0, $0.1) }, colored: false))
    }

    private func legend(_ groups: [(String, Double)], colored: Bool) -> String {
        let names = ["blue", "purple", "orange"]
        return groups.enumerated().map { i, g in
            (colored ? names[i] + ": " : "") + g.0 + " " + Fmt.diskBytes(UInt64(g.1))
        }.joined(separator: "\n")
    }
}
