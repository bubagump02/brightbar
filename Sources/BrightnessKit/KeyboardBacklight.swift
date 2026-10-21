// Keyboard backlight, through CoreBrightness's KeyboardBrightnessClient: the
// client behind Control Center's Keyboard Brightness module. Resolved at
// runtime like the rest; a Mac without a backlit keyboard gets nil.

import Darwin
import Foundation
import ObjectiveC

private let coreBrightness = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)

private typealias MsgGetFloat = @convention(c) (AnyObject, Selector, UInt64) -> Float
private typealias MsgGetBool = @convention(c) (AnyObject, Selector, UInt64) -> Bool
private typealias MsgSetFloat = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
private typealias MsgSetBool = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool
private typealias NotifyBlock = @convention(block) (AnyObject?, AnyObject?) -> Void
private typealias MsgRegister = @convention(c) (AnyObject, Selector, NSArray, UInt64, NotifyBlock) -> Void

private func msg<T>(_ obj: AnyObject, _ name: String, as _: T.Type) -> (T, Selector)? {
    let sel = NSSelectorFromString(name)
    guard obj.responds(to: sel), let imp = class_getMethodImplementation(type(of: obj), sel) else { return nil }
    return (unsafeBitCast(imp, to: T.self), sel)
}

public final class KeyboardBacklight: @unchecked Sendable {
    private let client: NSObject
    /// CoreBrightness keyboard id (a registry entry id, not 0-based).
    public let id: UInt64

    /// The built-in keyboard's backlight, or nil if there is none.
    public init?() {
        _ = coreBrightness
        guard let client = (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init(),
              let ids = client.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?
                  .takeRetainedValue() as? [NSNumber]
        else { return nil }
        let builtIn = msg(client, "isKeyboardBuiltIn:", as: MsgGetBool.self)
        guard let id = ids.map(\.uint64Value).first(where: { id in builtIn.map { $0.0(client, $0.1, id) } ?? true })
        else { return nil }
        self.client = client
        self.id = id
    }

    private func float(_ name: String) -> Float? {
        guard let (get, sel) = msg(client, name, as: MsgGetFloat.self) else { return nil }
        return get(client, sel, id)
    }

    private func bool(_ name: String) -> Bool {
        guard let (get, sel) = msg(client, name, as: MsgGetBool.self) else { return false }
        return get(client, sel, id)
    }

    /// User brightness, 0...1. 0 switches the backlight off.
    public var brightness: Float? { float("brightnessForKeyboard:") }

    /// Faded by the system, as from Control Center. Also persisted by it.
    @discardableResult
    public func set(_ value: Float) -> Bool {
        guard let (set, sel) = msg(client, "setBrightness:forKeyboard:", as: MsgSetFloat.self) else { return false }
        return set(client, sel, min(max(value, 0), 1), id)
    }

    /// macOS "Adjust keyboard brightness in low light" (needs the light sensor).
    public var autoBrightnessAvailable: Bool { bool("isAmbientFeatureAvailableOnKeyboard:") }
    public var autoBrightness: Bool { bool("isAutoBrightnessEnabledForKeyboard:") }

    @discardableResult
    public func setAutoBrightness(_ on: Bool) -> Bool {
        guard let (set, sel) = msg(client, "enableAutoBrightness:forKeyboard:", as: MsgSetBool.self) else { return false }
        return set(client, sel, on, id)
    }

    /// Called on the main queue with the new brightness (0...1), from any source.
    public func observe(_ onChange: @escaping @MainActor (Float) -> Void) {
        guard let (register, sel) = msg(client, "registerNotificationForKeys:keyboardID:block:", as: MsgRegister.self)
        else { return }
        // Also posts "KeyboardBacklightLevel" (the raw backlight); only the
        // user brightness matters here.
        let block: NotifyBlock = { key, value in
            guard key as? String == "KeyboardBacklightBrightness", let v = (value as? NSNumber)?.floatValue else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { onChange(v) } }
        }
        register(client, sel, ["KeyboardBacklightBrightness"] as NSArray, id, block)
    }
}
