// Built-in panel brightness, mirroring Lunar's AppleNativeControl:
// DisplayServices first, CoreDisplay as fallback, values in 0.0...1.0.

import CoreGraphics
import Foundation

public enum BrightnessMethod: String, Sendable {
    case displayServices = "ds"
    case coreDisplay = "cd"
}

public struct BuiltinControl: Sendable {
    public let id: CGDirectDisplayID
    public let method: BrightnessMethod
    let api: NativeAPI

    public init?(id: CGDirectDisplayID, forced: BrightnessMethod? = nil, api: NativeAPI = .shared) {
        guard let method = Self.pick(id: id, api: api, forced: forced) else { return nil }
        self.id = id
        self.method = method
        self.api = api
    }

    /// Same order as Lunar: DisplayServices first, CoreDisplay as fallback.
    static func pick(id: CGDirectDisplayID, api: NativeAPI, forced: BrightnessMethod?) -> BrightnessMethod? {
        switch forced {
        case .displayServices?: return supports(.displayServices, id: id, api: api) ? .displayServices : nil
        case .coreDisplay?: return supports(.coreDisplay, id: id, api: api) ? .coreDisplay : nil
        case nil:
            if supports(.displayServices, id: id, api: api) { return .displayServices }
            return supports(.coreDisplay, id: id, api: api) ? .coreDisplay : nil
        }
    }

    /// Lunar's availability check: trust DisplayServicesCanChangeBrightness, else
    /// write current ±0.01, read it back, restore. On macOS 26 CoreDisplay's
    /// user-brightness setter is a no-op on the built-in panel, so the probe matters.
    public static func supports(_ m: BrightnessMethod, id: CGDirectDisplayID, api: NativeAPI = .shared) -> Bool {
        switch m {
        case .displayServices:
            guard let get = api.dsGet, let set = api.dsSet else { return false }
            if api.canChange?(id) == true { return true }
            var b: Float = 0
            guard get(id, &b) == 0 else { return false }
            let probe = b + (b < 0.5 ? 0.01 : -0.01)
            guard set(id, probe) == 0 else { return false }
            var r: Float = 0
            let ok = get(id, &r) == 0 && abs(r - probe) < 0.0001
            _ = set(id, b)
            return ok
        case .coreDisplay:
            guard let get = api.cdGet, let set = api.cdSet else { return false }
            let b = get(id)
            let probe = b + (b < 0.5 ? 0.01 : -0.01)
            set(id, probe)
            let ok = abs(get(id) - probe) < 0.0001
            set(id, b)
            return ok
        }
    }

    /// macOS's own "Automatically adjust brightness" is on for this display.
    /// It moves brightness behind our back, so the auto modes need it off.
    public var systemAutoBrightness: Bool {
        guard api.dsHasALC?(id) == true, let enabled = api.dsALCEnabled else { return false }
        var on = false
        _ = enabled(id, &on)
        return on
    }

    /// Brightness in 0.0...1.0.
    public func get() -> Float? {
        switch method {
        case .displayServices:
            var v: Float = 0
            return api.dsGet!(id, &v) == 0 ? v : nil
        case .coreDisplay:
            return Float(api.cdGet!(id))
        }
    }

    @discardableResult
    public func set(_ v: Float) -> Bool {
        let v = min(max(v, 0), 1)
        switch method {
        case .displayServices:
            return api.dsSet!(id, v) == 0
        case .coreDisplay:
            api.cdSet!(id, Double(v))
            return true
        }
    }

    /// Starts the system's animated transition and returns immediately.
    /// The animation runs for ~0.2-0.5s and get() already reports the target,
    /// so a write issued during it gets overwritten. Returns false when the
    /// native call is unavailable.
    @discardableResult
    public func smoothNative(to target: Float) -> Bool {
        guard method == .displayServices, let setSmooth = api.dsSetSmooth, let current = get() else { return false }
        return setSmooth(id, min(max(target, 0), 1) - current) == 0
    }

    /// No duration: native animated transition (system-timed, blocks until it
    /// settles). With a duration, or without DisplayServicesSetBrightnessSmooth:
    /// manual stepped loop (Lunar's "slow" path uses 0.002 per step; a coarser
    /// step keeps it short).
    public func smooth(to target: Float, duration: Double?) -> Bool {
        let target = min(max(target, 0), 1)
        guard let current = get() else { return false }

        if duration == nil, smoothNative(to: target) {
            Thread.sleep(forTimeInterval: 0.6)
            return true
        }

        let duration = duration ?? 0.5
        let steps = max(1, Int(duration / 0.01))
        for i in 1...steps {
            set(current + (target - current) * Float(i) / Float(steps))
            Thread.sleep(forTimeInterval: duration / Double(steps))
        }
        return set(target)
    }
}
