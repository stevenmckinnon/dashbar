import AppKit
import Carbon.HIToolbox

/// Dashbar's system-wide hot keys, through the Carbon hot key API, which needs no Accessibility permission (unlike
/// watching all key presses). One event handler serves them all and calls the action registered under the pressed
/// key's id, so the window's ⌃⌥D and the jump shortcut never take each other's presses.
///
/// Hot keys belong to the process that registers them, so the release and a local build each register only what their
/// own preferences hold. When a combination is already taken (by another app, or the other copy of Dashbar),
/// `RegisterEventHotKey` refuses it and the caller says so in Settings.
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    enum ID: UInt32 { case window = 1, jump = 2 }

    private struct Entry {
        let keyCode: UInt32
        let modifiers: UInt32
        let action: () -> Void
        var ref: EventHotKeyRef?
    }

    private var entries: [ID: Entry] = [:]
    private var handler: EventHandlerRef?
    /// While a shortcut is being recorded every hot key is let go, so pressing one types it instead of running it.
    private(set) var suspended = false

    nonisolated private static let signature = OSType(0x4453_4842)   // "DSHB"

    /// Registers (or replaces) the hot key under `id`. Returns false when the system refuses the combination.
    @discardableResult
    func register(_ id: ID, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        unregister(id)
        installHandler()
        var entry = Entry(keyCode: keyCode, modifiers: modifiers, action: action, ref: nil)
        if !suspended {
            guard let ref = Self.carbonRegister(id, keyCode: keyCode, modifiers: modifiers) else { return false }
            entry.ref = ref
        }
        entries[id] = entry
        return true
    }

    func unregister(_ id: ID) {
        if let ref = entries[id]?.ref { UnregisterEventHotKey(ref) }
        entries[id] = nil
    }

    func isRegistered(_ id: ID) -> Bool { entries[id] != nil }

    /// Lets go of every hot key (true) or takes them back (false). Taking them back can fail for a combination another
    /// app grabbed in the meantime; that one is dropped and `onLost` hears which.
    func setSuspended(_ on: Bool, onLost: ((ID) -> Void)? = nil) {
        guard on != suspended else { return }
        suspended = on
        for (id, var entry) in entries {
            if on {
                if let ref = entry.ref { UnregisterEventHotKey(ref) }
                entry.ref = nil
                entries[id] = entry
            } else if let ref = Self.carbonRegister(id, keyCode: entry.keyCode, modifiers: entry.modifiers) {
                entry.ref = ref
                entries[id] = entry
            } else {
                entries[id] = nil
                onLost?(id)
            }
        }
    }

    fileprivate func fire(_ raw: UInt32) {
        guard !suspended, let id = ID(rawValue: raw) else { return }
        entries[id]?.action()
    }

    private static func carbonRegister(_ id: ID, keyCode: UInt32, modifiers: UInt32) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: signature, id: id.rawValue),
                                         GetApplicationEventTarget(), 0, &ref)
        return status == noErr ? ref : nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var key = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard status == noErr, key.signature == HotKeys.signature else { return OSStatus(eventNotHandledErr) }
            let raw = key.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.shared.fire(raw) } }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

/// ⌃⌥D from anywhere opens the popout window, or closes it when it's already in front.
///
/// The combination is fixed; Settings can turn it off. ⌥⌘D was avoided because macOS uses it to hide the Dock.
@MainActor
final class GlobalShortcut {
    static let shared = GlobalShortcut()
    nonisolated static let enabledKey = "globalShortcut"
    nonisolated static let display = "⌃⌥D"
    /// The same combination as a `KeyCombo`, so the jump shortcut's recorder can refuse it while this one is on.
    nonisolated static let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey), key: "D")

    /// What the shortcut does; set by the store.
    var action: (() -> Void)?
    /// True when another app already holds ⌃⌥D, so Settings can say why it does nothing.
    private(set) var unavailable = false

    nonisolated static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    func setEnabled(_ on: Bool) {
        guard on else {
            HotKeys.shared.unregister(.window)
            unavailable = false
            return
        }
        guard !HotKeys.shared.isRegistered(.window) else { return }
        let ok = HotKeys.shared.register(.window, keyCode: Self.combo.keyCode, modifiers: Self.combo.modifiers) { [weak self] in
            self?.action?()
        }
        unavailable = !ok
    }
}
