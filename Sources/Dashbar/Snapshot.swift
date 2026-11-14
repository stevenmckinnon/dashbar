import SwiftUI
import AppKit

/// `Dashbar --snapshot out.png [--dark]` renders the dashboard with live data to a PNG and exits.
/// Handy for README screenshots and visual checks without clicking the menu bar.
@MainActor
enum Snapshot {
    static var store: Store?

    static func schedule(to path: String) {
        if let tab = ProcessInfo.processInfo.environment["DASHBAR_TAB"] {
            UserDefaults.standard.set(tab, forKey: "panelTab")
        }
        let island = CommandLine.arguments.firstIndex(of: "--island").flatMap { CommandLine.arguments.dropFirst($0 + 1).first }
        if island == "permission" { setenv("DASHBAR_DEMO_PERMISSION", "1", 1) }
        if island == "needsyou" { setenv("DASHBAR_DEMO_WAITING", "1", 1) }
        let demo = CommandLine.arguments.contains("--demo")
        let store = Store(demo: demo)
        self.store = store
        if !demo { store.setPanelVisible(true) }   // offline renders never get the window's visibility callback
        let dark = CommandLine.arguments.contains("--dark")
        let delay = Double(ProcessInfo.processInfo.environment["DASHBAR_SNAPSHOT_DELAY"] ?? "") ?? 10
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
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
            renderer.scale = 2
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
        renderer.scale = 2
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
    let size = CGSize(width: 960, height: 320)

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
