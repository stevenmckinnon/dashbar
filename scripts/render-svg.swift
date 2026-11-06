// Renders an SVG to a transparent PNG with WebKit, which (unlike NSImage/CoreSVG) supports SVG filters
// such as the icon's glow and drop shadow. Usage: swift scripts/render-svg.swift in.svg out.png [size]
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 3 else { fputs("usage: render-svg in.svg out.png [size]\n", stderr); exit(2) }
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let size = args.count > 3 ? Int(args[3]) ?? 1024 : 1024

final class Renderer: NSObject, WKNavigationDelegate {
    let web: WKWebView
    init(size: Int) {
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        web.setValue(false, forKey: "drawsBackground") // keep the corners transparent
        super.init()
        web.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        config.snapshotWidth = NSNumber(value: size) // 1 SVG unit per output pixel at any screen scale
        webView.takeSnapshot(with: config) { image, error in
            guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                fputs("snapshot failed: \(String(describing: error))\n", stderr); exit(1)
            }
            do { try png.write(to: output) } catch { fputs("\(error)\n", stderr); exit(1) }
            exit(0)
        }
    }
}

let svg = try String(contentsOf: input, encoding: .utf8)
let html = """
<!doctype html><html><head><style>
html,body{margin:0;padding:0;background:transparent;overflow:hidden}
svg{display:block;width:\(size)px;height:\(size)px}
</style></head><body>\(svg)</body></html>
"""
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = Renderer(size: size)
renderer.web.loadHTMLString(html, baseURL: nil)
DispatchQueue.main.asyncAfter(deadline: .now() + 20) { fputs("timed out\n", stderr); exit(1) }
app.run()
