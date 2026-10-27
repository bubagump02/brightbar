import AppKit
import BrightnessKit
import Combine

/// Tinted Dark Mode: while macOS is in Dark Mode, raises the black point of
/// every display through the gamma table, toward a blue-grey, so dark
/// interfaces look lighter and bluer in every app. White stays white.
/// It acts on pixels, not on apps: photos and videos get it too, and
/// screenshots don't show it.
@MainActor
final class DarkTintModel: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "darkTint")
            update(animated: true)
        }
    }
    /// 0-100: how far black is raised.
    @Published var lighten: Double {
        didSet {
            UserDefaults.standard.set(lighten, forKey: "darkTintLighten")
            update(animated: false)
        }
    }
    /// 0-100: neutral grey at 0, slate blue at 100.
    @Published var blue: Double {
        didSet {
            UserDefaults.standard.set(blue, forKey: "darkTintBlue")
            update(animated: false)
        }
    }
    /// macOS is in Dark Mode, so the tint shows when enabled.
    @Published private(set) var dark = Appearance.isDark

    static let defaultLighten = 45.0
    static let defaultBlue = 60.0
    /// Matches the panel's crossfade when Dark Mode switches.
    static let fadeDuration: Duration = .milliseconds(300)

    private var fade: Task<Void, Never>?
    private var themeObserver: NSObjectProtocol?

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: "darkTint")
        lighten = defaults.object(forKey: "darkTintLighten") as? Double ?? Self.defaultLighten
        blue = defaults.object(forKey: "darkTintBlue") as? Double ?? Self.defaultBlue
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Appearance.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                dark = Appearance.isDark
                update(animated: true)
            }
        }
        update(animated: false)
    }

    var isActive: Bool { enabled && dark }

    func resetDefaults() {
        lighten = Self.defaultLighten
        blue = Self.defaultBlue
    }

    /// Slider moves apply at once; switching on or off fades.
    private func update(animated: Bool) {
        let target = isActive ? GammaTint(lighten: Float(lighten / 100), blue: Float(blue / 100)) : .none
        fade?.cancel()
        let start = GammaTables.tint
        guard animated, start != target else {
            GammaTables.tint = target
            return
        }
        fade = Task { @MainActor in
            let steps = 18
            for i in 1...steps {
                guard (try? await Task.sleep(for: Self.fadeDuration / steps)) != nil else { return }
                let t = Float(i) / Float(steps)
                GammaTables.tint = start.mixed(with: target, t * t * (3 - 2 * t))
            }
        }
    }
}
