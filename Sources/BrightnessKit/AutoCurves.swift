// Pure brightness curves for the auto modes: time of day and ambient lux.

import Foundation

/// A brightness target at a time of day.
public struct SchedulePoint: Codable, Hashable, Identifiable, Sendable {
    /// Stable identity for list editing; not persisted.
    public var id = UUID()
    /// Minutes since midnight, 0..<1440.
    public var minute: Int
    /// 0...100.
    public var brightness: Double

    public init(minute: Int, brightness: Double) {
        self.minute = minute
        self.brightness = brightness
    }

    public init(hour: Int, minute: Int = 0, brightness: Double) {
        self.init(minute: hour * 60 + minute, brightness: brightness)
    }

    private enum CodingKeys: String, CodingKey {
        case minute, brightness
    }
}

public enum ScheduleCurve {
    // Equal values at 22:30 and 06:30 keep the night flat instead of ramping
    // up from midnight.
    public static let defaultPoints = [
        SchedulePoint(hour: 6, minute: 30, brightness: 35),
        SchedulePoint(hour: 8, brightness: 70),
        SchedulePoint(hour: 10, brightness: 90),
        SchedulePoint(hour: 17, brightness: 90),
        SchedulePoint(hour: 20, brightness: 60),
        SchedulePoint(hour: 22, minute: 30, brightness: 35),
    ]

    /// Linear interpolation between neighbouring points, wrapping past midnight.
    public static func brightness(at minute: Int, points: [SchedulePoint]) -> Double? {
        let p = points.sorted { $0.minute < $1.minute }
        guard let first = p.first, let last = p.last else { return nil }
        if p.count == 1 { return first.brightness }

        // Previous point at or before `minute`, else last point of the day before.
        let prevIndex = p.lastIndex { $0.minute <= minute }
        let prev = prevIndex.map { p[$0] } ?? last
        let next = prevIndex.map { $0 + 1 < p.count ? p[$0 + 1] : first } ?? first

        var span = next.minute - prev.minute
        if span <= 0 { span += 1440 }
        var elapsed = minute - prev.minute
        if elapsed < 0 { elapsed += 1440 }
        let t = Double(elapsed) / Double(span)
        return prev.brightness + (next.brightness - prev.brightness) * t
    }

    /// Next point strictly after `minute`, wrapping to tomorrow.
    public static func nextPoint(after minute: Int, points: [SchedulePoint]) -> SchedulePoint? {
        let p = points.sorted { $0.minute < $1.minute }
        return p.first { $0.minute > minute } ?? p.first
    }
}

public enum LuxCurve {
    /// (lux, brightness) anchors, interpolated on log10(lux + 1): perceived
    /// brightness tracks the logarithm of illuminance.
    static let anchors: [(lux: Double, brightness: Double)] = [
        (0, 15), (10, 30), (100, 55), (500, 80), (2000, 100),
    ]

    /// `offset` shifts the whole curve (user preference, e.g. -20...+20).
    public static func brightness(lux: Double, offset: Double = 0) -> Double {
        let x = log10(max(lux, 0) + 1)
        let pts = anchors.map { (log10($0.lux + 1), $0.brightness) }
        let b: Double
        if x <= pts[0].0 {
            b = pts[0].1
        } else if let i = pts.indices.dropFirst().first(where: { x <= pts[$0].0 }) {
            let (x0, y0) = pts[i - 1], (x1, y1) = pts[i]
            b = y0 + (y1 - y0) * (x - x0) / (x1 - x0)
        } else {
            b = pts[pts.count - 1].1
        }
        return min(max(b + offset, 0), 100)
    }
}
