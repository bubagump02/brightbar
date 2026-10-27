import AppKit
import BrightnessKit
import Combine

/// External monitors and their brightness: DDC/CI when the monitor answers,
/// software dimming through the gamma table otherwise. DDC reads block for
/// tens of milliseconds, so discovery runs off the main thread.
@MainActor
final class ExternalDisplaysModel: ObservableObject {
    enum Control {
        /// Hardware backlight; `max` is the monitor's native maximum (often 100).
        case ddc(DDCChannel, max: Int)
        /// Picture darkened through the gamma table; backlight untouched.
        case gamma(GammaDimmer)
    }

    struct Item: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        let control: Control?
        /// 0-100, nil when no control is available.
        var value: Double?

        var isSoftware: Bool {
            if case .gamma = control { return true }
            return false
        }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var loading = false
    /// Mirror the built-in brightness (and so the F1/F2 keys) to every monitor.
    @Published var followBuiltin: Bool {
        didSet { UserDefaults.standard.set(followBuiltin, forKey: "followBuiltin") }
    }

    /// Monitors dimmed in software. The dimmers themselves come from
    /// GammaTables, which keeps them across reloads.
    private var dimmers: [CGDirectDisplayID: GammaDimmer] = [:]
    private var observers: [NSObjectProtocol] = []
    private var builtinSub: AnyCancellable?

    init(builtin: Published<Double>.Publisher) {
        followBuiltin = UserDefaults.standard.bool(forKey: "followBuiltin")
        reload()

        // macOS resets gamma tables on reconfiguration and wake.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reapplyGamma()
                self?.onScreensChanged?()
                self?.reload()
            }
        })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reapplyGamma() }
            })
        }

        builtinSub = builtin
            .removeDuplicates()
            .sink { [weak self] v in
                MainActor.assumeIsolated {
                    guard let self, self.followBuiltin else { return }
                    self.setAll(v)
                }
            }
    }

    func reload() {
        loading = true
        Task.detached(priority: .userInitiated) {
            let found = externalDisplays().map { d in (d, d.ddc?.read(.brightness)) }
            await MainActor.run { self.apply(found) }
        }
    }

    private func apply(_ found: [(ExternalDisplay, (current: Int, max: Int)?)]) {
        let online = Set(found.map(\.0.id))
        for (id, dimmer) in dimmers where !online.contains(id) {
            dimmer.set(1)
            dimmers[id] = nil
        }

        items = found.map { d, reading in
            let name = Self.screenName(d.id) ?? d.name
            if let ddc = d.ddc, let reading {
                // DDC answers now: drop any software dimming left on this screen.
                if let dimmer = dimmers.removeValue(forKey: d.id) { dimmer.set(1) }
                let value = Double(reading.current) * 100 / Double(max(reading.max, 1))
                return Item(id: d.id, name: name, control: .ddc(ddc, max: reading.max), value: value)
            }
            guard let dimmer = dimmer(for: d.id) else {
                return Item(id: d.id, name: name, control: nil, value: nil)
            }
            return Item(id: d.id, name: name, control: .gamma(dimmer), value: Double(dimmer.level) * 100)
        }
        loading = false
    }

    private func dimmer(for id: CGDirectDisplayID) -> GammaDimmer? {
        if let d = dimmers[id] { return d }
        guard let d = GammaTables.dimmer(for: id) else { return nil }
        dimmers[id] = d
        // Restore the level saved for this monitor across launches.
        if let saved = UserDefaults.standard.object(forKey: Self.gammaKey(id)) as? Double {
            d.set(Float(saved / 100))
        }
        return d
    }

    func set(_ id: CGDirectDisplayID, _ v: Double) {
        guard let i = items.firstIndex(where: { $0.id == id }), let control = items[i].control else { return }
        let v = min(max(v, 0), 100)
        items[i].value = v
        switch control {
        case let .ddc(ddc, max):
            ddc.write(.brightness, Int((v * Double(max) / 100).rounded()))
        case let .gamma(dimmer):
            dimmer.set(Float(v / 100))
            UserDefaults.standard.set(v, forKey: Self.gammaKey(id))
        }
    }

    func setAll(_ v: Double) {
        for item in items { set(item.id, v) }
    }

    /// Called after a display reconfiguration, once gamma is reapplied.
    var onScreensChanged: (() -> Void)?

    private func reapplyGamma() {
        GammaTables.reapply()
    }

    /// Per monitor, not per display id: ids change across reconnections.
    private static func gammaKey(_ id: CGDirectDisplayID) -> String {
        "gamma.\(CGDisplayVendorNumber(id)):\(CGDisplayModelNumber(id)):\(CGDisplaySerialNumber(id))"
    }

    private static func screenName(_ id: CGDirectDisplayID) -> String? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }?.localizedName
    }
}
