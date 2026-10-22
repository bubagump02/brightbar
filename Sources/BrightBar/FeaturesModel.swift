import AppKit
import BrightnessKit
import Combine

/// Dark Mode, Night Shift and True Tone state for the panel's toggles, kept in
/// sync with changes made from System Settings or Control Center.
@MainActor
final class FeaturesModel: ObservableObject {
    @Published private(set) var dark = false
    @Published private(set) var darkAuto = false
    @Published private(set) var nightShift: NightShift.Status?
    @Published private(set) var trueToneSupported = false
    @Published private(set) var trueTone = false

    private let night = NightShift()
    private let tone = TrueTone()
    private var themeObserver: NSObjectProtocol?

    init() {
        refresh()
        night.observe { [weak self] in self?.refresh() }
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Appearance.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        dark = Appearance.isDark
        darkAuto = Appearance.switchesAutomatically
        nightShift = night.status
        trueToneSupported = tone.isSupported
        trueTone = tone.isEnabled
    }

    // Each toggle flips its state at once and applies it to the system once
    // the toggle has animated: the system calls can stall the main thread
    // (Dark Mode redraws every window), which would freeze it mid-animation.
    // Applying whatever the state is by then also absorbs a quick double click.

    func toggleDark() {
        dark.toggle()
        afterToggleAnimation { [weak self] in
            guard let self, dark != Appearance.isDark else { return }
            Self.crossfadeKeyWindow(dark: dark)
            Appearance.setDark(dark)
        }
    }

    func toggleNightShift() {
        guard nightShift != nil else { return }
        nightShift?.enabled.toggle()
        afterToggleAnimation { [weak self] in
            guard let self, let want = nightShift?.enabled, night.status?.enabled != want else { return }
            night.setEnabled(want)
        }
    }

    func toggleTrueTone() {
        trueTone.toggle()
        afterToggleAnimation { [weak self] in
            guard let self, tone.isEnabled != trueTone else { return }
            tone.setEnabled(trueTone)
        }
    }

    /// Matches ToggleCircle's animation.
    static let toggleAnimationDuration: Duration = .milliseconds(250)

    private func afterToggleAnimation(_ apply: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: Self.toggleAnimationDuration)
            apply()
        }
    }

    /// Crossfades the panel into the new appearance instead of letting it snap
    /// when the system switches: the window takes the target appearance right
    /// away, under a fade, then follows the system again once it has caught up.
    private static func crossfadeKeyWindow(dark: Bool) {
        guard let window = NSApp.keyWindow,
              let layer = window.contentView?.superview?.layer ?? window.contentView?.layer
        else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.3
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "appearance")
        let previous = window.appearance
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            window.appearance = previous
        }
    }

    var darkSubtitle: String {
        darkAuto ? (dark ? "Activé · Auto" : "Désactivé · Auto") : (dark ? "Activé" : "Désactivé")
    }

    var nightShiftSubtitle: String {
        guard let s = nightShift else { return "Indisponible" }
        let state = s.enabled ? "Activé" : "Désactivé"
        switch s.schedule {
        case .off: return state
        case .sunsetToSunrise: return state + " · Coucher/lever"
        case .custom:
            let t = s.enabled ? s.to : s.from
            return state + String(format: " · jusqu'à %02d:%02d", t.0, t.1)
        }
    }

    static func openDisplaySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    }
}
