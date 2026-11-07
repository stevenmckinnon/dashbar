import SwiftUI
import AppKit

/// What kind of build this is. `build.sh` marks everything except a release as local ("Dashbar Local.app"),
/// so it can be told apart from the installed release. Offline snapshots never show the marker.
enum BuildInfo {
    static let isLocal = Bundle.main.object(forInfoDictionaryKey: "DashbarLocalBuild") as? Bool == true
        && !CommandLine.arguments.contains("--snapshot")
    static var appName: String { isLocal ? "Dashbar Local" : "Dashbar" }
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    /// Puts the "LOCAL" icon on the Dock tile of a local build. Call again after the activation policy changes,
    /// which resets it.
    @MainActor static func applyLocalIcon() {
        if isLocal { NSApp.applicationIconImage = localIcon }
    }

    /// The bundle's icon with a "LOCAL" band, for the Dock and the About pane.
    @MainActor private static let localIcon: NSImage = {
        let base = NSImage(named: NSImage.applicationIconName) ?? NSImage()
        return NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            base.draw(in: rect)
            let band = NSRect(x: 96, y: 56, width: 320, height: 88)
            NSColor.black.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: band, xRadius: 44, yRadius: 44).fill()
            let text = NSAttributedString(string: "LOCAL", attributes: [
                .font: NSFont.systemFont(ofSize: 56, weight: .bold), .foregroundColor: NSColor.white, .kern: 4,
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: band.midX - size.width / 2, y: band.midY - size.height / 2))
            return true
        }
    }()
}

/// The Dashbar mark: a gauge arc over a progress bar, taken from the app icon.
/// The geometry is shared by the menu bar template image and the in-app coloured mark.
enum BrandMark {
    /// Proportions from the icon (arc radius 100, bar 240 × 34 at y 315), normalised to a unit square.
    struct Geometry {
        let size: CGFloat
        var arcCenter: CGPoint { CGPoint(x: size * 0.5, y: size * 0.56) }
        var arcRadius: CGFloat { size * 0.35 }
        var arcWidth: CGFloat { max(1.5, size * 0.085) }
        /// The bar's track: a faint filled pill (the icon's dark track), not an outline, so it stays legible at 18pt.
        var track: CGRect { CGRect(x: size * 0.1, y: size * 0.7, width: size * 0.8, height: size * 0.24) }
        func fill(_ fraction: CGFloat) -> CGRect {
            let inset = track.height * 0.15
            let inner = track.insetBy(dx: inset, dy: inset)
            return CGRect(x: inner.minX, y: inner.minY, width: max(inner.height, inner.width * fraction), height: inner.height)
        }
    }

    /// Menu bar glyph as a template image, so the system tints it for light, dark and highlighted menu bars.
    /// While an agent is working the bar fills further, a static cue that doesn't rely on colour.
    static func menuBarImage(working: Bool) -> NSImage {
        let pt: CGFloat = 18
        let g = Geometry(size: pt)
        let image = NSImage(size: NSSize(width: pt, height: pt), flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let arc = NSBezierPath()
            arc.appendArc(withCenter: g.arcCenter, radius: g.arcRadius, startAngle: 180, endAngle: 0, clockwise: false)
            arc.lineWidth = g.arcWidth
            arc.lineCapStyle = .round
            arc.stroke()

            // Template images keep alpha, so the track can be faint like the icon's.
            NSColor.black.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: g.track, xRadius: g.track.height / 2, yRadius: g.track.height / 2).fill()

            NSColor.black.setFill()
            let fillRect = g.fill(working ? 1 : 0.45)
            NSBezierPath(roundedRect: fillRect, xRadius: fillRect.height / 2, yRadius: fillRect.height / 2).fill()
            // A local build carries a dot in the top corner, so it reads differently from the release's icon.
            if BuildInfo.isLocal { NSBezierPath(ovalIn: NSRect(x: pt - 5.5, y: 0.5, width: 5, height: 5)).fill() }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = working ? "\(BuildInfo.appName), agents working" : BuildInfo.appName
        return image
    }
}

/// The coloured mark for use inside the app (panel header, settings), matching the icon's cyan-to-orange palette.
struct BrandMarkView: View {
    var size: CGFloat = 16

    var body: some View {
        let g = BrandMark.Geometry(size: size)
        let cyan = Color(red: 0.13, green: 0.83, blue: 0.93)
        let teal = Color(red: 0.05, green: 0.45, blue: 0.56)
        let orange = Color(red: 0.98, green: 0.45, blue: 0.09)
        Canvas { ctx, _ in
            var arc = Path()
            arc.addArc(center: g.arcCenter, radius: g.arcRadius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            ctx.stroke(arc, with: .linearGradient(Gradient(colors: [cyan, teal]),
                                                  startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: size, y: 0)),
                       style: StrokeStyle(lineWidth: g.arcWidth, lineCap: .round))

            ctx.fill(Path(roundedRect: g.track, cornerRadius: g.track.height / 2), with: .color(.primary.opacity(0.14)))

            let fill = g.fill(0.66)
            ctx.fill(Path(roundedRect: fill, cornerRadius: fill.height / 2),
                     with: .linearGradient(Gradient(colors: [cyan, teal, orange]),
                                           startPoint: CGPoint(x: fill.minX, y: 0), endPoint: CGPoint(x: fill.maxX, y: 0)))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
