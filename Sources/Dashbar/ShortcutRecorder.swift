import AppKit
import SwiftUI

/// A field that records a key combination: press it (click, or Space with keyboard navigation), then type the
/// shortcut. Escape cancels, Delete on its own removes it, and the clear button beside it does too.
///
/// While recording, every Dashbar hot key is let go (`HotKeys.setSuspended`), so typing the current shortcut records it
/// instead of running it. Keys are read with a local event monitor, which sees only Dashbar's own key presses and needs
/// no permission.
struct ShortcutRecorder: View {
    /// What the shortcut does, for VoiceOver: "Jump to the agent that needs you".
    let label: String
    let combo: KeyCombo?
    let onChange: (KeyCombo?) -> Void
    /// A short sentence after a key that can't be used, shown by the caller under the row.
    @Binding var note: String?

    @State private var recording = false
    @State private var monitor: Any?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                Text(title)
                    .font(.system(size: UI.Size.body))
                    .foregroundStyle(combo == nil || recording ? UI.textSecondary : Color.primary)
                    .lineLimit(1)
                    .frame(minWidth: 96)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous)
                        .fill(Color.primary.opacity(recording || hover ? UI.buttonHover : UI.rowHover)))
                    .overlay(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous)
                        // The system's focus colour while listening for keys, as a text field shows it; neutral otherwise.
                        .strokeBorder(recording ? Color(nsColor: .keyboardFocusIndicatorColor) : Color.primary.opacity(0.12),
                                      lineWidth: recording ? 2 : 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .onHover { hover = $0 }
            .help(recording ? "Type the shortcut. Escape cancels." : "Click to record a shortcut")
            .accessibilityLabel(label)
            .accessibilityValue(recording ? "Recording" : combo?.spoken ?? "None")
            .accessibilityHint(recording ? "Type the shortcut, or press Escape to cancel."
                                         : "Press to record a new shortcut.")
            if combo != nil && !recording {
                IconButton(symbol: "xmark.circle.fill", help: "Remove the shortcut") { finish(.clear) }
            }
        }
        .onDisappear { stop() }
    }

    private var title: String {
        if recording { return "Type shortcut…" }
        return combo?.display ?? "Record Shortcut"
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        note = nil
        recording = true
        HotKeys.shared.setSuspended(true)
        Announcement.post("Recording. Type the shortcut, or press Escape to cancel.", high: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let result = KeyCombo.record(keyCode: UInt32(event.keyCode),
                                         modifiers: KeyCombo.carbonModifiers(event.modifierFlags),
                                         characters: event.charactersIgnoringModifiers)
            finish(result)
            return nil   // swallowed: a recorded ⌘W shouldn't also close Settings
        }
    }

    private func finish(_ result: KeyCombo.Recorded) {
        switch result {
        case .combo(let new):
            stop()
            onChange(new)
            Announcement.post("Shortcut set to \(new.spoken).", high: true)
        case .clear:
            stop()
            onChange(nil)
            Announcement.post("Shortcut removed.", high: true)
        case .cancel:
            stop()
        case .needsModifiers:
            note = KeyCombo.modifiersHint   // keep listening
            Announcement.post(KeyCombo.modifiersHint, high: true)
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        // Taking the hot keys back after `onChange` re-registered the new one is harmless: it only re-registers the rest.
        HotKeys.shared.setSuspended(false) { id in
            if id == .jump { JumpShortcut.shared.apply() }   // lost meanwhile: say so under the row
            if id == .window { GlobalShortcut.shared.setEnabled(GlobalShortcut.isEnabled) }
        }
    }
}
