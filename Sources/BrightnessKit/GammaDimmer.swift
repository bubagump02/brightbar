// Software dimming through the display gamma table, for monitors that don't
// take DDC. It only darkens the picture: the
// backlight stays where the monitor's OSD put it. The same table carries the
// tinted Dark Mode's raised black point (GammaTint).
//
// macOS resets gamma tables on display reconfiguration and wake, and restores
// them when the process that set them exits, so the owner must reapply.

import CoreGraphics

public final class GammaDimmer: @unchecked Sendable {
    public let id: CGDirectDisplayID
    /// Lowest factor applied, so 0 % never turns the screen fully black.
    public static let floor: Float = 0.1

    private var red: [CGGammaValue] = []
    private var green: [CGGammaValue] = []
    private var blue: [CGGammaValue] = []
    /// Last requested brightness in 0.0...1.0.
    public private(set) var level: Float = 1
    /// Multiplier applied to the original table.
    public private(set) var factor: Float = 1
    /// Black point raised before the factor applies.
    public private(set) var tint = GammaTint.none

    public init?(id: CGDirectDisplayID) {
        self.id = id
        guard captureOriginal() else { return nil }
    }

    /// Reads the current table as the undimmed reference. Call only while no
    /// dimming is applied (at init, or right after restore()).
    @discardableResult
    func captureOriginal() -> Bool {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 0 else { return false }
        var r = [CGGammaValue](repeating: 0, count: Int(capacity))
        var g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &r, &g, &b, &count) == .success, count > 0 else { return false }
        red = Array(r.prefix(Int(count)))
        green = Array(g.prefix(Int(count)))
        blue = Array(b.prefix(Int(count)))
        return true
    }

    /// Dims to `level` (0.0...1.0); 1.0 restores the original table.
    @discardableResult
    public func set(_ level: Float) -> Bool {
        self.level = min(max(level, 0), 1)
        factor = Self.floor + (1 - Self.floor) * self.level
        return apply()
    }

    /// Raw multiplier (0.0...1.0) with no floor, for sub-zero dimming of the
    /// built-in panel where the caller owns the curve.
    @discardableResult
    public func set(factor: Float) -> Bool {
        self.factor = min(max(factor, 0), 1)
        level = self.factor
        return apply()
    }

    /// Raises the black point; GammaTint.none restores it. The dimming factor
    /// still applies on top.
    @discardableResult
    public func set(tint: GammaTint) -> Bool {
        self.tint = tint
        return apply()
    }

    /// Neither dimmed nor tinted: the table on screen is the reference.
    public var isIdentity: Bool { factor >= 1 && tint == .none }

    /// Re-sends the last tint and factor, after macOS reset the table.
    @discardableResult
    public func apply() -> Bool {
        let (r, g, b) = tables()
        return CGSetDisplayTransferByTable(id, UInt32(r.count), r, g, b) == .success
    }

    private func tables() -> ([CGGammaValue], [CGGammaValue], [CGGammaValue]) {
        let f = factor
        func curve(_ table: [CGGammaValue], _ lift: Float) -> [CGGammaValue] {
            table.map { (lift + (1 - lift) * $0) * f }
        }
        return (curve(red, tint.red), curve(green, tint.green), curve(blue, tint.blue))
    }

    /// The table on screen is still the one apply() sent: macOS hasn't reset it.
    func isOnScreen() -> Bool {
        let capacity = UInt32(red.count)
        var r = [CGGammaValue](repeating: 0, count: Int(capacity))
        var g = r, b = r
        var count: UInt32 = 0
        guard capacity > 0, CGGetDisplayTransferByTable(id, capacity, &r, &g, &b, &count) == .success,
              count == capacity else { return false }
        let sent = tables()
        func same(_ x: [CGGammaValue], _ y: [CGGammaValue]) -> Bool {
            zip(x, y).allSatisfy { abs($0 - $1) < 0.002 }
        }
        return same(r, sent.0) && same(g, sent.1) && same(b, sent.2)
    }

    /// After a reconfiguration or wake: if macOS reset a table we changed, go
    /// back to the ColorSync tables (they may have changed, e.g. a new color
    /// profile), re-read them as the reference, then dim and tint again.
    /// macOS posts reconfigurations dozens of times while EDR ramps up; when
    /// every table is still on screen nothing is touched, so the tint doesn't
    /// flicker.
    public static func reapply(_ dimmers: [GammaDimmer]) {
        // An offline display has no table to check; it gets reapplied once
        // it's back, since its new table won't match.
        let changed = dimmers.filter { !$0.isIdentity && CGDisplayIsOnline($0.id) != 0 }
        // Untouched tables are the ColorSync ones: re-read them as they are.
        for d in dimmers where d.isIdentity { d.captureOriginal() }
        guard changed.contains(where: { !$0.isOnScreen() }) else { return }
        CGDisplayRestoreColorSyncSettings()
        for d in changed {
            d.captureOriginal()
            d.apply()
        }
    }

    /// Reads back what's applied now, as a factor of the original table
    /// (1.0 = undimmed). For checks and tests.
    public func appliedFactor() -> Float? {
        let capacity = UInt32(red.count)
        var r = [CGGammaValue](repeating: 0, count: Int(capacity))
        var g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &r, &g, &b, &count) == .success,
              let i = red.indices.last, red[i] > 0 else { return nil }
        return r[i] / red[i]
    }
}

/// Black point of the tinted Dark Mode, per channel, in the encoded signal
/// (0...1). The table maps x to lift + (1 - lift) * x: black becomes this
/// color, white stays white, everything in between is lifted less and less.
public struct GammaTint: Equatable, Sendable {
    public var red: Float
    public var green: Float
    public var blue: Float

    public init(red: Float, green: Float, blue: Float) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let none = GammaTint(red: 0, green: 0, blue: 0)

    /// Black point at lighten 1, before the blue shift.
    public static let maxLift: Float = 0.2

    /// `lighten` and `blue` in 0...1. Blue 0 lifts black to a neutral grey;
    /// blue 1 leans it toward slate blue (red x0.4, green x0.7, blue x1.6).
    /// At BrightBar's defaults (0.45, 0.6), black becomes #0F131F and #1E1E1E,
    /// a common dark background, becomes #2B2F3A.
    public init(lighten: Float, blue: Float) {
        let lift = Self.maxLift * min(max(lighten, 0), 1)
        let shift = min(max(blue, 0), 1)
        self.init(red: lift * (1 - 0.6 * shift), green: lift * (1 - 0.3 * shift), blue: lift * (1 + 0.6 * shift))
    }

    /// Linear blend toward `other`, for fades (t in 0...1).
    public func mixed(with other: GammaTint, _ t: Float) -> GammaTint {
        GammaTint(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t
        )
    }
}
