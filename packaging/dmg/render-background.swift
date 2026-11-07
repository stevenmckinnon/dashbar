import AppKit

// Draws the installer window's background (660 × 416 points: the window shows the top 400, the rest covers title bars taller than this macOS's): a mid-tone slate that both of Finder's label colours
// (dark on a light-theme Mac, light on a dark-theme Mac) can read on, an arrow from the app to Applications, and
// one line of instruction. Usage: swift render-background.swift out.png
// It is 1x only: on macOS 27 Finder drew every Retina variant tried (@2x pair, 2x-only, reversed multi-image TIFF)
// at twice the size, so a single 1x image is the only one that displays correctly. It is slightly soft on Retina.
let width: CGFloat = 660, height: CGFloat = 416

func render(scale: CGFloat, to path: String) {
    let px = Int(width * scale), py = Int(height * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: py, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)   // 2x files are 144 dpi, so tools treat them as the same size
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    ctx.translateBy(x: 0, y: CGFloat(py)); ctx.scaleBy(x: scale, y: -scale)   // origin top-left, like Finder
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

    NSColor(srgbRed: 0x6c / 255, green: 0x7a / 255, blue: 0x82 / 255, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    // The arrow: an arc between the icons, with its head set on the curve's end tangent.
    let p0 = CGPoint(x: 262, y: 172), p1 = CGPoint(x: 305, y: 108), p2 = CGPoint(x: 355, y: 108), p3 = CGPoint(x: 398, y: 172)
    var t = CGPoint(x: p3.x - p2.x, y: p3.y - p2.y)
    let n = hypot(t.x, t.y); t = CGPoint(x: t.x / n, y: t.y / n)
    let tip = CGPoint(x: p3.x + t.x * 3, y: p3.y + t.y * 3)
    let end = CGPoint(x: p3.x - t.x * 2, y: p3.y - t.y * 2)   // stops inside the head so the round cap doesn't poke out
    func wing(_ angle: CGFloat) -> CGPoint {
        let bx = -t.x, by = -t.y
        return CGPoint(x: tip.x + 24 * (bx * cos(angle) - by * sin(angle)), y: tip.y + 24 * (bx * sin(angle) + by * cos(angle)))
    }
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.88).cgColor)
    ctx.setLineWidth(7); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.move(to: p0); ctx.addCurve(to: end, control1: p1, control2: p2); ctx.strokePath()
    let a = 34 * CGFloat.pi / 180
    ctx.move(to: wing(a)); ctx.addLine(to: tip); ctx.addLine(to: wing(-a)); ctx.strokePath()

    let text = NSAttributedString(string: "Drag Dashbar to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92),
    ])
    let size = text.size()
    text.draw(at: NSPoint(x: (width - size.width) / 2, y: 318))

    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
guard args.count == 2 else { print("usage: render-background.swift out.png"); exit(64) }
render(scale: 1, to: args[1])
