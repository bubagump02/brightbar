// The other toggles of macOS's Display module, through the same private APIs
// Lunar uses: SkyLight for Dark Mode, CoreBrightness for Night Shift and
// True Tone. Everything is resolved at runtime and degrades to "unsupported".

import Darwin
import Foundation
import ObjectiveC

private let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
private let coreBrightness = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)

private typealias GetBoolFn = @convention(c) () -> Bool
private typealias SetBoolFn = @convention(c) (Bool) -> Void
private typealias MsgGetBool = @convention(c) (AnyObject, Selector) -> Bool
private typealias MsgSetBool = @convention(c) (AnyObject, Selector, Bool) -> Bool
private typealias MsgGetPtr = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool

private func fn<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as _: T.Type) -> T? {
    guard let handle, let p = dlsym(handle, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

private func msg<T>(_ obj: AnyObject, _ name: String, as _: T.Type) -> (T, Selector)? {
    let sel = NSSelectorFromString(name)
    guard obj.responds(to: sel), let imp = class_getMethodImplementation(type(of: obj), sel) else { return nil }
    return (unsafeBitCast(imp, to: T.self), sel)
}

private func instance(_ className: String) -> NSObject? {
    _ = coreBrightness
    return (NSClassFromString(className) as? NSObject.Type)?.init()
}

// MARK: - Dark Mode

public enum Appearance {
    private static let getDarkFn = fn(skyLight, "SLSGetAppearanceThemeLegacy", as: GetBoolFn.self)
    private static let setDarkFn = fn(skyLight, "SLSSetAppearanceThemeLegacy", as: SetBoolFn.self)
    private static let getAutoFn = fn(skyLight, "SLSGetAppearanceThemeSwitchesAutomatically", as: GetBoolFn.self)

    public static var isSupported: Bool { getDarkFn != nil && setDarkFn != nil }
    public static var isDark: Bool { getDarkFn?() ?? false }
    /// "Auto" appearance in System Settings (light by day, dark by night).
    public static var switchesAutomatically: Bool { getAutoFn?() ?? false }
    public static func setDark(_ dark: Bool) { setDarkFn?(dark) }

    /// Posted by the system whenever the appearance flips, from any source.
    public static let changedNotification = Notification.Name("AppleInterfaceThemeChangedNotification")
}

// MARK: - Night Shift

public final class NightShift: @unchecked Sendable {
    public enum Schedule: Int32, Sendable {
        case off = 0, sunsetToSunrise = 1, custom = 2
    }

    public struct Status: Sendable {
        /// Night Shift is currently tinting the screen.
        public var enabled: Bool
        public var schedule: Schedule
        /// Custom schedule start/end, as (hour, minute).
        public var from: (Int, Int)
        public var to: (Int, Int)
    }

    private let client = instance("CBBlueLightClient")

    public init() {}

    public var isSupported: Bool { client != nil && status != nil }

    /// Reads CoreBrightness's StatusData:
    /// { BOOL active; BOOL enabled; BOOL sunSchedulePermitted; int mode;
    ///   {{int h, m} from; {int h, m} to} schedule; uint64 disableFlags; BOOL available }
    public var status: Status? {
        guard let client, let (get, sel) = msg(client, "getBlueLightStatus:", as: MsgGetPtr.self) else { return nil }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        defer { buf.deallocate() }
        memset(buf, 0, 64)
        guard get(client, sel, buf) else { return nil }
        let int = { (offset: Int) in Int(buf.load(fromByteOffset: offset, as: Int32.self)) }
        return Status(
            enabled: buf.load(fromByteOffset: 1, as: Bool.self),
            schedule: Schedule(rawValue: buf.load(fromByteOffset: 4, as: Int32.self)) ?? .off,
            from: (int(8), int(12)),
            to: (int(16), int(20))
        )
    }

    @discardableResult
    public func setEnabled(_ on: Bool) -> Bool {
        guard let client, let (set, sel) = msg(client, "setEnabled:", as: MsgSetBool.self) else { return false }
        return set(client, sel, on)
    }

    /// Called on the main queue whenever Night Shift changes, from any source.
    public func observe(_ onChange: @escaping @MainActor () -> Void) {
        guard let client else { return }
        let sel = NSSelectorFromString("setStatusNotificationBlock:")
        guard client.responds(to: sel) else { return }
        let block: @convention(block) () -> Void = {
            DispatchQueue.main.async { MainActor.assumeIsolated { onChange() } }
        }
        client.perform(sel, with: block as AnyObject)
    }
}

// MARK: - True Tone

public final class TrueTone: @unchecked Sendable {
    private let client = instance("CBTrueToneClient")

    public init() {}

    private func bool(_ name: String) -> Bool {
        guard let client, let (get, sel) = msg(client, name, as: MsgGetBool.self) else { return false }
        return get(client, sel)
    }

    /// Hardware has the ambient color sensor and the display supports it.
    public var isSupported: Bool { bool("supported") && bool("available") }
    public var isEnabled: Bool { bool("enabled") }

    @discardableResult
    public func setEnabled(_ on: Bool) -> Bool {
        guard let client, let (set, sel) = msg(client, "setEnabled:", as: MsgSetBool.self) else { return false }
        return set(client, sel, on)
    }
}
