import AppKit
import SwiftUI

@main
struct BrightBarApp: App {
    @StateObject private var model: BrightnessModel
    @StateObject private var features = FeaturesModel()
    @StateObject private var keyboard: KeyboardModel
    @StateObject private var externals: ExternalDisplaysModel
    @StateObject private var auto: AutoBrightness
    @StateObject private var keys: BrightnessKeys
    @StateObject private var login = LaunchAtLogin()
    private let keyController: KeyController

    init() {
        let model = BrightnessModel()
        let externals = ExternalDisplaysModel(builtin: model.$value)
        externals.extraDimmers = { [weak model] in model?.activeGamma.map { [$0] } ?? [] }
        externals.onScreensChanged = { [weak model] in model?.screensChanged() }
        let keyboard = KeyboardModel()
        let keyController = KeyController(builtin: model, externals: externals, keyboard: keyboard)
        self.keyController = keyController
        _model = StateObject(wrappedValue: model)
        _externals = StateObject(wrappedValue: externals)
        _keyboard = StateObject(wrappedValue: keyboard)
        _auto = StateObject(wrappedValue: AutoBrightness(builtin: model, externals: externals))
        _keys = StateObject(wrappedValue: keyController.keys)
        // New status items land leftmost and end up hidden behind the notch on
        // a crowded menu bar. Start ~300pt from the right edge instead; a ⌘-drag
        // by the user still overrides this (register() is only a fallback).
        UserDefaults.standard.register(defaults: ["NSStatusItem Preferred Position Item-0": 300])
        // Menu bar only, no Dock icon (LSUIElement also set in the bundle plist).
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model, features: features, keyboard: keyboard, externals: externals, auto: auto, keys: keys)
        } label: {
            Image(nsImage: MenuBarIcon.image(level: model.level))
        }
        .menuBarExtraStyle(.window)

        Window("Réglages BrightBar", id: "auto") {
            AutoSettingsView(auto: auto, login: login)
        }
        .windowResizability(.contentSize)
    }
}

/// Same layout as macOS's Display module in Control Center.
struct MenuView: View {
    @ObservedObject var model: BrightnessModel
    @ObservedObject var features: FeaturesModel
    @ObservedObject var keyboard: KeyboardModel
    @ObservedObject var externals: ExternalDisplaysModel
    @ObservedObject var auto: AutoBrightness
    @ObservedObject var keys: BrightnessKeys

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: FeaturesModel.openDisplaySettings) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Moniteur").font(.headline)
                        Text(model.displayName).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let status = model.status {
                Text(status).font(.callout).foregroundStyle(.secondary)
                Button("Réessayer") { model.connect() }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "sun.min").foregroundStyle(.secondary)
                        Slider(
                            value: Binding(get: { model.level }, set: { model.setLevel($0, user: true) }),
                            in: model.minLevel...model.maxLevel
                        )
                        Image(systemName: "sun.max").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(LevelText.describe(model.level))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(model.level < 0 || model.level > 100 ? Color.accentColor : .secondary)
                        Spacer()
                        Toggle("Sous zéro", isOn: $model.subzeroEnabled)
                            .help("Descendre sous le minimum de macOS en assombrissant l'image (gamma).")
                        Toggle("XDR", isOn: $model.xdrEnabled)
                            .disabled(!model.xdrSupported)
                            .help(model.xdrSupported
                                  ? "Dépasser 100 % jusqu'au maximum de la dalle XDR. Consomme plus de batterie et chauffe."
                                  : "Cet écran n'a pas de marge HDR/XDR.")
                    }
                    .toggleStyle(.checkbox)
                    .font(.caption)
                }
            }

            AutoSection(auto: auto, systemAutoBrightness: model.systemAutoBrightness)

            if !keys.active {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "keyboard").foregroundStyle(.secondary)
                    Text("F1/F2 passent par macOS. Autorise BrightBar dans Accessibilité pour afficher son indicateur.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Autoriser…") {
                    keys.start(prompt: true)
                    BrightnessKeys.openAccessibilitySettings()
                }
                .controlSize(.small)
            }

            HStack(alignment: .top) {
                ToggleCircle(
                    title: "Mode sombre", subtitle: features.darkSubtitle,
                    symbol: "circle.lefthalf.filled", isOn: features.dark,
                    action: features.toggleDark
                )
                ToggleCircle(
                    title: "Night Shift", subtitle: features.nightShiftSubtitle,
                    symbol: "moon.stars", isOn: features.nightShift?.enabled ?? false,
                    action: features.toggleNightShift
                )
                .disabled(features.nightShift == nil)
                if features.trueToneSupported {
                    ToggleCircle(
                        title: "True Tone", subtitle: features.trueTone ? "Activé" : "Désactivé",
                        symbol: "sun.max", isOn: features.trueTone,
                        action: features.toggleTrueTone
                    )
                }
            }

            if keyboard.isAvailable {
                Divider()
                KeyboardView(keyboard: keyboard, keys: keys)
            }

            if !externals.items.isEmpty {
                Divider()
                ExternalsView(externals: externals)
            }
        }
        .padding(16)
        .frame(width: 320)
        // No visible Quit button any more (it lives in Réglages BrightBar);
        // keep ⌘Q working while the panel is open.
        .background {
            Button("") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .opacity(0)
        }
        .onAppear {
            model.refresh()
            features.refresh()
            keyboard.refresh()
            externals.reload()
        }
    }
}

/// Human label for an extended brightness level.
enum LevelText {
    static func describe(_ level: Double) -> String {
        let n = Int(level.rounded())
        switch level {
        case ..<0: return "Sous zéro \(n) %"
        case ...100: return "\(n) %"
        default: return "XDR \(n) %"
        }
    }
}

/// Keyboard backlight, like Control Center's Keyboard Brightness module.
struct KeyboardView: View {
    @ObservedObject var keyboard: KeyboardModel
    @ObservedObject var keys: BrightnessKeys

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Clavier").font(.subheadline.weight(.semibold))
                if keys.active {
                    Text("⌃F1 / ⌃F2").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                if let v = keyboard.value {
                    Text(v == 0 ? "Éteint" : "\(Int(v.rounded())) %")
                        .monospacedDigit().font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "light.min").foregroundStyle(.secondary)
                Slider(value: Binding(get: { keyboard.value ?? 0 }, set: { keyboard.set($0) }), in: 0...100)
                Image(systemName: "light.max").foregroundStyle(.secondary)
            }
        }
    }
}

/// One slider per external monitor, driven over DDC/CI.
struct ExternalsView: View {
    @ObservedObject var externals: ExternalDisplaysModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Écrans externes").font(.subheadline.weight(.semibold))
                if externals.loading { ProgressView().controlSize(.mini) }
            }
            ForEach(externals.items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.name).font(.callout).lineLimit(1)
                        if item.isSoftware {
                            Text("logiciel")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.1)))
                                .help("L'écran ne répond pas en DDC : l'image est assombrie par la table gamma, le rétroéclairage ne change pas.")
                        }
                        Spacer()
                        if let v = item.value {
                            Text("\(Int(v.rounded())) %").monospacedDigit().font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let v = item.value {
                        HStack(spacing: 8) {
                            Image(systemName: "sun.min").foregroundStyle(.secondary)
                            Slider(value: Binding(get: { v }, set: { externals.set(item.id, $0) }), in: 0...100)
                            Image(systemName: "sun.max").foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Luminosité non réglable sur cet écran")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if item.isSoftware {
                        Text("Sans DDC : assombrit l'image seulement. Pour plus de lumière, règle l'écran au max dans son menu.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Toggle("Suivre la luminosité du MacBook (F1/F2)", isOn: $externals.followBuiltin)
                .font(.caption)
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}

/// Round toggle with a caption, like the Control Center buttons.
struct ToggleCircle: View {
    let title: String
    let subtitle: String
    let symbol: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .symbolEffect(.bounce, value: isOn)
                    .frame(width: 44, height: 44)
                    .foregroundStyle(isOn ? Color.white : Color.primary)
                    .background(Circle().fill(isOn ? Color.accentColor : Color.primary.opacity(0.1)))
                Text(title).font(.caption.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .animation(.snappy(duration: 0.25), value: isOn)
    }
}

/// Plain button that shrinks a little while held, like Control Center's.
struct PressableStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
