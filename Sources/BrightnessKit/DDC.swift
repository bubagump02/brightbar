// External monitor brightness over DDC/CI on Apple Silicon, through
// IOAVService (private, exported by IOKit) on the DCPAVServiceProxy of each
// external port, I²C chip 0x37, data address 0x51.
// Intel Macs (IOFramebuffer I²C) are not supported.

import CoreGraphics
import Darwin
import Foundation
import IOKit

private let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

private typealias AVCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
private typealias AVCopyEDID = @convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn
private typealias AVI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

private func sym<T>(_ name: String, as _: T.Type) -> T? {
    guard let ioKit, let p = dlsym(ioKit, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

private let avCreate = sym("IOAVServiceCreateWithService", as: AVCreate.self)
private let avCopyEDID = sym("IOAVServiceCopyEDID", as: AVCopyEDID.self)
private let avRead = sym("IOAVServiceReadI2C", as: AVI2C.self)
private let avWrite = sym("IOAVServiceWriteI2C", as: AVI2C.self)

/// VESA MCCS VCP codes.
public enum VCP: UInt8, Sendable {
    case brightness = 0x10
    case contrast = 0x12
}

/// One DDC/CI channel to an external monitor. All I²C traffic is serialized on
/// a private queue: monitors drop commands that arrive too close together.
public final class DDCChannel: @unchecked Sendable {
    private static let chip: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51
    private static let hostAddress: UInt8 = 0x6E

    private let service: CFTypeRef
    private let queue: DispatchQueue

    init(service: CFTypeRef, label: String) {
        self.service = service
        self.queue = DispatchQueue(label: "brightbar.ddc.\(label)")
    }

    /// Reads (current, max). Blocking, ~50 ms; call off the main thread.
    public func read(_ vcp: VCP) -> (current: Int, max: Int)? {
        queue.sync { readLocked(vcp) }
    }

    /// Fire-and-forget write; the latest value wins when writes pile up.
    public func write(_ vcp: VCP, _ value: Int, completion: (@Sendable (Bool) -> Void)? = nil) {
        pending.withLock { $0[vcp.rawValue] = value }
        queue.async { [self] in
            guard let v = pending.withLock({ $0.removeValue(forKey: vcp.rawValue) }) else { return }
            let ok = writeLocked(vcp, v)
            completion?(ok)
        }
    }

    private let pending = Locked<[UInt8: Int]>([:])

    private func readLocked(_ vcp: VCP) -> (current: Int, max: Int)? {
        guard let avRead, let avWrite else { return nil }
        // Get VCP Feature request: [0x82, 0x01, vcp, checksum]
        var request: [UInt8] = [0x82, 0x01, vcp.rawValue, 0]
        request[3] = checksum(request[0..<3])
        // Retry reads: some monitors need a second go after waking.
        for _ in 0..<3 {
            guard request.withUnsafeMutableBytes({ avWrite(service, Self.chip, Self.dataAddress, $0.baseAddress!, 4) }) == kIOReturnSuccess else {
                usleep(40_000)
                continue
            }
            usleep(40_000)
            var reply = [UInt8](repeating: 0, count: 12)
            guard reply.withUnsafeMutableBytes({ avRead(service, Self.chip, Self.dataAddress, $0.baseAddress!, 12) }) == kIOReturnSuccess else {
                usleep(40_000)
                continue
            }
            // Reply: [src 0x6E, len|0x80, 0x02, result, vcp, type, maxHi, maxLo, curHi, curLo, chk]
            // (byte 0 is the source address on some adapters; accept both layouts)
            let base = reply[0] == 0x6E ? 1 : 0
            guard reply[base + 1] == 0x02, reply[base + 2] == 0x00, reply[base + 3] == vcp.rawValue else {
                usleep(40_000)
                continue
            }
            let max = Int(reply[base + 5]) << 8 | Int(reply[base + 6])
            let cur = Int(reply[base + 7]) << 8 | Int(reply[base + 8])
            return (cur, max)
        }
        return nil
    }

    private func writeLocked(_ vcp: VCP, _ value: Int) -> Bool {
        guard let avWrite else { return false }
        let v = UInt16(clamping: value)
        // Set VCP Feature: [0x84, 0x03, vcp, hi, lo, checksum]
        var packet: [UInt8] = [0x84, 0x03, vcp.rawValue, UInt8(v >> 8), UInt8(v & 0xFF), 0]
        packet[5] = checksum(packet[0..<5])
        // Send every write twice, 15 ms apart: monitors silently drop some.
        var ok = false
        for i in 0..<2 {
            if i > 0 { usleep(15_000) }
            let r = packet.withUnsafeMutableBytes { avWrite(service, Self.chip, Self.dataAddress, $0.baseAddress!, 6) }
            ok = ok || r == kIOReturnSuccess
        }
        usleep(20_000)
        return ok
    }

    private func checksum(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(Self.hostAddress ^ UInt8(Self.dataAddress)) { $0 ^ $1 }
    }
}

/// Minimal lock box; Mutex needs macOS 15.
final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

// MARK: - Discovery

public struct ExternalDisplay: Sendable {
    public let id: CGDirectDisplayID
    public let name: String
    /// nil when no DDC-capable port matched this display (TV, DisplayLink,
    /// Sidecar, AirPlay, or a monitor with DDC disabled in its OSD).
    public let ddc: DDCChannel?
}

private struct AVPort {
    let service: CFTypeRef
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
}

/// External online displays with their DDC channel when one could be matched.
/// Matching uses the EDID vendor/product/serial against CoreGraphics; two
/// identical monitors with no EDID serial may be paired the wrong way round.
public func externalDisplays() -> [ExternalDisplay] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
    let externals = ids.filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }

    var ports = externalAVPorts()
    var result: [ExternalDisplay] = []
    var unmatched: [CGDirectDisplayID] = []
    for id in externals {
        let vendor = CGDisplayVendorNumber(id), model = CGDisplayModelNumber(id), serial = CGDisplaySerialNumber(id)
        if let i = ports.firstIndex(where: { $0.vendor == vendor && $0.model == model && (serial == 0 || $0.serial == 0 || $0.serial == serial) }) {
            let port = ports.remove(at: i)
            result.append(ExternalDisplay(id: id, name: displayName(id), ddc: DDCChannel(service: port.service, label: "\(id)")))
        } else {
            unmatched.append(id)
        }
    }
    // Single leftover on both sides: EDID was unreadable but the pairing is unambiguous.
    if unmatched.count == 1, ports.count == 1 {
        let id = unmatched.removeFirst()
        result.append(ExternalDisplay(id: id, name: displayName(id), ddc: DDCChannel(service: ports[0].service, label: "\(id)")))
    }
    result += unmatched.map { ExternalDisplay(id: $0, name: displayName($0), ddc: nil) }
    return result.sorted { $0.id < $1.id }
}

private func externalAVPorts() -> [AVPort] {
    guard let avCreate, let avCopyEDID else { return [] }
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }

    var ports: [AVPort] = []
    while case let entry = IOIteratorNext(iterator), entry != 0 {
        defer { IOObjectRelease(entry) }
        let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        guard location == "External", let service = avCreate(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }

        var edidRef: Unmanaged<CFData>?
        var vendor: UInt32 = 0, model: UInt32 = 0, serial: UInt32 = 0
        if avCopyEDID(service, &edidRef) == kIOReturnSuccess, let edid = edidRef?.takeRetainedValue() as Data?, edid.count >= 16 {
            vendor = UInt32(edid[8]) << 8 | UInt32(edid[9])
            model = UInt32(edid[10]) | UInt32(edid[11]) << 8
            serial = UInt32(edid[12]) | UInt32(edid[13]) << 8 | UInt32(edid[14]) << 16 | UInt32(edid[15]) << 24
        }
        ports.append(AVPort(service: service, vendor: vendor, model: model, serial: serial))
    }
    return ports
}

private func displayName(_ id: CGDirectDisplayID) -> String {
    // NSScreen lives in AppKit; IODisplayCreateInfoDictionary is gone on Apple
    // Silicon, so fall back to vendor/model numbers.
    "Écran \(String(format: "%04X:%04X", CGDisplayVendorNumber(id), CGDisplayModelNumber(id)))"
}
