// Intercepts the brightness keys (F1/F2), ⌃F1/⌃F2 and the keyboard
// illumination keys of Macs that have them, before macOS handles them, so the system OSD doesn't
// show and BrightBar applies the change itself. Same idea
// as Lunar's MediaKeyTap: a session event tap on NSSystemDefined events.
// Needs the Accessibility permission.

import AppKit
import ApplicationServices

@MainActor
final class BrightnessKeys: ObservableObject {
    enum Key { case up, down, keyboardUp, keyboardDown }

    /// Accessibility granted and the tap is running.
    @Published private(set) var active = false

    /// (key, fine step: ⌥⇧ held). Return true to swallow the event.
    var onKey: ((Key, Bool) -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var permissionTimer: Timer?

    // NX_KEYTYPE_* from IOKit/hidsystem/ev_keymap.h
    private static let brightnessUp = 2
    private static let brightnessDown = 3
    private static let illuminationUp = 21
    private static let illuminationDown = 22
    // NX_SUBTYPE_AUX_CONTROL_BUTTONS
    private static let auxControlButtons: Int16 = 8

    func start(prompt: Bool) {
        guard tap == nil else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            // Install as soon as the user flips the switch in System Settings.
            permissionTimer?.invalidate()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard AXIsProcessTrusted() else { return }
                    self?.permissionTimer?.invalidate()
                    self?.start(prompt: false)
                }
            }
            return
        }
        install()
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func install() {
        let mask = CGEventMask(1) << 14 // NSEventType.systemDefined
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: keyEventCallback, userInfo: refcon
        ) else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        active = true
    }

    /// Runs on the main run loop (the tap's source is on it).
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables slow or idle taps; turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == Self.auxControlButtons else {
            return Unmanaged.passUnretained(event)
        }
        let data = ns.data1
        let code = (data & 0xFFFF_0000) >> 16
        let isDown = ((data & 0xFF00) >> 8) == 0xA
        // ⌃F1/⌃F2 drive the keyboard backlight: the 14"/16" Apple Silicon
        // MacBook Pros have no illumination keys. macOS only binds ⌃ with fn
        // (⌃F1 keyboard access, ⌃F2 menu bar focus), so this one is free.
        let control = ns.modifierFlags.contains(.control)
        let key: Key
        switch code {
        case Self.brightnessUp: key = control ? .keyboardUp : .up
        case Self.brightnessDown: key = control ? .keyboardDown : .down
        case Self.illuminationUp: key = .keyboardUp
        case Self.illuminationDown: key = .keyboardDown
        default: return Unmanaged.passUnretained(event)
        }
        // Treat key-up like its key-down, or macOS would see half a key press.
        guard isDown else { return swallowedDown ? nil : Unmanaged.passUnretained(event) }
        let fine = ns.modifierFlags.contains([.option, .shift])
        swallowedDown = onKey?(key, fine) ?? false
        return swallowedDown ? nil : Unmanaged.passUnretained(event)
    }

    private var swallowedDown = false
}

private func keyEventCallback(
    proxy _: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let keys = Unmanaged<BrightnessKeys>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated { keys.handle(type, event) }
}
