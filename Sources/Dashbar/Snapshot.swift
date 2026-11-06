import SwiftUI
import AppKit

/// `Dashbar --snapshot out.png [--dark]` renders the dashboard with live data to a PNG and exits.
/// Handy for README screenshots and visual checks without clicking the menu bar.
@MainActor
enum Snapshot {
    static var store: Store?

    static func schedule(to path: String) {
        let store = Store()
        self.store = store
        let dark = CommandLine.arguments.contains("--dark")
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            let view = DashboardView(scrolls: false)
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
