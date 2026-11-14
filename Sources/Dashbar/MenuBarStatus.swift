import SwiftUI
import AppKit
import Combine

// MARK: - What the menu bar item says

/// The menu bar item's live agent status: which state wins and the text beside the mark. Pure, so it can be tested;
/// `MenuBarStatusImage` draws it and `MenuBarLabel` feeds it.
struct MenuBarStatus: Equatable {
    /// What the text beside the icon says about agents. The plan-left reading and system stats are separate toggles that
    /// follow it.
    enum TextMode: String, CaseIterable, Identifiable {
        case none, count, countTime
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: return "Nothing"
            case .count: return "Working count"
            case .countTime: return "Count and time"
            }
        }
    }

    /// Highest priority first: someone needs you, an agent just finished, agents are working, nothing is going on.
    enum State: Equatable {
        case needsYou(Int)
        case done(project: String)
        case working(Int)
        case idle
    }

    /// Colour carries meaning: only the status accent is coloured, everything else is the menu bar's own text colour.
    enum Tone: Equatable { case primary, secondary, attention, success }

    struct Piece: Equatable {
        enum Kind: Equatable { case text(String), symbol(String) }
        var kind: Kind
        var tone: Tone = .primary
        static func text(_ s: String, _ tone: Tone = .primary) -> Piece { Piece(kind: .text(s), tone: tone) }
        static func symbol(_ name: String, _ tone: Tone = .primary) -> Piece { Piece(kind: .symbol(name), tone: tone) }
    }

    /// Pieces drawn beside the mark, in groups with a wider gap between them.
    typealias Group = [Piece]

    var state: State
    var groups: [Group]
    /// The mark's bar sweeps while agents work, unless animation is off or Reduce Motion is on.
    var animates: Bool
    /// The mark's bar is full (static working cue) rather than at rest.
    var busy: Bool

    /// True when something has to be drawn in colour, so the image can't be a template.
    var isColoured: Bool { groups.joined().contains { $0.tone == .attention || $0.tone == .success } }

    /// Spoken form for VoiceOver.
    var accessibilityText: String {
        var words = [BuildInfo.appName]
        switch state {
        case .needsYou(let n): words.append("\(n) \(n == 1 ? "agent needs" : "agents need") you")
        case .done(let project): words.append("agent done in \(project)")
        case .working(let n): words.append("\(n) \(n == 1 ? "agent" : "agents") working")
        case .idle: break
        }
        return words.joined(separator: ", ")
    }

    /// How long a finished agent's "Done" stays in the menu bar.
    static let doneDuration: TimeInterval = 5
    /// Longer project names are cut short, so "Done" never makes the item wide.
    static let projectLimit = 16

    /// - Parameters:
    ///   - busySince: when each working agent started its current stretch of work.
    ///   - waiting: agents stopped for permission or an answer.
    ///   - finished: the project of an agent that finished within the last few seconds, if "Done" is on.
    ///   - extras: the stats the user turned on (plan left, CPU…), each its own group.
    static func make(busySince: [Date], waiting: Int, finished: String?, mode: TextMode,
                     animate: Bool, extras: [Group] = [], now: Date = Date()) -> MenuBarStatus {
        let busy = busySince.count
        let state: State
        if waiting > 0 { state = .needsYou(waiting) }
        else if let finished { state = .done(project: finished) }
        else if busy > 0 { state = .working(busy) }
        else { state = .idle }

        var groups: [Group] = []
        switch state {
        case .needsYou(let n):
            // Shown whatever the text setting: it's the one thing that can't wait.
            groups.append([.symbol("hand.raised.fill", .attention), .text("\(n)", .attention)])
        case .done(let project):
            groups.append([.text("Done", .success), .text(" · \(shortProject(project))", .secondary)])
        case .working(let n):
            switch mode {
            case .none: break
            case .count: groups.append([.text("\(n)")])
            case .countTime:
                let longest = busySince.min().map { now.timeIntervalSince($0) } ?? 0
                groups.append([.text("\(n)"), .text(" · \(elapsed(longest))", .secondary)])
            }
        case .idle: break
        }
        groups += extras
        // Needing you outranks working: the mark holds still so the amber is the one thing that moves the eye.
        let moving: Bool
        if case .needsYou = state { moving = false } else { moving = animate && busy > 0 }
        return MenuBarStatus(state: state, groups: groups, animates: moving, busy: busy > 0)
    }

    /// "<1m", "14m", "1h 5m", "2d 3h": short enough for the menu bar.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        switch s {
        case ..<60: return "<1m"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return s % 3600 / 60 == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(s % 3600 / 60)m"
        default: return "\(s / 86400)d \(s % 86400 / 3600)h"
        }
    }

    static func shortProject(_ name: String) -> String {
        name.count <= projectLimit ? name : String(name.prefix(projectLimit - 1)) + "…"
    }

    /// Frames a second while the bar sweeps.
    static let fps: Double = 8
    /// The sweep: the bar fills from low to full over this many frames (one second), easing out.
    static let sweepFrames = 8
    /// Then it holds full, the static "working" cue, for this many frames (four seconds) before the next sweep.
    /// Every change of the image costs the menu bar a redraw on each display, so the bar rests most of the time.
    static let holdFrames = 32

    /// The bar's fill at tick `tick` of the working animation.
    static func sweep(tick: Int) -> CGFloat {
        let i = tick % (sweepFrames + holdFrames)
        guard i < sweepFrames else { return 1 }
        let t = Double(i) / Double(sweepFrames - 1)
        let eased = 1 - pow(1 - t, 3)   // ease out: quick start, gentle arrival
        return CGFloat(0.3 + 0.7 * eased)
    }
}

// MARK: - Drawing

/// Draws the whole menu bar item (mark and text) as one image. When nothing is coloured it is a template image, so the
/// system tints it exactly like any other menu bar item (light, dark, highlighted, dimmed on an inactive display). When
/// the status needs an accent (amber, green) it is drawn in colour, with the plain parts in the menu bar's own text
/// colour, resolved at draw time from the appearance AppKit draws the status item with.
enum MenuBarStatusImage {
    static let height: CGFloat = 18
    static var font: NSFont { NSFont.menuBarFont(ofSize: 0) }

    /// The images drawn for the current status, by frame, so a sweep's later loops reuse the images (and the drawings
    /// AppKit caches for them) instead of drawing every frame again.
    @MainActor private static var memo: (status: MenuBarStatus, images: [Int: NSImage])?

    /// `image(_:fill:)`, remembered while the status stays the same.
    @MainActor static func cachedImage(_ status: MenuBarStatus, fill: CGFloat?) -> NSImage {
        let key = fill.map { Int(($0 * 1000).rounded()) } ?? -1
        if memo?.status != status { memo = (status, [:]) }
        if let image = memo?.images[key] { return image }
        let image = image(status, fill: fill)
        memo?.images[key] = image
        return image
    }

    /// - Parameter fill: the mark bar's fill (0…1); nil is at rest or full, from the status.
    static func image(_ status: MenuBarStatus, fill: CGFloat? = nil) -> NSImage {
        let template = !status.isColoured
        let barFill = fill ?? (status.busy ? 1 : 0.45)
        let font = self.font
        let pieces = layout(status.groups, font: font)
        let width = ceil(BrandMark.menuBarSize + (pieces.isEmpty ? 0 : 4 + (pieces.last.map { $0.x + $0.width } ?? 0)))
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let palette = Palette(template: template)
            BrandMark.drawMenuBarMark(at: NSPoint(x: 0, y: 0), fill: barFill, colour: palette.primary)
            let baseline = (height - (font.ascender - font.descender)) / 2 - font.descender
            for p in pieces {
                let colour = palette.colour(p.piece.tone)
                let x = BrandMark.menuBarSize + 4 + p.x
                switch p.piece.kind {
                case .text(let s):
                    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: colour])
                        .draw(at: NSPoint(x: x, y: baseline + font.descender))
                case .symbol(let name):
                    guard let symbol = symbolImage(name, colour: colour, font: font) else { continue }
                    let mid = baseline + font.capHeight / 2
                    symbol.draw(in: NSRect(x: x, y: mid - symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height))
                }
            }
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = status.accessibilityText
        return image
    }

    private struct Placed { let piece: MenuBarStatus.Piece; let x: CGFloat; let width: CGFloat }

    private static func layout(_ groups: [MenuBarStatus.Group], font: NSFont) -> [Placed] {
        var out: [Placed] = []
        var x: CGFloat = 0
        for (gi, group) in groups.enumerated() {
            if gi > 0 { x += 8 }
            for (pi, piece) in group.enumerated() {
                let w: CGFloat
                switch piece.kind {
                case .text(let s): w = ceil(NSAttributedString(string: s, attributes: [.font: font]).size().width)
                case .symbol(let name): w = symbolImage(name, colour: .black, font: font)?.size.width ?? 0
                }
                out.append(Placed(piece: piece, x: x, width: w))
                x += w
                if case .symbol = piece.kind, pi < group.count - 1 { x += 3 }
            }
        }
        return out
    }

    private static func symbolImage(_ name: String, colour: NSColor, font: NSFont) -> NSImage? {
        // Asked for on every draw, so keep the configured symbols.
        let key = "\(name) \(colour.description) \(font.pointSize)" as NSString
        if let hit = symbols.object(forKey: key) { return hit }
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize - 1, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [colour]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        if let image { symbols.setObject(image, forKey: key) }
        return image
    }
    nonisolated(unsafe) private static let symbols = NSCache<NSString, NSImage>()

    /// Colours for the appearance being drawn into. Template images are drawn black and tinted by the system.
    private struct Palette {
        let template: Bool
        let dark: Bool

        init(template: Bool) {
            self.template = template
            dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }

        /// Solid, like the system's tint of a template image, so the mark looks the same in both kinds of image.
        var primary: NSColor { template ? .black : dark ? .white : .black }

        func colour(_ tone: MenuBarStatus.Tone) -> NSColor {
            switch tone {
            case .primary: return primary
            case .secondary: return primary.withAlphaComponent(0.55)
            // The app's amber and a green that reads on a translucent menu bar: darker on a light one.
            case .attention: return dark ? NSColor(srgbRed: 0.89, green: 0.70, blue: 0.25, alpha: 1)
                                         : NSColor(srgbRed: 0.60, green: 0.40, blue: 0.0, alpha: 1)
            case .success: return dark ? NSColor(srgbRed: 0.25, green: 0.78, blue: 0.36, alpha: 1)
                                       : NSColor(srgbRed: 0.10, green: 0.50, blue: 0.22, alpha: 1)
            }
        }
    }
}

// MARK: - Live label

/// Drives the working animation and the transient "Done". The animation timer runs only while agents are working with
/// animation on and Reduce Motion off, and publishes only when the bar's fill changes (8 times in each 5-second cycle);
/// otherwise nothing ticks, except a 30-second clock while the text shows the elapsed time.
@MainActor
final class MenuBarAnimator: ObservableObject {
    /// The bar's fill, while sweeping.
    @Published private(set) var fill: CGFloat = 1
    private var tick = 0
    @Published private(set) var finished: String?
    @Published private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var doneClear: DispatchWorkItem?
    private var subscriptions = Set<AnyCancellable>()

    init(store: Store) {
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
            }
            .store(in: &subscriptions)
        store.islandEvents
            .receive(on: RunLoop.main)
            .sink { [weak self, weak store] event in
                guard case .finished = event.kind, AppSettings.shared.menuDone,
                      let project = store?.sessions.first(where: { $0.id == event.sessionID })?.project else { return }
                self?.showDone(project)
            }
            .store(in: &subscriptions)
    }

    func showDone(_ project: String, for duration: TimeInterval = MenuBarStatus.doneDuration) {
        finished = project
        doneClear?.cancel()
        let clear = DispatchWorkItem { [weak self] in self?.finished = nil }
        doneClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: clear)
    }

    /// Starts, slows or stops the timer to suit what is shown. Called whenever the label redraws.
    func update(animating: Bool, clock: Bool) {
        let interval: TimeInterval = animating ? 1 / MenuBarStatus.fps : clock ? 30 : 0
        guard interval != timerInterval else { return }
        timer?.invalidate()
        timer = nil
        timerInterval = interval
        guard interval > 0 else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if animating {
                    self.tick += 1
                    let fill = MenuBarStatus.sweep(tick: self.tick)
                    if fill != self.fill { self.fill = fill }
                } else {
                    self.objectWillChange.send()   // the elapsed time moved on
                }
            }
        }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: Store
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var animator: MenuBarAnimator

    init(store: Store) {
        self.store = store
        _animator = StateObject(wrappedValue: MenuBarAnimator(store: store))
    }

    var body: some View {
        let status = Self.status(store: store, settings: settings, finished: animator.finished,
                                 animate: settings.menuAnimate && !animator.reduceMotion)
        let fill = status.animates ? animator.fill : nil
        Image(nsImage: MenuBarStatusImage.cachedImage(status, fill: fill))
            .accessibilityLabel(status.accessibilityText)
            .onAppear { syncTimer(status) }
            .onChange(of: status.animates) { _, _ in syncTimer(status) }
            .onChange(of: needsClock(status)) { _, _ in syncTimer(status) }
    }

    private func needsClock(_ status: MenuBarStatus) -> Bool {
        if case .working = status.state { return settings.menuText == .countTime }
        return false
    }

    private func syncTimer(_ status: MenuBarStatus) {
        animator.update(animating: status.animates, clock: needsClock(status))
    }

    /// Everything the label shows, from the store and settings.
    static func status(store: Store, settings: AppSettings, finished: String?, animate: Bool, now: Date = Date()) -> MenuBarStatus {
        let busy = store.sessions.filter(\.isBusy).map(\.since)
        return MenuBarStatus.make(busySince: busy, waiting: store.waitingCount, finished: finished, mode: settings.menuText,
                                  animate: animate, extras: extras(store: store, settings: settings), now: now)
    }

    /// The stats the user turned on, each led by its symbol.
    private static func extras(store: Store, settings: AppSettings) -> [MenuBarStatus.Group] {
        let s = store.system
        var groups: [MenuBarStatus.Group] = []
        if settings.menuCPU { groups.append([.symbol("cpu"), .text("\(Int((s.cpu * 100).rounded()))%")]) }
        if settings.menuMemory {
            let used = Int((Double(s.memUsed) / Double(max(s.memTotal, 1)) * 100).rounded())
            groups.append([.symbol("memorychip"), .text("\(used)%")])
        }
        if settings.menuNetwork { groups.append([.symbol("arrow.down"), .text(Fmt.shortRate(s.netDown))]) }
        if settings.menuLimit, settings.showsClaudeLimits, store.claudePlan?.problem == nil,
           let r = ClaudePlanLimits.menuBarReading(store.claudePlan?.limits ?? []) {
            groups.append([.symbol(r.atRisk ? "exclamationmark.triangle.fill" : "gauge.with.needle"),
                           .text("\(r.name) \(r.leftPercent)% left")])
        }
        return groups
    }
}
