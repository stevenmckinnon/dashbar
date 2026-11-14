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
                          : store.busyCount > 0 ? "\(store.busyCount) working"
                          : store.sessions.isEmpty ? nil : "All idle",
                     badgeTint: store.waitingCount > 0 ? UI.textAttention : store.busyCount > 0 ? UI.textSuccess : UI.textSecondary,
                     value: "\(store.sessions.count)", unit: nil, quiet: store.sessions.isEmpty, selected: false,
                     accessoryWidth: SessionDots.width) {
                    // One dot per session, in its state's colour, so the picture is the number beside it.
                    SessionDots(waiting: store.waitingCount, working: store.busyCount,
                                idle: store.sessions.count - store.waitingCount - store.busyCount)
                }
            }
            .buttonStyle(PressStyle())
            .help("Show agents (⌘2)")
            .accessibilityLabel(agentsLabel)
            Button { open(.servers) } label: {
                let count = Set(store.devListeners.map(\.pid)).count
                // A running server isn't an agent, so "Live" stays neutral; green is for working agents.
                Tile(title: "Servers", badge: count == 0 ? nil : "Live", badgeTint: UI.textSecondary,
                     value: "\(count)", unit: nil, quiet: count == 0, selected: false) {
                    if store.serverMemory > 0 {
                        Text(Fmt.bytes(store.serverMemory))
                            .font(.system(size: UI.Size.caption, weight: .medium).monospacedDigit()).foregroundStyle(UI.textSecondary)
                            .lineLimit(1).fixedSize()
                    }
                }
            }
            .buttonStyle(PressStyle())
            .help("Show servers (⌘3)")
            .accessibilityLabel(serversLabel)
            Button { open(.cleanup) } label: {
                let (v, u) = store.cleanupScanned ? Fmt.bytesSplit(store.cleanupTotal) : ("…", "")
                let biggest = store.cleanupScanned ? Self.biggest(store.cleanup) : nil
                Tile(title: "Clean-up", badge: nil, value: v, unit: u,
                     quiet: store.cleanupScanned && store.cleanupTotal == 0, selected: false,
                     detail: biggest.map { [$0.name + " " + Fmt.diskBytes($0.size), Self.folderCount(store.cleanup.count)] }) {
                    EmptyView()
                }
            }
            .buttonStyle(PressStyle())
            .help("Show clean-up (⌘5)")
            .accessibilityLabel(cleanupLabel)
        }
    }

    /// The single largest folder to clean up, named as the Clean-up tab names it: "Xcode" for DerivedData,
    /// otherwise its project.
    static func biggest(_ items: [CleanupItem]) -> (name: String, size: UInt64)? {
        guard let top = items.max(by: { $0.size < $1.size }), top.size > 0 else { return nil }
        return (top.project, top.size)
    }

    /// What Clean-up found, counted in the Clean-up tab's own word: "1 folder", "6 folders".
    static func folderCount(_ n: Int) -> String { "\(n) \(n == 1 ? "folder" : "folders")" }

    /// "Agents, 4 sessions: 1 needs you, 1 working, 2 idle": the number with what it counts, as the dots show it.
    private var agentsLabel: String {
        SessionDots.label(waiting: store.waitingCount, working: store.busyCount,
                          idle: store.sessions.count - store.waitingCount - store.busyCount)
    }

    /// "Servers, 4 dev servers using 980 MB"
    private var serversLabel: String {
        let n = Set(store.devListeners.map(\.pid)).count
        return "Servers, \(n) dev \(n == 1 ? "server" : "servers")" + (store.serverMemory > 0 ? " using \(Fmt.bytes(store.serverMemory))" : "")
    }

    /// "Clean-up, 6.99 GB reclaimable in 6 folders, the largest Xcode at 2.3 GB": everything the tile can show,
    /// whichever of it fits on screen.
    private var cleanupLabel: String {
        guard store.cleanupScanned else { return "Clean-up, measuring" }
        let base = "Clean-up, \(Fmt.diskBytes(store.cleanupTotal)) reclaimable"
        guard let top = Self.biggest(store.cleanup) else { return base }
        return base + " in \(Self.folderCount(store.cleanup.count)), the largest \(top.name) at \(Fmt.diskBytes(top.size))"
    }
}

/// The Agents tile's picture: one dot per session, needs-you first (amber), then working (green), then idle (grey),
/// with "+N" past what fits. It counts the same thing as the number beside it.
struct SessionDots: View {
    let waiting: Int
    let working: Int
    let idle: Int

    enum State: Equatable { case waiting, working, idle }
    static let dot: CGFloat = 6
    static let spacing: CGFloat = 3
    /// Room for six dots, or four and a "+N".
    static let width: CGFloat = 6 * dot + 5 * spacing
    static let capacity = 6

    /// The dots to draw and how many are left over for "+N". With more than `capacity` sessions, one slot fewer
    /// for dots and two for the "+N" label, so the picture never grows past its slot.
    static func layout(waiting: Int, working: Int, idle: Int, capacity: Int = SessionDots.capacity) -> (dots: [State], more: Int) {
        let all = Array(repeating: State.waiting, count: max(0, waiting)) + Array(repeating: .working, count: max(0, working))
            + Array(repeating: .idle, count: max(0, idle))
        guard all.count > capacity else { return (all, 0) }
        let shown = max(1, capacity - 2)
        return (Array(all.prefix(shown)), all.count - shown)
    }

    /// The counts in words, for VoiceOver: "Agents, 4 sessions: 1 needs you, 1 working, 2 idle".
    static func label(waiting: Int, working: Int, idle: Int) -> String {
        let n = waiting + working + idle
        guard n > 0 else { return "Agents, no sessions" }
        let parts = [waiting > 0 ? "\(waiting) \(waiting == 1 ? "needs" : "need") you" : nil,
                     working > 0 ? "\(working) working" : nil,
                     idle > 0 ? "\(idle) idle" : nil].compactMap { $0 }
        return "Agents, \(n) \(n == 1 ? "session" : "sessions"): " + parts.joined(separator: ", ")
    }

    var body: some View {
        let l = Self.layout(waiting: waiting, working: working, idle: idle)
        HStack(spacing: Self.spacing) {
            ForEach(Array(l.dots.enumerated()), id: \.offset) { _, state in
                Circle().fill(Self.color(state)).frame(width: Self.dot, height: Self.dot)
            }
            if l.more > 0 {
                Text("+\(l.more)").font(.system(size: UI.Size.micro, weight: .semibold).monospacedDigit())
                    .foregroundStyle(UI.textSecondary).fixedSize()
            }
        }
        .frame(height: 13, alignment: .center)
        .accessibilityHidden(true)   // the tile's label states the counts
    }

    static func color(_ state: State) -> Color {
        switch state {
        case .waiting: return UI.attention
        case .working: return .green
        case .idle: return Color.secondary.opacity(0.5)   // as StatusDot draws an idle session
        }
    }
}

struct Tile<Accessory: View>: View {
    let title: String
    let badge: String?
    var badgeTint: Color = UI.textSuccess
    let value: String
    let unit: String?
    /// Nothing to count: the figure drops to secondary ink, a calm state rather than an alarm.
    var quiet = false
    let selected: Bool
    var accessoryWidth: CGFloat = 44
    /// Quiet text in the badge's place, longest first; the first that fits is shown ("Xcode 2.3 GB", then
    /// "6 folders"), or nothing when none fits, never a clipped word.
    var detail: [String]? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(selected ? .primary : .secondary)
                    .fixedSize()
                Spacer(minLength: 2)
                if let badge { Text(badge).font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(badgeTint).lineLimit(1) }
                else if let detail, !detail.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        ForEach(detail, id: \.self) { Text($0).lineLimit(1).fixedSize() }
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary)
                }
            }
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: UI.Size.numeral, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(quiet ? AnyShapeStyle(UI.textSecondary) : AnyShapeStyle(.primary))
                    .lineLimit(1).fixedSize()
                if let unit, !unit.isEmpty {
                    Text(unit).font(.system(size: UI.Size.caption, weight: .semibold)).foregroundStyle(UI.textSecondary).fixedSize()
                }
                Spacer(minLength: 6)
                accessory.frame(maxWidth: accessoryWidth, maxHeight: 16, alignment: .bottomTrailing)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 10)
        .frame(minWidth: UI.column, maxWidth: .infinity, minHeight: 66, maxHeight: 66, alignment: .topLeading)
        .surface(selected: selected)
        .contentShape(Rectangle())
    }
}
