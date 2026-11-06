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
        let store = Store()
        self.store = store
        store.setPanelVisible(true)   // offline renders never get the window's visibility callback
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
            if CommandLine.arguments.contains("--settings") {
                // The Settings window's General tab, laid out by AppKit so native controls draw.
                let host = NSHostingView(rootView: SettingsView().environment(\.colorScheme, dark ? .dark : .light))
                // Offline renders show the first tab; the others are checked by building SettingsView's tabs directly.
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
            if CommandLine.arguments.contains("--hosted") {
                // Lay out the real scrolling panel the way MenuBarExtra does: at its fitting size.
                let host = NSHostingView(rootView: DashboardView().environmentObject(store)
                    .environment(\.colorScheme, dark ? .dark : .light))
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
