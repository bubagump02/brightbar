import BrightnessKit
import Combine

/// Keyboard backlight for the panel's slider and ⌃F1/⌃F2, kept
/// in sync with changes made from Control Center or by macOS's auto mode.
@MainActor
final class KeyboardModel: ObservableObject {
    /// 0...100, nil when the Mac has no backlit keyboard.
    @Published private(set) var value: Double?

    private let backlight = KeyboardBacklight()

    init() {
        refresh()
        backlight?.observe { [weak self] v in self?.value = Double(v) * 100 }
    }

    var isAvailable: Bool { backlight != nil }

    func refresh() {
        guard let backlight else { return }
        value = backlight.brightness.map { Double($0) * 100 }
    }

    func set(_ v: Double) {
        let v = min(max(v, 0), 100)
        backlight?.set(Float(v / 100))
        value = v
    }
}
