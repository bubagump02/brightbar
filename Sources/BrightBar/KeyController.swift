import AppKit
import BrightnessKit

/// Routes F1/F2 to the screen under the mouse pointer, the illumination keys
/// to the keyboard backlight, and shows BrightBar's indicator instead of the
/// macOS one.
@MainActor
final class KeyController {
    let keys = BrightnessKeys()
    private let hud = BrightnessHUD()
    private let builtin: BrightnessModel
    private let externals: ExternalDisplaysModel
    private let keyboard: KeyboardModel

    init(builtin: BrightnessModel, externals: ExternalDisplaysModel, keyboard: KeyboardModel) {
        self.builtin = builtin
        self.externals = externals
        self.keyboard = keyboard
        keys.onKey = { [weak self] key, fine in
            self?.handle(key, fine: fine) ?? false
        }
        // Ask once on first launch; afterwards the panel has a button for it.
        let asked = UserDefaults.standard.bool(forKey: "askedAccessibility")
        UserDefaults.standard.set(true, forKey: "askedAccessibility")
        keys.start(prompt: !asked)
    }

    /// Returns false to let macOS handle the key (nothing we can drive).
    private func handle(_ key: BrightnessKeys.Key, fine: Bool) -> Bool {
        // macOS steps: 1/16, or 1/64 with ⌥⇧. Snap to the grid like it does.
        let next = { (v: Double, lo: Double, hi: Double) -> Double in
            // macOS's 1/16 in the native range (its bottom barely changes the
            // light anyway), 1/32 in sub-zero, which is its own finer range
            // like in Lunar. The keyboard backlight gets coarser 10 % steps,
            // so it goes from off to full in a few presses. ⌥⇧ halves the step.
            let isKeyboard = key == .keyboardUp || key == .keyboardDown
            let inSubzero = v < 0 || (v == 0 && key == .down)
            let divisions: Double = isKeyboard ? 10 : inSubzero ? 32 : 16
            let step = 100.0 / (fine ? divisions * 2 : divisions)
            let snapped = (v / step).rounded() * step
            return min(max(snapped + (key == .up || key == .keyboardUp ? step : -step), lo), hi)
        }

        if key == .keyboardUp || key == .keyboardDown {
            guard let v = keyboard.value else { return false }
            let target = next(v, 0, 100)
            keyboard.set(target)
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            hud.show(name: "Clavier", label: "\(Int(target.rounded())) %", fraction: target / 100,
                     badge: nil, symbols: ("light.min", "light.max"), on: screen)
            return true
        }

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        let id = screen.flatMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }

        if let id, let item = externals.items.first(where: { $0.id == id }), let v = item.value {
            let target = next(v, 0, 100)
            externals.set(id, target)
            hud.show(name: item.name, label: "\(Int(target.rounded())) %", fraction: target / 100,
                     badge: item.isSoftware ? "logiciel" : nil, on: screen)
            return true
        }
        guard builtin.isAvailable else { return false }
        let target = next(builtin.level, builtin.minLevel, builtin.maxLevel)
        builtin.setLevel(target, animated: true, user: true)
        // Bar spans the whole extended range, so sub-zero and XDR stay visible.
        let fraction = (target - builtin.minLevel) / (builtin.maxLevel - builtin.minLevel)
        let badge = target < 0 ? "sous zéro" : target > 100 ? "XDR" : nil
        hud.show(name: builtin.displayName, label: LevelText.describe(target), fraction: fraction,
                 badge: badge, on: builtin.screen)
        return true
    }
}
