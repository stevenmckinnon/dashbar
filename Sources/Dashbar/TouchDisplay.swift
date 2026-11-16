import AppKit
import SwiftUI

// MARK: - Touch displays

/// Whether this Mac has a touch display (`NSScreen.touchCapabilities`, macOS 27). Today only the MacBook Pro with the
/// PROLED XDR display has one, and it also has a Dynamic Island where other MacBooks have the notch. Apple offers no way
/// to detect the island itself, so a touch display stands in for it: the island starts off there
/// (`IslandSettings.enabledAtLaunch`), and the panel turns `touchFriendly` on.
enum TouchDisplay {
    /// `DASHBAR_DEMO_TOUCH=1` pretends there is one, in memory only, for snapshots and for trying the layout.
    static var simulated: Bool { ProcessInfo.processInfo.environment["DASHBAR_DEMO_TOUCH"] == "1" }

    /// Any screen: a touch MacBook on an external display still has its own touch screen and island.
    @MainActor static var present: Bool { simulated || NSScreen.screens.contains(where: hasTouch) }

    @MainActor static func hasTouch(_ screen: NSScreen) -> Bool {
        if #available(macOS 27.0, *) { return screen.touchCapabilities.contains(.multiTouch) }
        return false
    }
}

/// Set at the panel's and the window's root from `TouchDisplay.present`: row actions that otherwise wait for a hover
/// stay visible, and small buttons get a hit area of about 30 points (their glyphs keep their size). Off, nothing changes.
struct TouchFriendlyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var touchFriendly: Bool {
        get { self[TouchFriendlyKey.self] }
        set { self[TouchFriendlyKey.self] = newValue }
    }
}

enum TouchSize {
    /// The smallest thing to press with a finger.
    static let target: CGFloat = 30
}

extension View {
    /// At least a 30-point square to press when `touchFriendly` is on; untouched otherwise.
    func touchTarget() -> some View { modifier(TouchTarget()) }
}

private struct TouchTarget: ViewModifier {
    @Environment(\.touchFriendly) private var touch
    func body(content: Content) -> some View {
        if touch {
            content.frame(minWidth: TouchSize.target, minHeight: TouchSize.target).contentShape(Rectangle())
        } else {
            content
        }
    }
}
