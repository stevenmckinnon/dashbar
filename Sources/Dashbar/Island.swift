import Foundation
import CoreGraphics

// MARK: - Dashbar Island: what it shows and when (no AppKit, so it can be tested)

/// The island's settings, read from UserDefaults. On for new installs only (see `Onboarding.decideAtLaunch`): someone
/// updating gets no new thing drawn over their notch without asking, and finds it in Settings → General.
enum IslandSettings {
    static let enabledKey = "islandEnabled"
    static let positionKey = "islandPosition"
    static let expandOnFinishKey = "islandExpandOnFinish"
    static let expandOnNeedsYouKey = "islandExpandOnNeedsYou"
    static let replacesNotificationsKey = "islandReplacesNotifications"
    static let showsPillKey = "islandShowsPill"

    struct Values: Equatable {
        var enabled = true
        var position = IslandPosition.automatic
        var expandOnFinish = true
        var expandOnNeedsYou = true
        var replacesNotifications = false
        /// Keep a small status beside the notch while agents work. Off by default: the island shows only for
        /// moments, since a lasting pill can cover an app's menus (macOS carries them on past the notch).
        var showsPill = false

        /// Unset keys take the defaults above, except `enabled`, which is off unless a new install turned it on.
        static func read(_ defaults: UserDefaults = .standard) -> Values {
            func flag(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
            return Values(enabled: flag(enabledKey, false),
                          position: IslandPosition(rawValue: defaults.string(forKey: positionKey) ?? "") ?? .automatic,
                          expandOnFinish: flag(expandOnFinishKey, true),
                          expandOnNeedsYou: flag(expandOnNeedsYouKey, true),
                          replacesNotifications: flag(replacesNotificationsKey, false),
                          showsPill: flag(showsPillKey, false))
        }

        /// Whether this kind of moment opens the island.
        func expands(for kind: IslandBanner.Kind) -> Bool {
            guard enabled else { return false }
            switch kind {
            case .finished: return expandOnFinish
            case .waiting, .permission: return expandOnNeedsYou
            }
        }

        /// The system notification is left out only when the island will show the same moment instead, so turning the
        /// island off (or that kind of expansion) brings notifications back without touching another setting.
        func suppressesNotification(for kind: IslandBanner.Kind) -> Bool {
            replacesNotifications && expands(for: kind)
        }
    }
}

extension IslandSettings {
    /// What a launch saves for `enabledKey`, or nil to leave it alone. A new install turns the island on, except on a Mac
    /// with a touch display: today that is only the MacBook Pro with a Dynamic Island in place of the notch, which
    /// Dashbar's island would sit on top of. There it stays unset, so it reads as off and is still nobody's choice. A
    /// saved value is the user's (or an earlier launch's) and is never changed, in either direction.
    static func enabledAtLaunch(newInstall: Bool, saved: Bool?, touch: Bool) -> Bool? {
        guard newInstall, saved == nil, !touch else { return nil }
        return true
    }

    /// Applies `enabledAtLaunch` to `defaults`.
    static func applyLaunchDefault(_ defaults: UserDefaults, newInstall: Bool, touch: Bool) {
        let saved = defaults.object(forKey: enabledKey) as? Bool
        if let value = enabledAtLaunch(newInstall: newInstall, saved: saved, touch: touch) {
            defaults.set(value, forKey: enabledKey)
        }
    }
}

enum IslandPosition: String, CaseIterable {
    /// On the notch, or below another app's island when one is already there.
    case automatic
    case centre
    /// Beside the notch (on a screen without one, beside the middle of the menu bar).
    case left, right
}

/// The pill's summary when nothing is expanded: the most important thing only.
enum IslandStatus: Equatable {
    case idle
    case working(Int)
    case needsYou(Int)

    /// Someone has to act first (waiting sessions, and prompts whose session Dashbar can't see), then working agents.
    static func of(sessions: [LiveSession], permissionRequests: [PermissionRequest]) -> IslandStatus {
        let ids = Set(sessions.map(\.id))
        let waiting = sessions.filter(\.isWaiting).count + permissionRequests.filter { !ids.contains($0.sessionId) }.count
        if waiting > 0 { return .needsYou(waiting) }
        let busy = sessions.filter(\.isBusy).count
        return busy > 0 ? .working(busy) : .idle
    }

    /// "2": the number alone, for a narrow ear.
    var countText: String {
        switch self {
        case .idle: return ""
        case .working(let n), .needsYou(let n): return "\(n)"
        }
    }

    /// "1 needs you", "2 working".
    var label: String {
        switch self {
        case .idle: return "Idle"
        case .working(let n): return "\(n) working"
        case .needsYou(let n): return "\(n) \(n == 1 ? "needs" : "need") you"
        }
    }
}

/// A moment the island opens up for.
struct IslandBanner: Equatable, Identifiable {
    enum Kind: Equatable {
        case finished(after: TimeInterval)
        case waiting
        case permission(requestID: String)

        /// A prompt you can answer here outranks a session waiting for you, which outranks news that one finished.
        var priority: Int {
            switch self {
            case .finished: return 0
            case .waiting: return 1
            case .permission: return 2
            }
        }

        /// How long it stays open before folding back into the pill, unless the pointer is on it.
        var duration: TimeInterval {
            switch self {
            case .finished: return 5
            case .waiting: return 7
            case .permission: return 15   // long enough to read the command; answerable from the pill's hover after
            }
        }
    }

    let kind: Kind
    let sessionID: String
    let shownAt: Date
    var id: String { "\(sessionID)-\(kind.priority)-\(shownAt.timeIntervalSince1970)" }
}

/// What the island is doing now.
enum IslandMode: Equatable {
    case hidden
    case collapsed(IslandStatus)
    case banner(IslandBanner)
    /// Opened by the pointer: the live sessions, with any prompt waiting to be answered.
    case list
}

/// The island's state machine. Driven by store changes and the pointer; the window controller schedules a single
/// one-shot wake-up at `deadline` and nothing at all while idle.
struct IslandPresenter: Equatable {
    private(set) var banner: IslandBanner?
    /// The pointer is on the island.
    private(set) var hovering = false
    /// The pointer opened the session list (after a short pause on the collapsed pill).
    private(set) var listOpen = false
    private(set) var hoverEndedAt: Date?

    /// After the pointer leaves, an open banner stays at least this long so it doesn't vanish under a moving cursor.
    static let hoverGrace: TimeInterval = 1.5
    /// Resting on the pill this long opens the list; less is a pointer passing by on its way to the menu bar.
    static let hoverIntent: TimeInterval = 0.25
    /// Leaving the list for this long closes it.
    static let listGrace: TimeInterval = 0.4

    /// Offers a moment. Accepted when that kind is turned on and nothing more important is showing; a newer moment of
    /// the same kind replaces an older one.
    @discardableResult
    mutating func post(_ new: IslandBanner, settings: IslandSettings.Values, now: Date) -> Bool {
        guard settings.expands(for: new.kind) else { return false }
        expire(now: now)
        if let current = banner, current.kind.priority > new.kind.priority { return false }
        banner = new
        hoverEndedAt = nil
        return true
    }

    /// Drops a banner that no longer holds: its prompt was answered, its session stopped waiting or went away.
    mutating func reconcile(sessions: [LiveSession], permissionRequests: [PermissionRequest]) {
        guard let b = banner else { return }
        let session = sessions.first { $0.id == b.sessionID }
        switch b.kind {
        case .permission(let id):
            if !permissionRequests.contains(where: { $0.id == id }) { banner = nil }
        case .waiting:
            if session?.isWaiting != true { banner = nil }
        case .finished:
            if session == nil || session?.isBusy == true || session?.isWaiting == true { banner = nil }
        }
    }

    /// When the banner folds away, or nil while the pointer holds it open (or there is none).
    func deadline() -> Date? {
        guard let b = banner, !hovering else { return nil }
        let natural = b.shownAt.addingTimeInterval(b.kind.duration)
        guard let left = hoverEndedAt else { return natural }
        return max(natural, left.addingTimeInterval(Self.hoverGrace))
    }

    mutating func expire(now: Date) {
        if let d = deadline(), now >= d { banner = nil; hoverEndedAt = nil }
    }

    /// Clicked away (an action taken on it, or Escape).
    mutating func dismiss() { banner = nil; hoverEndedAt = nil }

    mutating func pointer(inside: Bool, now: Date) {
        guard inside != hovering else { return }
        hovering = inside
        hoverEndedAt = inside ? nil : now
    }

    /// The pointer rested on the pill long enough (`hoverIntent`), or it was clicked. Only the lasting pill opens
    /// the list; without it there is nothing to hover between moments.
    mutating func openList() { if banner == nil { listOpen = true } }
    mutating func closeList() { listOpen = false }

    /// A moment shows as its banner. Otherwise the island is gone (nothing drawn, nothing to click) unless the user
    /// keeps the small status pill, which shows while any agent works or waits.
    func mode(status: IslandStatus, showsPill: Bool) -> IslandMode {
        if let banner { return .banner(banner) }
        guard showsPill else { return .hidden }
        if listOpen { return .list }
        return status == .idle ? .hidden : .collapsed(status)
    }
}

// MARK: - Where it goes

/// The screen facts placement needs, in AppKit coordinates (origin bottom left, y up).
struct IslandScreen: Equatable {
    var frame: CGRect
    /// The hardware notch, or nil on a display without one.
    var notch: CGRect?
    var menuBarHeight: CGFloat

    /// From `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` (the menu bar either side of the notch) and
    /// `safeAreaInsets.top` (the notch's height). Without both side areas there is no notch.
    static func make(frame: CGRect, safeAreaTop: CGFloat, topLeft: CGRect?, topRight: CGRect?, menuBarHeight: CGFloat) -> IslandScreen {
        guard safeAreaTop > 0, let l = topLeft, let r = topRight, r.minX > l.maxX else {
            return IslandScreen(frame: frame, notch: nil, menuBarHeight: menuBarHeight)
        }
        let notch = CGRect(x: l.maxX, y: frame.maxY - safeAreaTop, width: r.minX - l.maxX, height: safeAreaTop)
        return IslandScreen(frame: frame, notch: notch, menuBarHeight: max(menuBarHeight, safeAreaTop))
    }
}

/// How the island sits, which decides its shape and how its content is laid out.
enum IslandStyle: Equatable {
    /// Grown out of the notch: flush with the top edge, the notch's width kept clear in the middle of the collapsed
    /// pill, and expanded content starting below `height`.
    case notch(width: CGFloat, height: CGFloat)
    /// Flush with the top edge beside the notch (or beside the middle of the menu bar), extending away from it.
    case beside(leading: Bool, height: CGFloat)
    /// A free-floating capsule below the menu bar, or below another app's island.
    case floating
}

struct IslandPlacement: Equatable {
    var style: IslandStyle
    /// The x the island grows from: its centre, or for `beside` the edge touching the notch.
    var anchorX: CGFloat
    /// The y its top edge sits at.
    var topY: CGFloat

    /// How far the island's centre sits from `anchorX`. Beside the notch it extends away from it; on the notch,
    /// ears of different widths (`left`, `right`) put the centre off the notch's.
    func centreOffset(for size: CGSize, ears: (left: CGFloat, right: CGFloat)? = nil) -> CGFloat {
        switch style {
        case .beside(let leading, _): return leading ? -size.width / 2 : size.width / 2
        case .notch: return ears.map { ($0.right - $0.left) / 2 } ?? 0
        case .floating: return 0
        }
    }

    /// The window's frame for content of this size (on the notch, with these ear widths when collapsed).
    func frame(for size: CGSize, ears: (left: CGFloat, right: CGFloat)? = nil) -> CGRect {
        let x = anchorX + centreOffset(for: size, ears: ears) - size.width / 2
        return CGRect(x: Self.px(x), y: Self.px(topY - size.height), width: Self.px(size.width), height: Self.px(size.height))
    }

    /// Half points, so it lands on Retina pixels and stays flush with a notch at x.5 (the 14-inch's is).
    static func px(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }

    /// The gap kept between a floating island and the menu bar (or another island above it).
    static let floatingGap: CGFloat = 6
    /// Room left in the middle on a screen without a notch when placed beside it, so it clears a centred island.
    static let besideClearance: CGFloat = 200

    static func place(on screen: IslandScreen, position: IslandPosition, obstacles: [CGRect] = []) -> IslandPlacement {
        let top = screen.frame.maxY
        let menuBottom = top - screen.menuBarHeight
        switch position {
        case .left, .right:
            let leading = position == .left
            if let n = screen.notch {
                return IslandPlacement(style: .beside(leading: leading, height: n.height), anchorX: leading ? n.minX : n.maxX, topY: top)
            }
            let mid = screen.frame.midX
            return IslandPlacement(style: .beside(leading: leading, height: screen.menuBarHeight),
                                   anchorX: leading ? mid - besideClearance / 2 : mid + besideClearance / 2, topY: top)
        case .centre, .automatic:
            let busy = position == .automatic ? obstacles.filter { $0.intersects(centreBand(screen)) } : []
            if !busy.isEmpty {
                // Another app already draws here: sit under the lowest of its windows, centred, as a floating pill.
                let lowest = min(busy.map(\.minY).min() ?? menuBottom, menuBottom)
                return IslandPlacement(style: .floating, anchorX: screen.frame.midX, topY: lowest - floatingGap)
            }
            if let n = screen.notch {
                return IslandPlacement(style: .notch(width: n.width, height: n.height), anchorX: n.midX, topY: top)
            }
            return IslandPlacement(style: .floating, anchorX: screen.frame.midX, topY: menuBottom - floatingGap)
        }
    }

    /// Where a centred island would be: the notch and a little either side, down to just below the menu bar (or a
    /// 200-point stretch in the middle of a screen without a notch).
    static func centreBand(_ screen: IslandScreen) -> CGRect {
        let width = (screen.notch?.width ?? besideClearance) + 80
        let height = screen.menuBarHeight + 40
        let midX = screen.notch?.midX ?? screen.frame.midX
        return CGRect(x: midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    }
}

// MARK: - Ears that fit between the notch and the menu bar items

/// The collapsed island on a notch: the notch plus two small ears, the Dashbar mark on the left and a short status
/// on the right, each only as wide as the free menu bar beside the notch allows. macOS won't move menu bar items
/// out of the way, so the island has to fit around them.
struct IslandEars: Equatable {
    /// The right ear's status, widest first: "2 working", "2", a dot, nothing.
    enum Right: Int, Comparable, CaseIterable {
        case none, dot, count, full
        static func < (a: Right, b: Right) -> Bool { a.rawValue < b.rawValue }
    }

    var showsMark = true
    var right = Right.count
    /// Each ear's width, flare included (0 for a hidden ear).
    var leftWidth: CGFloat = 0
    var rightWidth: CGFloat = 0

    /// What each form of each ear needs, measured from the text it would show.
    struct Widths: Equatable {
        var mark: CGFloat
        var full: CGFloat
        var count: CGFloat
        var dot: CGFloat

        func width(_ form: Right) -> CGFloat {
            switch form {
            case .none: return 0
            case .dot: return dot
            case .count: return count
            case .full: return full
            }
        }
    }

    /// Kept clear between an ear and the nearest menu bar item.
    static let margin: CGFloat = 6
    /// Free space assumed beside the notch when nothing there can be measured: room for the mark on the left and a
    /// count on the right, not the full words. The app's menus (left) and other apps' menu bar items (right) aren't
    /// exposed to other apps without Accessibility access, so the ears stay small rather than guess.
    static let assumedLeft: CGFloat = 48
    static let assumedRight: CGFloat = 54

    /// The widest of each ear that fits its gap less the margin, or a hidden ear when even the smallest doesn't.
    /// `allowFull` is false unless the right gap was actually measured.
    static func fit(leftGap: CGFloat, rightGap: CGFloat, widths: Widths, allowFull: Bool) -> IslandEars {
        let leftRoom = leftGap - margin, rightRoom = rightGap - margin
        let showsMark = widths.mark <= leftRoom
        let forms: [Right] = allowFull ? [.full, .count, .dot] : [.count, .dot]
        let right = forms.first { widths.width($0) <= rightRoom } ?? .none
        return IslandEars(showsMark: showsMark, right: right,
                          leftWidth: showsMark ? widths.mark : 0, rightWidth: widths.width(right))
    }

    /// The free menu bar either side of the notch, from the menu bar items that could be found (AppKit coordinates).
    /// A side with nothing found gets the assumed room, capped by the screen edge; `measuredRight` says whether
    /// the right side's came from real items rather than the assumption.
    static func gaps(notch: CGRect, screen: CGRect, items: [CGRect], itemsAreComplete: Bool)
        -> (left: CGFloat, right: CGFloat, measuredRight: Bool) {
        let band = CGRect(x: screen.minX, y: notch.minY, width: screen.width, height: notch.height)
        let inBar = items.filter { $0.intersects(band) && !$0.intersects(notch.insetBy(dx: 1, dy: 1)) }
        let rightItems = inBar.filter { $0.midX > notch.midX }.map(\.minX)
        let leftItems = inBar.filter { $0.midX < notch.midX }.map(\.maxX)
        let rightEdge = rightItems.min()
        let leftEdge = leftItems.max()
        var right = (rightEdge ?? screen.maxX) - notch.maxX
        var left = notch.minX - (leftEdge ?? screen.minX)
        // Unless every item could be seen, an unseen one may sit nearer the notch than any found.
        if !itemsAreComplete || rightEdge == nil { right = min(right, assumedRight) }
        if !itemsAreComplete || leftEdge == nil { left = min(left, assumedLeft) }
        return (max(0, left), max(0, right), itemsAreComplete && rightEdge != nil)
    }

    /// Menu bar items in `CGWindowListCopyWindowInfo` (layer 25, the status window level, inside the menu bar),
    /// in AppKit coordinates. Recent macOS draws other apps' items inside the menu bar's own window and lists none
    /// of them here, so this is often empty; Dashbar's own item comes from its own windows instead.
    static func statusItems(in windows: [[String: Any]], ownPID: Int32, primaryHeight: CGFloat, menuBarHeight: CGFloat) -> [CGRect] {
        windows.compactMap { w in
            guard (w[kCGWindowOwnerPID as String] as? Int).map(Int32.init) != ownPID,
                  w[kCGWindowLayer as String] as? Int == 25,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let x = (b["X"] as? NSNumber)?.doubleValue, let y = (b["Y"] as? NSNumber)?.doubleValue,
                  let width = (b["Width"] as? NSNumber)?.doubleValue, let height = (b["Height"] as? NSNumber)?.doubleValue,
                  y < 1, height <= menuBarHeight + 1, width < 400
            else { return nil }
            return CGRect(x: x, y: primaryHeight - y - height, width: width, height: height)
        }
    }
}

// MARK: - Other apps at the notch

/// Other apps' windows sitting where a centred island would go (T3 Code's island, Vibe Island, CodeIsland…), read from
/// `CGWindowListCopyWindowInfo`'s owner, layer and bounds, which need no Screen Recording permission.
enum IslandNeighbours {
    /// System windows that live in the menu bar and are never another island.
    static let systemOwners: Set<String> = ["Window Server", "Control Center", "SystemUIServer", "Dock", "Spotlight",
                                            "Notification Center", "WindowManager", "Screenshot", "screencaptureui"]

    /// Windows above the menu bar (layer 25 and up) inside `band`, converted to AppKit coordinates. A local build
    /// makes way for the release's island, but the release ignores a local build's, so the two copies never chase
    /// each other around. Anything screen-sized is an overlay, not an island.
    static func obstacles(in windows: [[String: Any]], ownPID: Int32, isLocalBuild: Bool, primaryHeight: CGFloat,
                          band: CGRect) -> [CGRect] {
        windows.compactMap { w in
            guard (w[kCGWindowOwnerPID as String] as? Int).map(Int32.init) != ownPID,
                  let layer = w[kCGWindowLayer as String] as? Int, layer >= 25,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let x = (b["X"] as? NSNumber)?.doubleValue, let y = (b["Y"] as? NSNumber)?.doubleValue,
                  let width = (b["Width"] as? NSNumber)?.doubleValue, let height = (b["Height"] as? NSNumber)?.doubleValue
            else { return nil }
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            if systemOwners.contains(owner) { return nil }
            if owner == "Dashbar Local" { return nil }
            if owner == "Dashbar", !isLocalBuild { return nil }
            guard width < band.width * 6, height < 400 else { return nil }
            let rect = CGRect(x: x, y: primaryHeight - y - height, width: width, height: height)
            return rect.intersects(band) ? rect : nil
        }
    }
}
