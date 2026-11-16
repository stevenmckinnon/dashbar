import SwiftUI
import AppKit
import DashbarStatus
import DashbarWidgetUI

/// `Dashbar --snapshot out.png [--dark]` renders the dashboard with live data to a PNG and exits.
/// Handy for README screenshots and visual checks without clicking the menu bar.
@MainActor
enum Snapshot {
    static var store: Store?

    /// `DASHBAR_SNAPSHOT_SCALE=4` renders the offline panel and the island at more pixels per point than the default 2,
    /// so they stay sharp when a video scales them up. (`--hosted` can't: the live view rasterises at the screen's scale.)
    static var scale: CGFloat? {
        Double(ProcessInfo.processInfo.environment["DASHBAR_SNAPSHOT_SCALE"] ?? "").map { CGFloat($0) }
    }

    static func schedule(to path: String) {
        if let tab = ProcessInfo.processInfo.environment["DASHBAR_TAB"] {
            UserDefaults.standard.set(tab, forKey: "panelTab")
        }
        let island = CommandLine.arguments.firstIndex(of: "--island").flatMap { CommandLine.arguments.dropFirst($0 + 1).first }
        if island == "permission" { setenv("DASHBAR_DEMO_PERMISSION", "1", 1) }
        if island == "needsyou" { setenv("DASHBAR_DEMO_WAITING", "1", 1) }
        let menubar = CommandLine.arguments.firstIndex(of: "--menubar").flatMap { CommandLine.arguments.dropFirst($0 + 1).first }
        if menubar == "needsyou" { setenv("DASHBAR_DEMO_WAITING", "1", 1) }
        let demo = CommandLine.arguments.contains("--demo")
        let store = Store(demo: demo)
        self.store = store
        if !demo { store.setPanelVisible(true) }   // offline renders never get the window's visibility callback
        let dark = CommandLine.arguments.contains("--dark")
        let delay = Double(ProcessInfo.processInfo.environment["DASHBAR_SNAPSHOT_DELAY"] ?? "") ?? 10
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if CommandLine.arguments.contains("--cli") {
                // The `dashbar` command's status file, written to `path` instead of the app's own (`CLIStatus`).
                let snapshot = CLIStatus.snapshot(of: store, showsClaudeLimits: demo || AppSettings.shared.showsClaudeLimits)
                let data = (try? StatusSnapshot.encoder().encode(snapshot)) ?? Data()
                try? data.write(to: URL(fileURLWithPath: path))
                exit(0)
            }
            if let flag = CommandLine.arguments.firstIndex(of: "--widget") {
                // A desktop widget from the demo data, drawn by the same views the extension uses.
                let size = CommandLine.arguments.dropFirst(flag + 1).first.flatMap(DashbarWidgetSize.init(rawValue:)) ?? .small
                WidgetSnapshot.render(size, store: store, dark: dark, to: path)
                exit(0)
            }
            if CommandLine.arguments.contains("--glyphs") {
                // Menu bar glyph at its real size on light and dark menu bars, idle and working, at 4x for inspection.
                let scale: CGFloat = 4, w: CGFloat = 220, h: CGFloat = 24
                let out = NSImage(size: NSSize(width: w * scale, height: h * 2 * scale + 120 * scale))
                out.lockFocus()
                NSGraphicsContext.current?.imageInterpolation = .none
                for (row, dark) in [(0, false), (1, true)] {
                    let y = CGFloat(row) * h * scale + 120 * scale
                    (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                    NSRect(x: 0, y: y, width: w * scale, height: h * scale).fill()
                    for (i, working) in [false, true].enumerated() {
                        let glyph = BrandMark.menuBarImage(working: working)
                        let tinted = NSImage(size: glyph.size, flipped: false) { r in
                            glyph.draw(in: r)
                            (dark ? NSColor.white : NSColor.black).set()
                            r.fill(using: .sourceAtop)
                            return true
                        }
                        tinted.draw(in: NSRect(x: (20 + CGFloat(i) * 60) * scale, y: y + 3 * scale, width: 18 * scale, height: 18 * scale))
                        if working {
                            let text = NSAttributedString(string: "2", attributes: [.font: NSFont.menuBarFont(ofSize: 13 * scale),
                                                                                    .foregroundColor: dark ? NSColor.white : NSColor.black])
                            text.draw(at: NSPoint(x: (20 + 60 + 21) * scale, y: y + 4 * scale))
                        }
                    }
                }
                out.unlockFocus()
                let mark = ImageRenderer(content: HStack(spacing: 30) { BrandMarkView(size: 18); BrandMarkView(size: 64) }
                    .padding(20).background(Color(white: 0.12)))
                mark.scale = scale
                let composed = NSImage(size: out.size)
                composed.lockFocus()
                out.draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
                mark.nsImage?.draw(at: NSPoint(x: 0, y: 0), from: .zero, operation: .sourceOver, fraction: 1)
                composed.unlockFocus()
                if let tiff = composed.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
                exit(0)
            }
            if let island {
                IslandSnapshot.render(island, store: store, dark: dark, to: path)
                return
            }
            if let menubar {
                MenuBarSnapshot.render(menubar, store: store, dark: dark, to: path)
                return
            }
            if let flag = CommandLine.arguments.firstIndex(of: "--settings") {
                // A Settings tab, laid out by AppKit so native controls draw. `--settings integrations` picks the tab (general,
                // notifications, menuBar, folders, accounts, integrations, about) at the window's opening height, or
                // DASHBAR_SETTINGS_HEIGHT; without one it is the whole window, which offline shows General.
                let next = CommandLine.arguments.dropFirst(flag + 1).first
                let height = ProcessInfo.processInfo.environment["DASHBAR_SETTINGS_HEIGHT"].flatMap(Double.init).map { CGFloat($0) }
                let root: AnyView = next.flatMap(SettingsTab.init(name:)).map { AnyView(SettingsView.page($0, height: height)) } ?? AnyView(SettingsView())
                let host = NSHostingView(rootView: root.environment(\.colorScheme, dark ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 480, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                host.frame.size = host.fittingSize
                window.setContentSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                    exit(0)
                }
                return
            }
            if CommandLine.arguments.contains("--onboarding") {
                // The first-run window with its title bar, laid out by AppKit so native controls draw.
                let window = OnboardingWindow.makeWindow(OnboardingView(snapshot: true) {})
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.setFrameOrigin(NSPoint(x: -3000, y: -3000))   // drawn off screen
                window.orderFrontRegardless()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard let frameView = window.contentView?.superview else { exit(1) }
                    if let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                        frameView.cacheDisplay(in: frameView.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                    exit(0)
                }
                return
            }
            if CommandLine.arguments.contains("--onscreen"), !CommandLine.arguments.contains("--app") {
                // The panel in a real window for 8 seconds, for `screencapture -l` to catch what only the window server
                // draws (Liquid Glass). Prints the window number.
                let host = NSHostingView(rootView: DashboardView(scrolls: false).environmentObject(store)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light))
                let window = NSWindow(contentRect: .init(origin: .zero, size: host.fittingSize), styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                window.center()
                window.level = .floating
                window.orderFrontRegardless()
                print("window", window.windowNumber)
                fflush(stdout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { exit(0) }
                return
            }
            if CommandLine.arguments.contains("--app") {
                // The Dashbar window at 1100×760, laid out by AppKit so the sidebar list draws.
                // DASHBAR_APP_PAGE picks the page: a tab ("agents") or a workspace's name.
                let name = ProcessInfo.processInfo.environment["DASHBAR_APP_PAGE"] ?? "overview"
                let page: AppPage = name == "history" ? .history : PanelTab(rawValue: name).map { .tab($0) }
                    ?? .workspace(store.workspaces.first { $0.name == name }?.root ?? name)
                // Hosted the way AppWindow hosts it (a hosting controller), so the window chrome matches the app's.
                let controller = NSHostingController(rootView: AppView(model: AppWindowModel(page: page), snapshot: true)
                    .environmentObject(store).environment(\.colorScheme, dark ? .dark : .light))
                controller.sizingOptions = []
                let window = NSWindow(contentViewController: controller)
                window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                // DASHBAR_APP_HEIGHT renders a taller window, to see a long page whole.
                let height = Double(ProcessInfo.processInfo.environment["DASHBAR_APP_HEIGHT"] ?? "") ?? 760
                window.setContentSize(NSSize(width: 1100, height: height))
                let host = controller.view
                if CommandLine.arguments.contains("--onscreen") {
                    // On screen and active for 8 seconds, for `screencapture -l` to catch what only the window server
                    // draws (Liquid Glass, the window buttons' colour). Prints the window number.
                    NSApp.setActivationPolicy(.regular)
                    window.center()
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(nil)
                    NSApp.activate()
                    print("window", window.windowNumber)
                    fflush(stdout)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { exit(0) }
                    return
                }
                window.setFrameOrigin(NSPoint(x: -3000, y: -3000))   // drawn off screen
                window.orderFrontRegardless()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard let frameView = host.superview else { exit(1) }
                    if let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                        frameView.cacheDisplay(in: frameView.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                    exit(0)
                }
                return
            }
            if CommandLine.arguments.contains("--hosted") {
                // Lay out the real scrolling panel the way MenuBarExtra does: at its fitting size.
                let host = NSHostingView(rootView: DashboardView().environmentObject(store)
                    .background(dark ? Color(white: 0.14) : Color(white: 0.97))
                    .environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame.size = host.fittingSize
                host.layoutSubtreeIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    host.frame.size = host.fittingSize
                    host.layoutSubtreeIfNeeded()
                    print("fitting size:", host.fittingSize)
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                    exit(0)
                }
                return
            }
            let forced = ProcessInfo.processInfo.environment["DASHBAR_TAB"].flatMap(PanelTab.init(rawValue:))
            let view = DashboardView(scrolls: false, forcedTab: forced)
                .environmentObject(store)
                .background(dark ? Color(white: 0.12) : Color(white: 0.97))
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = scale ?? 2
            if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }
}

/// `--island collapsed|needsyou|finished|permission|list`: the island over a made-up top of the screen (menu bar,
/// notch, wallpaper; `--dark` for a dark one). `DASHBAR_ISLAND_STYLE=floating|left|right` draws it as on a screen
/// without a notch or beside it. With `--onscreen`, the real panel at the real notch for 8 seconds instead.
@MainActor
enum IslandSnapshot {
    static func mode(_ name: String, store: Store) -> IslandMode {
        let now = Date()
        switch name {
        case "finished":
            return .banner(IslandBanner(kind: .finished(after: 12 * 60 + 20), sessionID: "s3", shownAt: now))
        case "permission":
            let id = store.permissionRequests.first?.id ?? ""
            return .banner(IslandBanner(kind: .permission(requestID: id), sessionID: "s2", shownAt: now))
        case "waiting":
            return .banner(IslandBanner(kind: .waiting, sessionID: "s2", shownAt: now))
        case "list":
            return .list
        default:
            return .collapsed(IslandStatus.of(sessions: store.sessions, permissionRequests: store.permissionRequests))
        }
    }

    static func render(_ name: String, store: Store, dark: Bool, to path: String) {
        if name == "live" {
            IslandController.shared.startDemo(store: store)
            print("window", IslandController.shared.panelWindowNumber)
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { exit(0) }
            return
        }
        let mode = mode(name, store: store)
        if CommandLine.arguments.contains("--onscreen") {
            IslandController.shared.showPinned(store: store, mode: mode)
            print("window", IslandController.shared.panelWindowNumber)
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { exit(0) }
            return
        }
        let notch = CGSize(width: 185, height: 32)
        let style: IslandStyle
        switch ProcessInfo.processInfo.environment["DASHBAR_ISLAND_STYLE"] {
        case "floating": style = .floating
        case "left": style = .beside(leading: true, height: notch.height)
        case "right": style = .beside(leading: false, height: notch.height)
        default: style = .notch(width: notch.width, height: notch.height)
        }
        let scene = IslandScene(mode: mode, style: style, dark: dark, notch: notch).environmentObject(store)
        let renderer = ImageRenderer(content: scene)
        renderer.scale = Snapshot.scale ?? 2
        if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        exit(0)
    }
}

/// A made-up top of a MacBook screen for island renders: wallpaper, menu bar, the notch, and the island on it.
private struct IslandScene: View {
    let mode: IslandMode
    let style: IslandStyle
    let dark: Bool
    let notch: CGSize
    /// `DASHBAR_ISLAND_HEIGHT=900` for a tall list (with `DASHBAR_DEMO_WORST=1`), which 320 would crop.
    let size = CGSize(width: 960, height: ProcessInfo.processInfo.environment["DASHBAR_ISLAND_HEIGHT"].flatMap(Double.init) ?? 320)

    var body: some View {
        let ink: Color = dark ? .white : .black
        ZStack(alignment: .top) {
            (dark ? Color(red: 0.11, green: 0.13, blue: 0.18) : Color(red: 0.80, green: 0.85, blue: 0.91))
            HStack(spacing: 18) {
                Image(systemName: "apple.logo").font(.system(size: 14))
                Text("Finder").fontWeight(.bold)
                Text("File"); Text("Edit"); Text("View"); Text("Go"); Text("Window")
                Spacer()
                Image(systemName: "wifi"); Image(systemName: "battery.75percent")
                Text("Sat 14 Nov  9:41")
            }
            .font(.system(size: 13))
            .foregroundStyle(ink.opacity(0.85))
            .padding(.horizontal, 18)
            .frame(height: notch.height)
            .background(dark ? Color.black.opacity(0.35) : Color.white.opacity(0.5))
            if case .floating = style {} else {
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9, style: .continuous)
                    .fill(.black).frame(width: notch.width, height: notch.height)
            }
            island
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    @ViewBuilder private var island: some View {
        let content = IslandContent(mode: mode, style: style)
        switch style {
        case .notch:
            content
        case .floating:
            content.padding(.top, notch.height + IslandPlacement.floatingGap)
        case .beside(let leading, _):
            HStack(alignment: .top, spacing: 0) {
                if leading {
                    Spacer(minLength: 0)
                    content
                    Color.clear.frame(width: (size.width + notch.width) / 2, height: 1)
                } else {
                    Color.clear.frame(width: (size.width + notch.width) / 2, height: 1)
                    content
                    Spacer(minLength: 0)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// `--menubar idle|working|needsyou|done|time|all`: the menu bar item on a made-up menu bar strip (`--dark` for a dark
/// one), at 3x. `working` shows the mark at three points of its sweep; `all` is every state, light and dark, in one sheet.
/// With `--onscreen`, the state in a real status item for 8 seconds (animating while working), for `screencapture -R`.
@MainActor
enum MenuBarSnapshot {
    static func status(_ name: String, store: Store, now: Date = Date()) -> MenuBarStatus {
        let settings = AppSettings.shared
        let busy = name == "idle" ? [] : store.sessions.filter(\.isBusy).map(\.since) + [now.addingTimeInterval(-160)]
        return MenuBarStatus.make(busySince: busy, waiting: name == "needsyou" ? max(store.waitingCount, 1) : 0,
                                  finished: name == "done" ? "storefront-web" : nil,
                                  mode: name == "time" ? .countTime : settings.menuText, animate: true, now: now)
    }

    static func render(_ name: String, store: Store, dark: Bool, to path: String) {
        if CommandLine.arguments.contains("--onscreen") { live(name, store: store); return }
        let rows: [(String, Bool)]
        if name == "all" {
            rows = ["idle", "working", "needsyou", "done", "time"].flatMap { [($0, false), ($0, true)] }
        } else {
            rows = [(name, dark)]
        }
        let scale: CGFloat = 3, w: CGFloat = 300, h: CGFloat = 24
        let out = NSImage(size: NSSize(width: w * scale, height: h * CGFloat(rows.count) * scale))
        out.lockFocus()
        for (i, row) in rows.enumerated() {
            let y = out.size.height - CGFloat(i + 1) * h * scale
            // Roughly macOS's menu bar over a neutral wallpaper.
            (row.1 ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.90, alpha: 1)).setFill()
            NSRect(x: 0, y: y, width: w * scale, height: h * scale).fill()
            let status = status(row.0, store: store)
            let fills: [CGFloat?] = row.0 == "working" ? [0.3, 0.65, 1] : [nil]
            var x: CGFloat = 12
            for fill in fills {
                let image = draw(MenuBarStatusImage.image(status, fill: fill), dark: row.1)
                image.draw(in: NSRect(x: x * scale, y: y + (h - image.size.height) / 2 * scale,
                                      width: image.size.width * scale, height: image.size.height * scale))
                x += image.size.width + 24
            }
        }
        out.unlockFocus()
        if let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        exit(0)
    }

    /// The item as the menu bar would draw it: template images tinted with the menu bar's text colour, coloured ones
    /// drawn as they are, both resolved for a light or dark menu bar. At 3x, so it stays sharp when scaled up.
    private static func draw(_ image: NSImage, dark: Bool) -> NSImage {
        let appearance = NSAppearance(named: dark ? .vibrantDark : .vibrantLight) ?? NSAppearance.currentDrawing()
        let size = image.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 3), pixelsHigh: Int(size.height * 3),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            if image.isTemplate {
                // The system draws a template's alpha in the menu bar's text colour.
                let tinted = NSImage(size: size, flipped: false) { r in
                    image.draw(in: r)
                    (dark ? NSColor.white : NSColor.black).set()
                    r.fill(using: .sourceIn)
                    return true
                }
                tinted.draw(in: NSRect(origin: .zero, size: size))
            } else {
                image.draw(in: NSRect(origin: .zero, size: size))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: size)
        out.addRepresentation(rep)
        return out
    }

    /// A real status item showing the state for 8 seconds, animating while working. Prints its frame in screen
    /// coordinates (top-left origin, for `screencapture -R`).
    private static func live(_ name: String, store: Store) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        var frame = 0
        func tick() {
            let status = status(name, store: store)
            let fill = status.animates ? MenuBarStatus.sweep(tick: frame) : nil
            let image = MenuBarStatusImage.cachedImage(status, fill: fill)
            if item.button?.image !== image { item.button?.image = image }
            frame += 1
        }
        tick()
        if status(name, store: store).animates {
            let timer = Timer(timeInterval: 1 / MenuBarStatus.fps, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
            RunLoop.main.add(timer, forMode: .common)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if let window = item.button?.window, let screen = window.screen ?? NSScreen.main {
                let f = window.frame
                print("item", Int(f.minX), Int(screen.frame.maxY - f.maxY), Int(f.width), Int(f.height))
                fflush(stdout)
            }
        }
        let seconds = Double(ProcessInfo.processInfo.environment["DASHBAR_ONSCREEN_SECONDS"] ?? "") ?? 8
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    }
}

/// `--widget small|medium|codex|antigravity|opencode|copilot|usage`: one desktop widget at its real size, its own rounded
/// shape and fill on a transparent background (the README's pictures and the reference for the site's HTML widgets,
/// `docs/images/widget-*-{light,dark}.png`, at `DASHBAR_SNAPSHOT_SCALE=4`), from the store's snapshot as the widget would
/// read it. `small` is Claude's plan limits, `medium` the overview, `usage` tokens today; the demo flags
/// (`DASHBAR_DEMO_GOOGLE`, `DASHBAR_DEMO_OPENCODE`, `DASHBAR_DEMO_COPILOT`, `DASHBAR_DEMO_HIDDEN`) fill in the rest.
/// `DASHBAR_WIDGET_STATE=nodata|notrunning` shows the widget before the app has saved anything, or after it has quit;
/// `=hidden` with the widget's own tool switched off in Dashbar, `=unused` with that tool never used.
/// `DASHBAR_WIDGET_TOOLS=1` keeps only the first N tools' limits, to see the medium widget with fewer rows.
/// `DASHBAR_WIDGET_LOCAL=1` draws the "Local" marker a local build's widgets carry (left out otherwise, as everywhere offline).
@MainActor
enum WidgetSnapshot {
    static func render(_ size: DashbarWidgetSize, store: Store, dark: Bool, to path: String) {
        let now = Date()
        let state = ProcessInfo.processInfo.environment["DASHBAR_WIDGET_STATE"]
        var full = CLIStatus.snapshot(of: store, showsClaudeLimits: true, now: now)
        if let tool = size.tool, state == "hidden" || state == "unused" {
            // As the app would save it: a tool switched off (or never used) has no limits or usage in the snapshot.
            full.limits.removeAll { $0.provider == tool.provider }
            full.usageToday?.tools.removeAll { $0.tool == tool.usageID }
            if state == "hidden" { full.hidden = ((full.hidden ?? []) + [StatusSnapshot.switchID(tool.provider)]).sorted() }
        }
        var snapshot = full.forWidget()
        if let tools = ProcessInfo.processInfo.environment["DASHBAR_WIDGET_TOOLS"].flatMap(Int.init) {
            snapshot.limits = Array(snapshot.limits.prefix(tools))
        }
        let entry = DashbarWidgetEntry(date: now, snapshot: state == "nodata" ? nil : snapshot, running: state != "notrunning",
                                       local: ProcessInfo.processInfo.environment["DASHBAR_WIDGET_LOCAL"] == "1")
        let content = size.view(entry)
            .padding(16)
            .frame(width: size.points.width, height: size.points.height, alignment: .topLeading)
            .background(dark ? Color(white: 0.17) : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))   // chronod: 27.88
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = Snapshot.scale ?? 2
        renderer.isOpaque = false
        if let image = renderer.cgImage, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
