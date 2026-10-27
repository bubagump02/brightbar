// Private display APIs resolved at runtime with dlopen/dlsym, so nothing links
// against private frameworks and a missing symbol degrades instead of crashing.

import CoreFoundation
import CoreGraphics
import Darwin

typealias DSCanChange = @convention(c) (CGDirectDisplayID) -> Bool
typealias DSGet = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
typealias DSSet = @convention(c) (CGDirectDisplayID, Float) -> Int32
typealias DSGetBool = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Bool>) -> Int32
typealias DSRegister = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?, CFNotificationCallback) -> Int32
typealias DSUnregister = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?) -> Int32
typealias CDGet = @convention(c) (CGDirectDisplayID) -> Double
typealias CDSet = @convention(c) (CGDirectDisplayID, Double) -> Void

public struct NativeAPI: @unchecked Sendable {
    var canChange: DSCanChange?
    var dsGet: DSGet?
    var dsSet: DSSet?
    // Takes a delta (target - current), not an absolute value.
    var dsSetSmooth: DSSet?
    // macOS "Automatically adjust brightness" (ambient light compensation).
    var dsHasALC: DSCanChange?
    // Result through the out-parameter, not the return value.
    var dsALCEnabled: DSGetBool?
    var dsRegister: DSRegister?
    var dsUnregister: DSUnregister?
    var cdGet: CDGet?
    var cdSet: CDSet?

    public static let shared = NativeAPI.load()

    static func load() -> NativeAPI {
        func sym<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as _: T.Type) -> T? {
            guard let handle, let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        let cd = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
        return NativeAPI(
            canChange: sym(ds, "DisplayServicesCanChangeBrightness", as: DSCanChange.self),
            dsGet: sym(ds, "DisplayServicesGetBrightness", as: DSGet.self),
            dsSet: sym(ds, "DisplayServicesSetBrightness", as: DSSet.self),
            dsSetSmooth: sym(ds, "DisplayServicesSetBrightnessSmooth", as: DSSet.self),
            dsHasALC: sym(ds, "DisplayServicesHasAmbientLightCompensation", as: DSCanChange.self),
            dsALCEnabled: sym(ds, "DisplayServicesAmbientLightCompensationEnabled", as: DSGetBool.self),
            dsRegister: sym(ds, "DisplayServicesRegisterForBrightnessChangeNotifications", as: DSRegister.self),
            dsUnregister: sym(ds, "DisplayServicesUnregisterForBrightnessChangeNotifications", as: DSUnregister.self),
            cdGet: sym(cd, "CoreDisplay_Display_GetUserBrightness", as: CDGet.self),
            cdSet: sym(cd, "CoreDisplay_Display_SetUserBrightness", as: CDSet.self)
        )
    }

    public var description: String {
        """
        DisplayServices get/set/smooth: \(dsGet != nil)/\(dsSet != nil)/\(dsSetSmooth != nil)
        DisplayServices notifications: \(dsRegister != nil)/\(dsUnregister != nil)
        CoreDisplay get/set: \(cdGet != nil)/\(cdSet != nil)
        """
    }
}

public func builtinDisplayID() -> CGDirectDisplayID? {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
    return ids.first { CGDisplayIsBuiltin($0) != 0 }
}
