// Built-in ambient light sensor, read through IOHIDEventSystemClient
// services matching the ALS usage (0xff00/4), then the ambient-light event's
// lux field. Private IOKit symbols, resolved at runtime.

import Foundation
import IOKit

private typealias HIDCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
private typealias HIDSetMatching = @convention(c) (AnyObject, CFDictionary) -> Void
private typealias HIDCopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
private typealias HIDCopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
private typealias HIDGetFloat = @convention(c) (AnyObject, Int32) -> Double

public final class AmbientLightSensor: @unchecked Sendable {
    private static let eventType: Int64 = 12            // kIOHIDEventTypeAmbientLightSensor
    private static let luxField: Int32 = 12 << 16       // IOHIDEventFieldBase(type)

    private let service: AnyObject
    private let copyEvent: HIDCopyEvent
    private let getFloat: HIDGetFloat
    // Keeps the event system client (and so the service) alive.
    private let client: AnyObject

    public init?() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }
        func sym<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(h, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let create = sym("IOHIDEventSystemClientCreate", as: HIDCreate.self),
              let setMatching = sym("IOHIDEventSystemClientSetMatching", as: HIDSetMatching.self),
              let copyServices = sym("IOHIDEventSystemClientCopyServices", as: HIDCopyServices.self),
              let copyEvent = sym("IOHIDServiceClientCopyEvent", as: HIDCopyEvent.self),
              let getFloat = sym("IOHIDEventGetFloatValue", as: HIDGetFloat.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }

        setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 4] as CFDictionary)
        guard let services = copyServices(client)?.takeRetainedValue() as? [AnyObject],
              let service = services.first
        else { return nil }
        self.client = client
        self.service = service
        self.copyEvent = copyEvent
        self.getFloat = getFloat
    }

    /// Current illuminance in lux, nil if the sensor has no reading (lid closed).
    public func lux() -> Double? {
        guard let event = copyEvent(service, Self.eventType, 0, 0)?.takeRetainedValue() else { return nil }
        let v = getFloat(event, Self.luxField)
        return v.isFinite && v >= 0 ? v : nil
    }
}
