import AppKit
import BrightnessKit
import Combine
import CoreGraphics

/// Built-in display brightness, kept in sync with changes made outside the app
/// (brightness keys, Control Center).
///
/// `value` is the native backlight (0-100). `level` extends it:
/// -100..<0  sub-zero: native at 0, picture darkened through the gamma table
///  0...100  native backlight only
///  100<..200 XDR: native at 100, EDR overlay brightens past the SDR limit
@MainActor
final class BrightnessModel: ObservableObject {
    @Published private(set) var value: Double = 0
    @Published private(set) var level: Double = 0
    @Published private(set) var status: String?
    @Published private(set) var displayName = L("Built-in Display")

    @Published var subzeroEnabled: Bool {
        didSet {
            UserDefaults.standard.set(subzeroEnabled, forKey: "subzeroEnabled")
            if !subzeroEnabled, level < 0 { setLevel(0) }
        }
    }
    @Published var xdrEnabled: Bool {
        didSet {
            UserDefaults.standard.set(xdrEnabled, forKey: "xdrEnabled")
            if !xdrEnabled, level > 100 { setLevel(100) }
        }
    }

    /// Called when the user moves brightness (slider, F1/F2, Control Center),
    /// not when the app animates it. The auto modes pause on it.
    var onUserChange: (() -> Void)?

    /// Light left at level -100, as a fraction of the native minimum.
    /// Sub-zero is exponential in *luminance*, so every step looks equally
    /// darker; the gamma table acts on the encoded signal, hence the 1/2.2.
    static let subzeroMinLuminance = 0.001
    static let panelGamma = 2.2

    /// Gamma-table multiplier for a sub-zero level (-100...0).
    static func subzeroFactor(_ level: Double) -> Double {
        let luminance = pow(subzeroMinLuminance, -level / 100)
        return pow(luminance, 1 / panelGamma)
    }

    private var control: BuiltinControl?
    private var observer: BrightnessObserver?
    private var gamma: GammaDimmer?
    private let xdr = XDROverlay()

    init() {
        subzeroEnabled = UserDefaults.standard.object(forKey: "subzeroEnabled") as? Bool ?? true
        xdrEnabled = UserDefaults.standard.bool(forKey: "xdrEnabled")
        connect()
    }

    var method: String? { control?.method.rawValue }
    var isAvailable: Bool { control != nil }
    var systemAutoBrightness: Bool { control?.systemAutoBrightness ?? false }
    var xdrSupported: Bool { XDROverlay.isSupported(on: screen) }
    var minLevel: Double { subzeroEnabled ? -100 : 0 }
    var maxLevel: Double { xdrEnabled && xdrSupported ? 200 : 100 }

    var screen: NSScreen? {
        guard let id = control?.id else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    func connect() {
        observer?.invalidate()
        observer = nil
        guard let id = builtinDisplayID() else {
            control = nil
            status = L("Built-in display unavailable (lid closed?)")
            return
        }
        guard let control = BuiltinControl(id: id) else {
            self.control = nil
            status = L("No usable brightness API")
            return
        }
        self.control = control
        status = nil
        displayName = screen?.localizedName ?? L("Built-in Display")
        refresh()
        // BrightnessObserver delivers on the main queue.
        observer = BrightnessObserver(id: id) { [weak self] v in
            MainActor.assumeIsolated { self?.externalChange(Double(v) * 100) }
        }
    }

    func refresh() {
        guard let v = control?.get() else { return }
        value = Double(v) * 100
        // Sub-zero and XDR levels sit outside the native range; keep them.
        if (0...100).contains(level) { level = value }
    }

    /// Slider and brightness keys. `animated` uses the system transition for
    /// the native part.
    func setLevel(_ l: Double, animated: Bool = false, user: Bool = false) {
        let l = min(max(l, minLevel), maxLevel)
        level = l
        // The very bottom of the range is black, as with macOS at 0 %:
        // backlight off. Every level above it stays lit.
        if l <= minLevel {
            clearExtended(keepXDR: false)
            setNative(0, animated: animated, off: true)
            if user { onUserChange?() }
            return
        }
        switch l {
        case ..<0:
            xdr.hide()
            setNative(0, animated: animated)
            if gamma == nil, let id = control?.id { gamma = GammaTables.dimmer(for: id) }
            gamma?.set(factor: Float(Self.subzeroFactor(l)))
        case ...100:
            clearExtended(keepXDR: false)
            setNative(l, animated: animated)
        default:
            restoreGamma()
            setNative(100, animated: animated)
            updateXDR()
        }
        if user { onUserChange?() }
    }

    private func updateXDR() {
        guard level > 100, let screen else { return }
        let headroom = XDROverlay.headroom(of: screen)
        xdr.set(1 + (headroom - 1) * (level - 100) / 100, on: screen)
    }

    /// App-driven changes (auto modes): native only, system transition.
    func animate(to v: Double) {
        clearExtended(keepXDR: false)
        level = min(max(v, 0), 100)
        setNative(level, animated: true)
    }

    /// After a display reconfiguration: the overlay must match the new frame.
    /// macOS also posts this dozens of times while EDR ramps up, so only the
    /// overlay is touched, not the native backlight.
    func screensChanged() {
        updateXDR()
    }

    /// Lowest native value sent unless `off`. On the MacBook Pro XDR panel an
    /// exact 0 switches the backlight off (linear brightness 0), while
    /// anything above it stays at the lit minimum (~0.0048 linear). Sub-zero
    /// must dim from that lit minimum, not from black.
    static let nativeFloor: Float = 0.001

    private func setNative(_ v: Double, animated: Bool, off: Bool = false) {
        value = v
        guard let control else { return }
        let f = off ? 0 : max(Float(v / 100), Self.nativeFloor)
        if animated, control.smoothNative(to: f) { return }
        control.set(f)
    }

    private func clearExtended(keepXDR: Bool) {
        restoreGamma()
        if !keepXDR { xdr.hide() }
    }

    private func restoreGamma() {
        guard let gamma, gamma.factor < 1 else { return }
        gamma.set(factor: 1)
    }

    private func externalChange(_ v: Double) {
        // Our own writes echo back as notifications; ignore near-equal values.
        guard abs(v - value) > 0.5 else { return }
        // Someone else moved the backlight (Control Center, keys without
        // Accessibility): drop sub-zero/XDR and follow.
        clearExtended(keepXDR: false)
        value = v
        level = v
        onUserChange?()
    }
}
