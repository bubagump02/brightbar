import BrightnessKit
import CoreGraphics

/// One GammaDimmer per display, shared by sub-zero, the software dimming of
/// external monitors and the tinted Dark Mode. A dimmer captures the table as
/// its untouched reference, so a second one on the same display would capture
/// the first one's output and compound it.
@MainActor
enum GammaTables {
    private static var dimmers: [CGDirectDisplayID: GammaDimmer] = [:]

    /// Tinted Dark Mode black point, applied to every online display.
    static var tint = GammaTint.none {
        didSet {
            guard tint != oldValue else { return }
            if tint != .none { coverOnlineDisplays() }
            for d in dimmers.values { d.set(tint: tint) }
        }
    }

    static func dimmer(for id: CGDirectDisplayID) -> GammaDimmer? {
        if let d = dimmers[id] { return d }
        guard let d = GammaDimmer(id: id) else { return nil }
        dimmers[id] = d
        if tint != .none { d.set(tint: tint) }
        return d
    }

    /// After a reconfiguration or wake: macOS resets every table. A display
    /// that just came online gets the tint too.
    static func reapply() {
        GammaDimmer.reapply(Array(dimmers.values))
        if tint != .none { coverOnlineDisplays() }
    }

    private static func coverOnlineDisplays() {
        for id in onlineDisplayIDs() { _ = dimmer(for: id) }
    }
}
