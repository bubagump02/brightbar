// ⌃⌥⌘D toggles Dark Mode from anywhere. A Carbon hot key rather than the
// brightness-key tap: it needs no Accessibility permission, and macOS
// swallows the key press only for BrightBar. Free on macOS and in Magnet,
// which takes ⌃⌥ + letters and ⌃⌥⌘ + arrows.

import BrightnessKit
import Carbon.HIToolbox

@MainActor
final class DarkModeHotKey {
    static let label = "⌃⌥⌘D"

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Runs on the main thread. The panel's toggle follows through
        // Appearance.changedNotification.
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Appearance.setDark(!Appearance.isDark)
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x4242_444D), id: 1) // 'BBDM'
        RegisterEventHotKey(
            UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey | cmdKey), id,
            GetApplicationEventTarget(), 0, &hotKey
        )
    }
}
