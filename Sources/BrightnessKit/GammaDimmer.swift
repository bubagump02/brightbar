// Software dimming through the display gamma table, for monitors that don't
// take DDC. It only darkens the picture: the
// backlight stays where the monitor's OSD put it.
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

    /// Re-sends the last factor, after macOS reset the table.
    @discardableResult
    public func apply() -> Bool {
        let f = factor
        let r = red.map { $0 * f }, g = green.map { $0 * f }, b = blue.map { $0 * f }
        return CGSetDisplayTransferByTable(id, UInt32(r.count), r, g, b) == .success
    }

    /// After a reconfiguration or wake: go back to the ColorSync tables (they
    /// may have changed, e.g. a new color profile), re-read them as the
    /// reference, then dim again.
    public static func reapply(_ dimmers: [GammaDimmer]) {
        guard !dimmers.isEmpty else { return }
        CGDisplayRestoreColorSyncSettings()
        for d in dimmers {
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
