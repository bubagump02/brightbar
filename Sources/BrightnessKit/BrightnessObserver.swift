// Notifies when the built-in brightness changes from outside (brightness keys,
// Control Center, ambient light). Mechanism:
// DisplayServicesRegisterForBrightnessChangeNotifications(id, observer: id, cb).

import CoreFoundation
import CoreGraphics
import Foundation

public final class BrightnessObserver: @unchecked Sendable {
    public let id: CGDirectDisplayID
    let api: NativeAPI
    let onChange: (Float) -> Void

    // The C callback cannot capture context; The display id is passed as the
    // observer pointer, so route callbacks back through this table.
    nonisolated(unsafe) static var observers: [CGDirectDisplayID: BrightnessObserver] = [:]

    /// Receives the raw notification userInfo; for debugging the payload.
    nonisolated(unsafe) public static var debugUserInfo: ((CFDictionary?) -> Void)?

    var observerToken: UnsafeRawPointer? { UnsafeRawPointer(bitPattern: UInt(id)) }

    /// DisplayServices calls back on a CoreBrightness XPC queue, not the
    /// registering thread; onChange is re-dispatched to the main queue.
    /// Register and invalidate from the main thread. onChange receives
    /// brightness in 0.0...1.0.
    public init?(id: CGDirectDisplayID, api: NativeAPI = .shared, onChange: @escaping (Float) -> Void) {
        guard let register = api.dsRegister, api.canChange?(id) == true else { return nil }
        self.id = id
        self.api = api
        self.onChange = onChange
        guard Self.observers[id] == nil else { return nil }
        Self.observers[id] = self
        guard register(id, observerToken, brightnessChanged) == 0 else {
            Self.observers[id] = nil
            return nil
        }
    }

    public func invalidate() {
        guard Self.observers[id] === self else { return }
        _ = api.dsUnregister?(id, observerToken)
        Self.observers[id] = nil
    }

    deinit { invalidate() }
}

private func brightnessChanged(
    _: CFNotificationCenter?, observer: UnsafeMutableRawPointer?, _: CFNotificationName?,
    _: UnsafeRawPointer?, userInfo: CFDictionary?
) {
    guard let observer else { return }
    let id = CGDirectDisplayID(UInt(bitPattern: observer))
    // userInfo carries the new value; nil means read it back on main.
    let value = ((userInfo as? [String: Any])?["value"] as? NSNumber)?.floatValue
    nonisolated(unsafe) let rawInfo = userInfo

    DispatchQueue.main.async {
        guard let obs = BrightnessObserver.observers[id] else { return }
        BrightnessObserver.debugUserInfo?(rawInfo)
        if let value {
            obs.onChange(value)
            return
        }
        var v: Float = 0
        if obs.api.dsGet?(id, &v) == 0 { obs.onChange(v) }
    }
}
