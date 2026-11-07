import AppKit
import Carbon.HIToolbox

/// ⌃⌥D from anywhere opens the popout window, or closes it when it's already in front.
///
/// Uses the Carbon hot key API, which needs no Accessibility permission (unlike watching all key presses).
/// The combination is fixed; Settings can turn it off. ⌥⌘D was avoided because macOS uses it to hide the Dock.
final class GlobalShortcut {
    static let shared = GlobalShortcut()
    static let enabledKey = "globalShortcut"
    static let display = "⌃⌥D"

    /// What the shortcut does; set by the store.
    var action: (() -> Void)?
    /// True when another app already holds ⌃⌥D, so Settings can say why it does nothing.
    private(set) var unavailable = false

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    func setEnabled(_ on: Bool) { on ? register() : unregister() }

    private func register() {
        guard hotKey == nil else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { GlobalShortcut.shared.action?() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4453_4842), id: 1)   // "DSHB"
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey), id,
                                         GetApplicationEventTarget(), 0, &hotKey)
        unavailable = status != noErr
        if unavailable { hotKey = nil }
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        unavailable = false
    }
}
