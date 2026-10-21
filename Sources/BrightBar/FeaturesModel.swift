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

    func toggleDark() {
        Appearance.setDark(!dark)
        dark.toggle()
    }

    func toggleNightShift() {
        guard let s = nightShift else { return }
        night.setEnabled(!s.enabled)
        nightShift?.enabled.toggle()
    }

    func toggleTrueTone() {
        tone.setEnabled(!trueTone)
        trueTone.toggle()
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
