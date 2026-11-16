import SwiftUI
import AppKit

// MARK: - Building blocks

/// Card and tile surface. Depth comes from fill (and a soft shadow in light mode), not a border;
/// only the selected state draws an outline.
struct Surface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var selected = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: UI.cardRadius, style: .continuous)
        let light = scheme == .light
        content
            .background(shape.fill(light ? Color.white.opacity(selected ? 0.95 : 0.62)
                                         : Color.white.opacity(selected ? 0.10 : 0.055)))
            .overlay { if selected { shape.strokeBorder(Color.primary.opacity(0.14)) } }
            .shadow(color: .black.opacity(light ? 0.05 : 0), radius: 1, y: 0.5)
            .shadow(color: .black.opacity(light ? (selected ? 0.08 : 0.04) : 0), radius: 8, y: 3)
    }
}

extension View {
    func surface(selected: Bool = false) -> some View { modifier(Surface(selected: selected)) }
}

/// Search and filter fields: a Liquid Glass capsule on macOS 26 and later, like the system's own fields there;
/// before that, the quiet rounded fill the panel always had.
struct SearchFieldSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(RoundedRectangle(cornerRadius: UI.fieldRadius, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
    }
}

/// Groups glass controls that sit together (macOS 26 and later), so they render as one layer and blend where they meet.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Presses scale to 0.96 over 150ms; under Reduce Motion they dim instead. Disabled buttons never react.
struct PressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
            .opacity(pressed && reduceMotion ? 0.7 : 1)
            .animation(.easeOut(duration: 0.15), value: pressed)
            .modifier(KeyboardFocusRing())
    }
}

/// A ring in the system's focus colour while a hand-styled button holds keyboard focus (Keyboard navigation on in
/// System Settings), so someone moving with Tab can see where they are. Buttons only take focus that way, so a mouse
/// user never sees it.
private struct KeyboardFocusRing: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    func body(content: Content) -> some View {
        content.overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2)
                    .padding(-2)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    var icon: String? = nil
    var tint: Color = .secondary
    var count: Int?
    var trailing: String?
    /// A small view at the right of the title row, after `trailing` (the plan limits card's pace key).
    var accessory: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                if let icon { IconChip(symbol: icon, tint: tint) }
                Text(title).font(.system(size: UI.Size.body, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)   // VoiceOver's headings rotor jumps between cards
                if let count, count > 0 { Text("\(count)").font(.system(size: UI.Size.body).monospacedDigit()).foregroundStyle(UI.textSecondary) }
                Spacer()
                if let trailing {
                    Text(trailing).font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary)
                }
                if let accessory { accessory }
            }
            content
        }
        .padding(UI.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }
}

/// The symbol leading a card's title. Plain, in secondary ink; only the agents' own symbols (Claude's asterisk, Codex's
/// brackets, Google's sparkle, opencode's square) keep their colour, because there it names the agent.
struct IconChip: View {
    let symbol: String
    let tint: Color
    private var namesAnAgent: Bool { symbol == "asterisk" || symbol.hasPrefix("chevron.left.forwardslash") || symbol == UI.googleSymbol || symbol == UI.openCodeSymbol }
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: UI.Size.body, weight: .semibold))
            .foregroundStyle(namesAnAgent ? tint : UI.textSecondary)
            // Flush with the card's content edge, so it lines up with the icons and text below it. A fixed
            // width keeps every card's title starting at the same place whatever the symbol's width.
            .frame(width: 16, height: 22, alignment: .leading)
            .accessibilityHidden(true)
    }
}

/// A project's tile: its own icon when one is found in the folder, otherwise its first letter on a quiet
/// neutral tile. Colour is left for state, so the only thing that lights up is a working agent's dot.
struct Monogram: View {
    let name: String
    var root: String? = nil
    let active: Bool
    /// An agent here is waiting for you: the dot turns amber.
    var waiting = false
    var size: CGFloat = 28
    @State private var icon: NSImage?

    var body: some View {
        let dot = size * 0.3
        let radius = size * 0.26
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high).scaledToFill()
                        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.primary.opacity(0.09))
                        .overlay(Text(String(name.first.map { String($0).uppercased() } ?? "?"))
                            .font(.system(size: size * 0.46, weight: .semibold, design: .rounded)).foregroundStyle(UI.textSecondary))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            if active || waiting {
                // Punch a ring out of the tile so the dot reads cleanly on any surface.
                Circle().frame(width: dot + 3, height: dot + 3).offset(x: 2.5, y: 2.5).blendMode(.destinationOut)
            }
        }
        .compositingGroup()
        .overlay(alignment: .bottomTrailing) {
            if active || waiting {
                Circle().fill(waiting ? UI.attention : Color.green).frame(width: dot, height: dot).offset(x: 1, y: 1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: root) {
            guard let root else { return }
            if let hit = ProjectIcon.cached(for: root) { icon = hit; return }
            icon = await Task.detached(priority: .utility) { ProjectIcon.find(in: root) }.value
        }
    }
}

struct StatusDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let active: Bool
    /// Waiting for you: a steady amber dot. Working pulses green; waiting holds still until someone acts.
    var waiting = false
    var size: CGFloat = 7
    @State private var pulse = false

    var body: some View {
        ZStack {
            if active {
                if reduceMotion {
                    // Static halo: same cue, no motion.
                    Circle().fill(Color.green.opacity(0.25)).frame(width: size * 1.8, height: size * 1.8)
                } else {
                    // Scoped animation: only scale and opacity loop, so the halo can never drift with
                    // layout (the bug with a plain repeatForever), and it renders without re-laying out
                    // the panel each frame (the cost of a TimelineView clock).
                    Circle().fill(Color.green.opacity(0.35))
                        .frame(width: size * 2, height: size * 2)
                        .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { content in
                            content
                                .scaleEffect(pulse ? 1 : 0.4)
                                .opacity(pulse ? 0 : 1)
                        }
                }
            }
            if waiting {
                Circle().fill(UI.attention.opacity(0.25)).frame(width: size * 1.8, height: size * 1.8)
            }
            Circle().fill(waiting ? UI.attention : active ? Color.green : Color.secondary.opacity(0.5)).frame(width: size, height: size)
        }
        .frame(width: size * 2, height: size * 2)
        .accessibilityHidden(true)
        .onAppear { pulse = true }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: UI.Size.body, weight: .medium))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous)
                    .fill(Color.primary.opacity(hover ? UI.buttonHover : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(UI.textSecondary)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Inline confirmation for a destructive action: a tinted pill in the danger colour,
/// matching the panel's own buttons rather than a stock AppKit push button.
struct ConfirmButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: UI.Size.caption, weight: .semibold))
                .foregroundStyle(UI.textDanger)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous)
                    .fill(UI.textDanger.opacity(hover ? 0.2 : 0.12)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .fixedSize()
    }
}

struct NoticeBanner: View {
    let text: String
    let dismiss: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(UI.textDanger).accessibilityHidden(true)
            Text(text).font(.system(size: UI.Size.caption)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let dismiss { IconButton(symbol: "xmark", help: "Dismiss message", action: dismiss) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
        .accessibilityElement(children: .contain)
    }
}

struct EmptyRow: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Other AI tools running on this Mac whose sessions Dashbar doesn't list by workspace (Codex, Cursor, Ollama…). No
/// status dot: they aren't known to be working, and green means a working agent.
struct AgentChips: View {
    let items: [String]
    var body: some View {
        HStack(spacing: 5) {
            Text("Other AI tools running").font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
            ForEach(items, id: \.self) { item in
                Text(item).font(.system(size: UI.Size.caption))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
        .help("Running on this Mac. Dashbar doesn't list their sessions by workspace.")
    }

    /// The chips: each running tool ("Codex ×2" for several copies), leaving out an app that already hosts a listed
    /// session (T3 Code, when a Claude Code session above runs in it), since that row already names it.
    static func items(_ agents: [AgentProcess], hosts: Set<String>) -> [String] {
        agents.filter { a in !hosts.contains(a.name) && !hosts.contains { a.name == $0 + " app" } }
            .map { $0.count > 1 ? "\($0.name) ×\($0.count)" : $0.name }
    }

    @MainActor static func items(_ agents: [AgentProcess], sessions: [LiveSession]) -> [String] {
        guard !agents.isEmpty else { return [] }
        return items(agents, hosts: Set(sessions.compactMap { HostApp.info(for: $0)?.name }))
    }
}

extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

/// How long a meter's fill is drawn.
enum Meter {
    /// Nothing at all for nothing used, so a 0% meter never shows a stub that reads as "a little"; a small non-zero
    /// share keeps `minimum` so it stays visible. Clamped to the meter's length.
    static func width(_ fraction: Double, in length: CGFloat, minimum: CGFloat = 3) -> CGFloat {
        guard fraction > 0, length > 0 else { return 0 }
        return min(length, max(minimum, length * CGFloat(min(fraction, 1))))
    }
}
