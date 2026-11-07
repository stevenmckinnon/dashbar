import AppKit

/// Finds a project's own icon on disk (its web app icon, favicon, Xcode app icon or logo), so a workspace
/// can show what the project actually looks like. Only reads images, only inside the project folder, and
/// remembers the answer (including "none") for the life of the app.
enum ProjectIcon {
    private static let lock = NSLock()
    private static var cache: [String: NSImage?] = [:]

    /// Plain files to try, in order of how likely they are to be a deliberate, square icon.
    private static let candidates = [
        "app/icon.png", "src/app/icon.png", "app/icon.jpg", "src/app/icon.jpg",
        "public/apple-touch-icon.png", "public/icon.png", "public/logo.png", "public/favicon.png",
        "static/icon.png", "static/favicon.png", "src/assets/icon.png", "src/assets/logo.png",
        "assets/icon.png", "assets/logo.png", "Resources/AppIcon.icns", "docs/images/icon.png",
        "icon.png", "logo.png", "favicon.png", "public/favicon.ico", "favicon.ico", "app/favicon.ico", "src/app/favicon.ico",
    ]

    /// Cached result without touching the disk, or nil when it hasn't been looked up yet.
    static func cached(for root: String) -> NSImage?? {
        lock.lock(); defer { lock.unlock() }
        return cache[root]
    }

    /// Looks for an icon (blocking disk reads, so call off the main thread) and remembers the result.
    static func find(in root: String) -> NSImage? {
        if let hit = cached(for: root) { return hit }
        let image = search(root)
        lock.lock(); cache[root] = .some(image); lock.unlock()
        return image
    }

    private static func search(_ root: String) -> NSImage? {
        let base = URL(fileURLWithPath: root)
        for path in candidates {
            if let image = load(base.appendingPathComponent(path)) { return image }
        }
        return xcodeIcon(in: base)
    }

    /// `Something/Assets.xcassets/AppIcon.appiconset/*.png`, one or two folders down: the largest image.
    private static func xcodeIcon(in base: URL) -> NSImage? {
        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        for dir in [base] + top.filter({ $0.hasDirectoryPath }).prefix(12) {
            let sets = ["Assets.xcassets", "Images.xcassets", "Resources/Assets.xcassets"]
            for set in sets {
                let icons = dir.appendingPathComponent(set).appendingPathComponent("AppIcon.appiconset")
                guard let files = try? fm.contentsOfDirectory(at: icons, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
                let pngs = files.filter { $0.pathExtension.lowercased() == "png" }
                    .sorted { size($0) > size($1) }
                if let best = pngs.first, let image = load(best) { return image }
            }
        }
        return nil
    }

    private static func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

    /// A readable image at least 32 pixels across (smaller ones go soft at tile size), and not huge.
    private static func load(_ url: URL) -> NSImage? {
        guard FileManager.default.isReadableFile(atPath: url.path), size(url) > 0, size(url) < 6_000_000,
              let image = NSImage(contentsOf: url) else { return nil }
        let widest = image.representations.map(\.pixelsWide).max() ?? 0
        return widest >= 32 ? image : nil
    }
}
