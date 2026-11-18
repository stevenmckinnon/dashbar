import SwiftUI
import AppKit

// MARK: - Workspace detail

/// A figure with its recent history underneath.
struct UsageTile: View {
    let title: String
    let value: String
    let unit: String
    let values: [Double]
    var style: Sparkbars.Style = .bars
    let caption: String
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value).font(.system(size: UI.Size.numeral, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.7)
                if !unit.isEmpty {
                    Text(unit).font(.system(size: UI.Size.caption, weight: .semibold)).foregroundStyle(UI.textSecondary).fixedSize()
                }
            }
            if style == .none {
                Color.clear.frame(height: 18)   // keeps a row of tiles level
            } else {
                Sparkbars(values: Array(values.suffix(Sparkbars.count)), style: style)
            }
            Text(caption).font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 11).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .surface()
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value) \(unit), \(caption)")
    }
}

/// Recent samples, newest on the right and darkest. Bars suit bursty figures (CPU, energy) and are scaled to their own
/// peak: they show the shape of the last few minutes, the figure above gives the size. A line suits figures that drift
/// (memory): its scale spans at least 10% either side of the average, so a small drift draws as a small slope.
struct Sparkbars: View {
    enum Style { case bars, line, none }
    static let count = 24
    let values: [Double]
    var style: Style = .bars
    var height: CGFloat = 18

    var body: some View {
        switch style {
        case .bars: bars
        case .line: line
        case .none: EmptyView()
        }
    }

    private var line: some View {
        let domain = Self.lineDomain(values)
        let lo = domain.lowerBound, hi = domain.upperBound
        let flat = hi <= lo
        return GeometryReader { g in
            let step = g.size.width / CGFloat(Self.count - 1)
            let offset = CGFloat(Self.count - values.count)
            let point: (Int) -> CGPoint = { i in
                let y = flat ? 0.5 : (values[i] - lo) / (hi - lo)
                return CGPoint(x: (offset + CGFloat(i)) * step, y: 2 + (height - 4) * (1 - y))
            }
            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: 1).offset(y: height - 1)
                if values.count > 1 {
                    Path { p in
                        p.move(to: point(0))
                        for i in 1..<values.count { p.addLine(to: point(i)) }
                    }
                    .stroke(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
                if !values.isEmpty {
                    let last = point(values.count - 1)
                    Circle().fill(UI.dataNow).frame(width: 5, height: 5).position(last)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    /// The line's vertical scale: the samples' range, widened to at least ±10% of their average, so the slope is
    /// honest about how big a change is. Empty or all-zero samples give an empty range (drawn flat).
    static func lineDomain(_ values: [Double]) -> ClosedRange<Double> {
        guard let lo = values.min(), let hi = values.max(), hi > 0 else { return 0...0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return min(lo, mean * 0.9)...max(hi, mean * 1.1)
    }

    private var bars: some View {
        let peak = values.max() ?? 0
        return GeometryReader { g in
            let spacing: CGFloat = 1.5
            let w = max(1, (g.size.width - spacing * CGFloat(Self.count - 1)) / CGFloat(Self.count))
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: 1)
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(0..<Self.count, id: \.self) { i in
                        let index = i - (Self.count - values.count)
                        let v = index >= 0 ? values[index] : 0
                        RoundedRectangle(cornerRadius: min(1, w / 2))
                            .fill(index == values.count - 1 ? UI.dataNow : UI.dataPast)
                            .frame(width: w, height: index >= 0 && peak > 0 ? max(2, height * v / peak) : 0)
                    }
                }
            }
            .frame(height: height, alignment: .bottom)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// What the workspace's figures are made of, busiest first.
struct ProcessList: View {
    let groups: [WorkspaceUsage.ProcessGroup]
    var shown = 6
    @State private var showAll = false

    var body: some View {
        let list = showAll ? groups : Array(groups.prefix(shown))
        Card(title: "Processes", icon: "square.stack", count: groups.reduce(0) { $0 + $1.count }) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Text("CPU").frame(width: 48, alignment: .trailing)
                    Text("Memory").frame(width: 64, alignment: .trailing)
                    Color.clear.frame(width: 22, height: 1)
                }
                .font(.system(size: UI.Size.micro, weight: .medium)).foregroundStyle(UI.textSecondary)
                .padding(.horizontal, 4).padding(.bottom, 4)
                ForEach(list) { ProcessRow(group: $0) }
                if groups.count > shown {
                    Button(showAll ? "Show fewer" : "Show \(groups.count - shown) more") { showAll.toggle() }
                        .buttonStyle(PressStyle())
                        .font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(UI.textInfo)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4).padding(.top, 4)
                }
            }
        }
    }
}

/// One process group, with "Quit…" behind a confirm that names it. Offered only where `QuitPolicy` allows: the
/// user's own processes, never the system's or Dashbar's.
struct ProcessRow: View {
    @EnvironmentObject var store: Store
    let group: WorkspaceUsage.ProcessGroup
    @State private var confirm = false
    @State private var hover = false

    static func confirmTitle(_ g: WorkspaceUsage.ProcessGroup) -> String {
        g.pids.count > 1 ? "Quit \(g.pids.count) \(g.name) processes" : "Quit \(g.name)"
    }

    var body: some View {
        let quittable = group.pids.contains(where: QuitPolicy.allows)
        HStack(spacing: 6) {
            Text(group.name).font(.system(size: UI.Size.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            if group.count > 1 {
                Text("×\(group.count)").font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary)
            }
            Spacer(minLength: 6)
            if confirm {
                ConfirmButton(title: Self.confirmTitle(group)) { store.quit(group); confirm = false }
                IconButton(symbol: "xmark", help: "Cancel") { confirm = false }
            } else {
                Text(UsageText.percent(group.cpu) + "%").frame(width: 48, alignment: .trailing)
                Text(Fmt.bytes(group.memory)).frame(width: 64, alignment: .trailing).foregroundStyle(UI.textSecondary)
                if quittable {
                    IconButton(symbol: "xmark.circle", help: "Quit \(group.name)…") { confirm = true }
                } else {
                    Color.clear.frame(width: 22, height: 22).touchTarget()   // keeps the columns lined up with the buttons
                }
            }
        }
        .font(.system(size: UI.Size.caption).monospacedDigit())
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous)
            .fill(Color.primary.opacity(hover ? UI.rowHover : 0)))
        .onHover { hover = $0 }
        .contextMenu {
            if quittable { Button("Quit \(group.name)…", role: .destructive) { confirm = true } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Quit \(group.name)") { if quittable { confirm = true } }
    }
}
