import BrightnessKit
import Charts
import SwiftUI

/// Mode picker and one status line, under the brightness slider.
struct AutoSection: View {
    @ObservedObject var auto: AutoBrightness
    let systemAutoBrightness: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: $auto.mode) {
                    ForEach(AutoBrightness.Mode.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button {
                    openWindow(id: "auto")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .help("Réglages : horaires, capteur, ouverture de session, quitter")
            }

            if let line = statusLine {
                HStack(spacing: 6) {
                    Text(line).font(.caption).foregroundStyle(.secondary)
                    if auto.pausedUntil != nil {
                        Button("Reprendre", action: auto.resume)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }

            if auto.mode != .manual, systemAutoBrightness {
                Text("Désactive « Régler automatiquement la luminosité » dans Réglages › Moniteurs, sinon macOS et BrightBar se contredisent.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusLine: String? {
        if let until = auto.pausedUntil {
            return "En pause (réglage manuel) jusqu'à \(until.formatted(date: .omitted, time: .shortened))"
        }
        switch auto.mode {
        case .manual:
            return nil
        case .schedule:
            guard let t = auto.target else { return nil }
            var s = "Cible \(Int(t)) %"
            if let next = auto.nextPoint {
                s += " · \(next.date.formatted(date: .omitted, time: .shortened)) → \(Int(next.point.brightness)) %"
            }
            return s
        case .sensor:
            guard auto.sensorAvailable else { return "Pas de capteur de lumière" }
            guard let lux = auto.lux, let t = auto.target else { return "Capteur sans mesure (capot fermé ?)" }
            return "\(Int(lux.rounded())) lux → \(Int(t)) %"
        }
    }
}

/// Settings window: schedule points with a 24 h preview, and the sensor curve offset.
struct AutoSettingsView: View {
    @ObservedObject var auto: AutoBrightness
    @ObservedObject var login: LaunchAtLogin

    var body: some View {
        Form {
            Section("Général") {
                Toggle("Ouvrir à l'ouverture de session", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                    .disabled(!login.isInstalled)
                if !login.isInstalled {
                    Text("Installe l'app dans Applications (scripts/install.sh) pour l'activer.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if login.needsApproval {
                    Button("Autoriser dans Éléments de connexion…", action: LaunchAtLogin.openLoginItemsSettings)
                        .buttonStyle(.link).font(.caption)
                } else if let error = login.error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button("Quitter BrightBar") { NSApplication.shared.terminate(nil) }
                }
            }

            Section("Horaires") {
                ScheduleChart(points: auto.points)
                    .frame(height: 120)
                ForEach(auto.points.sorted { $0.minute < $1.minute }) { point in
                    HStack {
                        DatePicker("", selection: timeBinding(point.id), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .frame(width: 90)
                        Slider(value: brightnessBinding(point.id), in: 0...100, step: 1)
                        Text("\(Int(point.brightness)) %")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                        Button {
                            auto.points.removeAll { $0.id == point.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(auto.points.count <= 1)
                    }
                }
                HStack {
                    Button("Ajouter un point") {
                        auto.points.append(SchedulePoint(hour: 12, brightness: 80))
                    }
                    Spacer()
                    Button("Valeurs par défaut", action: auto.resetSchedule)
                }
                Text("La luminosité varie en ligne droite d'un point au suivant. Un réglage manuel met le mode en pause jusqu'au point suivant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Capteur de lumière") {
                if auto.sensorAvailable {
                    HStack {
                        Text("Plus sombre")
                        Slider(value: $auto.luxOffset, in: -30...30, step: 1)
                        Text("Plus clair")
                    }
                    if let lux = auto.lux {
                        Text("Maintenant : \(Int(lux.rounded())) lux → \(Int(LuxCurve.brightness(lux: lux, offset: auto.luxOffset))) %")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Repères : pièce sombre ≈ 10 lux, bureau ≈ 300 lux, près d'une fenêtre ≈ 2 000 lux. Un réglage manuel met le mode en pause 30 minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Ce Mac n'a pas de capteur de lumière ambiante.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh() }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    // Bindings look the point up by id, so a row being torn down after a
    // delete reads a harmless default instead of an out-of-range index.
    private func timeBinding(_ id: UUID) -> Binding<Date> {
        Binding(
            get: {
                let m = auto.points.first { $0.id == id }?.minute ?? 0
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                guard let i = auto.points.firstIndex(where: { $0.id == id }) else { return }
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                auto.points[i].minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        )
    }

    private func brightnessBinding(_ id: UUID) -> Binding<Double> {
        Binding(
            get: { auto.points.first { $0.id == id }?.brightness ?? 0 },
            set: { v in
                guard let i = auto.points.firstIndex(where: { $0.id == id }) else { return }
                auto.points[i].brightness = v
            }
        )
    }
}

/// 24 h preview of the schedule curve, with a "now" marker.
struct ScheduleChart: View {
    let points: [SchedulePoint]

    var body: some View {
        let samples = stride(from: 0, through: 1440, by: 15).map { m in
            (hour: Double(m) / 60, value: ScheduleCurve.brightness(at: m % 1440, points: points) ?? 0)
        }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60

        Chart {
            ForEach(samples, id: \.hour) { s in
                AreaMark(x: .value("Heure", s.hour), y: .value("Luminosité", s.value))
                    .foregroundStyle(Color.accentColor.opacity(0.15))
                LineMark(x: .value("Heure", s.hour), y: .value("Luminosité", s.value))
                    .foregroundStyle(Color.accentColor)
            }
            RuleMark(x: .value("Maintenant", now))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .chartXScale(domain: 0...24)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 24]) { v in
                AxisGridLine()
                AxisValueLabel { Text("\(v.as(Int.self) ?? 0) h") }
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { v in
                AxisGridLine()
                AxisValueLabel { Text("\(v.as(Int.self) ?? 0) %") }
            }
        }
    }
}
