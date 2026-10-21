import AppKit
import BrightnessKit
import Combine

/// Drives brightness from the time of day or the ambient light sensor.
/// A manual change (slider, F1/F2) pauses it: until the next schedule point,
/// or for 30 minutes in sensor mode.
@MainActor
final class AutoBrightness: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case manual, schedule, sensor
        var id: String { rawValue }
        var title: String {
            switch self {
            case .manual: "Manuel"
            case .schedule: "Horaires"
            case .sensor: "Capteur"
            }
        }
    }

    @Published var mode: Mode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "autoMode")
            pausedUntil = nil
            smoothedLux = nil
            restart()
        }
    }
    @Published var points: [SchedulePoint] {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(points), forKey: "schedulePoints")
            if mode == .schedule { tick() }
        }
    }
    /// Shifts the lux curve, -30...+30.
    @Published var luxOffset: Double {
        didSet {
            UserDefaults.standard.set(luxOffset, forKey: "luxOffset")
            if mode == .sensor { tick() }
        }
    }
    @Published private(set) var lux: Double?
    @Published private(set) var target: Double?
    @Published private(set) var pausedUntil: Date?

    let sensorAvailable: Bool
    private let sensor = AmbientLightSensor()
    private var smoothedLux: Double?
    private var timer: Timer?
    private let builtin: BrightnessModel
    private let externals: ExternalDisplaysModel

    init(builtin: BrightnessModel, externals: ExternalDisplaysModel) {
        self.builtin = builtin
        self.externals = externals
        sensorAvailable = sensor?.lux() != nil
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: "autoMode") ?? "") ?? .manual
        points = UserDefaults.standard.data(forKey: "schedulePoints")
            .flatMap { try? JSONDecoder().decode([SchedulePoint].self, from: $0) } ?? ScheduleCurve.defaultPoints
        luxOffset = UserDefaults.standard.double(forKey: "luxOffset")

        builtin.onUserChange = { [weak self] in self?.userChanged() }
        restart()
    }

    func resume() {
        pausedUntil = nil
        tick()
    }

    func resetSchedule() {
        points = ScheduleCurve.defaultPoints
    }

    var nextPoint: (date: Date, point: SchedulePoint)? {
        guard let p = ScheduleCurve.nextPoint(after: Self.minuteNow(), points: points) else { return nil }
        return (Self.date(forMinute: p.minute), p)
    }

    private func restart() {
        timer?.invalidate()
        timer = nil
        target = nil
        guard mode != .manual else { return }
        // The sensor reacts within seconds; the schedule moves slowly.
        let interval: TimeInterval = mode == .sensor ? 1 : 30
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    private func tick() {
        let goal: Double?
        let threshold: Double
        switch mode {
        case .manual:
            return
        case .schedule:
            goal = ScheduleCurve.brightness(at: Self.minuteNow(), points: points)
            threshold = 1
        case .sensor:
            guard let raw = sensor?.lux() else { lux = nil; return }
            // Light smoothing so a passing shadow doesn't pump the backlight.
            let s = smoothedLux.map { $0 + 0.25 * (raw - $0) } ?? raw
            smoothedLux = s
            lux = s
            goal = LuxCurve.brightness(lux: s, offset: luxOffset)
            // Wider dead band than the schedule: lux readings jitter.
            threshold = 3
        }
        guard let goal else { return }
        target = goal.rounded()

        if let until = pausedUntil {
            guard Date() >= until else { return }
            pausedUntil = nil
        }
        let current = builtin.isAvailable ? builtin.value : (externals.items.compactMap(\.value).first ?? -100)
        guard abs(goal - current) >= threshold else { return }
        apply(goal.rounded())
    }

    private func apply(_ v: Double) {
        if builtin.isAvailable {
            // Externals follow through the "follow the MacBook" option.
            builtin.animate(to: v)
        } else {
            // Lid closed: drive the monitors directly.
            externals.setAll(v)
        }
    }

    private func userChanged() {
        guard mode != .manual else { return }
        switch mode {
        case .schedule: pausedUntil = nextPoint?.date
        case .sensor: pausedUntil = Date().addingTimeInterval(30 * 60)
        case .manual: break
        }
    }

    private static func minuteNow() -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Next occurrence of a time of day, today or tomorrow.
    static func date(forMinute minute: Int) -> Date {
        let cal = Calendar.current
        let today = cal.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        return today > Date() ? today : cal.date(byAdding: .day, value: 1, to: today) ?? today
    }
}
