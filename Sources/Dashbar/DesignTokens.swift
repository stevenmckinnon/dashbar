import SwiftUI
import AppKit

// MARK: - Design tokens

enum UI {
    static let panelWidth: CGFloat = 420
    static let gutter: CGFloat = 12
    static let gap: CGFloat = 8
    static let cardPadding: CGFloat = 12
    /// Inner surfaces (rows, buttons, mini stats). Cards are concentric: inner + padding.
    static let innerRadius: CGFloat = 6
    static let cardRadius: CGFloat = innerRadius + cardPadding
    /// Search field sits `gutter` inside the panel edge.
    static let fieldRadius: CGFloat = 8
    static let rowHover = 0.06
    static let buttonHover = 0.10
    /// Three equal columns across the panel.
    static let column: CGFloat = (panelWidth - 2 * gutter - 2 * gap) / 3
    /// Two equal columns across the panel.
    static let half: CGFloat = (panelWidth - 2 * gutter - gap) / 2

    /// Claude brand only (icons, the "now" bar). Never used for status.
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let accent = Color(red: 0.98, green: 0.55, blue: 0.24)

    // Text roles. Each light/dark pair measures ≥ 4.5:1 on the card surface.
    static let textSecondary = Color(light: .init(white: 0, alpha: 0.58), dark: .init(white: 1, alpha: 0.55)) // 5.3 / 5.4
    static let textSuccess = Color(light: .init(hex: 0x1A7F37), dark: .init(hex: 0x3FD06A))   // 5.1 / 7.1 — "working"
    static let textInfo = Color(light: .init(hex: 0x0B5CD5), dark: .init(hex: 0x80BBFF))      // 5.0 / 5.2 — ports, context OK
    static let textDanger = Color(light: .init(hex: 0xC4320A), dark: .init(hex: 0xFF6B5E))    // 5.5 / 5.1 — context nearly full, errors
    static let textAttention = Color(light: .init(hex: 0x8A5C00), dark: .init(hex: 0xE3B341)) // 5.2 / 7.4 — needs attention soon
    /// Amber: something needs your attention soon (an agent waiting for you, a limit on course to run out).
    /// Kept apart from Claude's coral and the problem red.
    static let attention = Color(light: .init(hex: 0xBF8700), dark: .init(hex: 0xE3B341))

    /// Type scale: six sizes, each with one job.
    enum Size {
        static let micro: CGFloat = 10    // axis labels, overlines, key caps
        static let caption: CGFloat = 11  // metadata, footnotes, badges
        static let body: CGFloat = 12     // row titles, card titles
        static let emphasis: CGFloat = 13 // workspace names, search
        static let title: CGFloat = 14    // panel title, Now card name
        static let numeral: CGFloat = 22  // tile and widget figures
    }
}

extension Color {
    /// A colour that follows the appearance it is rendered in.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The panel's pages. Overview is what you glance at; the rest is detail, one tab each.
