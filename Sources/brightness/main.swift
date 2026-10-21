// brightness — read/set built-in display brightness the way Lunar does it.

import BrightnessKit
import CoreGraphics
import Foundation

func fail(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

let usage = """
usage: brightness [--method ds|cd] <command>
  get                     print brightness (0-100)
  set <0-100>             set immediately
  smooth <0-100> [secs]   animated transition: native without secs,
                          manual stepped loop over <secs> with it
  watch [--raw]           print external brightness changes until Ctrl-C
  info                    show display id and available APIs
  status                  Dark Mode, Night Shift, True Tone state
  dark|night|truetone on|off
  kbd [0-100]             keyboard backlight: print, or set
  kbd auto on|off         macOS "adjust keyboard brightness in low light"
  lux                     ambient light (lux) and the sensor mode's target
  schedule                schedule mode's target now, for the default points
  ddc list                external displays and their DDC brightness
  ddc set <n> <0-100>     set brightness of external display <n> (from list)
  gamma <n> <0-100> [secs]  software-dim external display <n>; macOS undoes
                          it when this process exits, so it holds for <secs>
                          (default: until Ctrl-C)
"""

var args = Array(CommandLine.arguments.dropFirst())
var forced: BrightnessMethod?
if let i = args.firstIndex(of: "--method") {
    guard i + 1 < args.count, let m = BrightnessMethod(rawValue: args[i + 1]) else { fail(usage, code: 64) }
    forced = m
    args.removeSubrange(i...(i + 1))
}
guard let command = args.first else { fail(usage, code: 64) }

func percent(_ s: String?) -> Float {
    guard let s, let v = Float(s), (0...100).contains(v) else { fail("value must be 0-100", code: 64) }
    return v / 100
}

func onOff(_ s: String?) -> Bool {
    switch s {
    case "on": return true
    case "off": return false
    default: fail("expected on|off", code: 64)
    }
}

switch command {
case "status":
    print("dark: \(Appearance.isDark) (auto: \(Appearance.switchesAutomatically))")
    if let s = NightShift().status {
        print("night shift: \(s.enabled) (schedule: \(s.schedule), from \(s.from.0):\(s.from.1) to \(s.to.0):\(s.to.1))")
    } else {
        print("night shift: unsupported")
    }
    let tone = TrueTone()
    print("true tone: \(tone.isSupported ? "\(tone.isEnabled)" : "unsupported")")
    exit(0)
case "dark":
    Appearance.setDark(onOff(args.dropFirst().first))
    exit(0)
case "night":
    exit(NightShift().setEnabled(onOff(args.dropFirst().first)) ? 0 : 1)
case "truetone":
    exit(TrueTone().setEnabled(onOff(args.dropFirst().first)) ? 0 : 1)
case "kbd":
    guard let kbd = KeyboardBacklight() else { fail("no keyboard backlight") }
    switch args.dropFirst().first {
    case nil:
        guard let v = kbd.brightness else { fail("keyboard read failed") }
        print(String(format: "%.1f (auto: %@)", v * 100, kbd.autoBrightnessAvailable ? "\(kbd.autoBrightness)" : "unavailable"))
        exit(0)
    case "auto":
        exit(kbd.setAutoBrightness(onOff(args.dropFirst(2).first)) ? 0 : 1)
    case let value:
        exit(kbd.set(percent(value)) ? 0 : 1)
    }
case "ddc":
    let displays = externalDisplays()
    switch args.dropFirst().first {
    case "list":
        if displays.isEmpty { print("no external display") }
        for (n, d) in displays.enumerated() {
            let b = d.ddc?.read(.brightness).map { "\($0.current)/\($0.max)" } ?? (d.ddc == nil ? "no DDC port" : "DDC read failed")
            print("\(n)  id=\(d.id)  \(d.name)  brightness=\(b)")
        }
        exit(0)
    case "set":
        guard args.count == 4, let n = Int(args[2]), displays.indices.contains(n) else { fail(usage, code: 64) }
        guard let ddc = displays[n].ddc, let (_, max) = ddc.read(.brightness) else { fail("display \(n): DDC unavailable") }
        let target = Int((percent(args[3]) * Float(max)).rounded())
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ok = false
        ddc.write(.brightness, target) { ok = $0; done.signal() }
        done.wait()
        exit(ok ? 0 : 1)
    default:
        fail(usage, code: 64)
    }
case "lux":
    guard let sensor = AmbientLightSensor(), let lux = sensor.lux() else { fail("no ambient light reading") }
    print(String(format: "%.0f lux -> %.0f %%", lux, LuxCurve.brightness(lux: lux)))
    exit(0)
case "schedule":
    let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
    let minute = c.hour! * 60 + c.minute!
    let target = ScheduleCurve.brightness(at: minute, points: ScheduleCurve.defaultPoints)!
    print(String(format: "%02d:%02d -> %.0f %%", c.hour!, c.minute!, target))
    for m in stride(from: 0, to: 1440, by: 120) {
        print(String(format: "  %02d:00 %5.1f %%", m / 60, ScheduleCurve.brightness(at: m, points: ScheduleCurve.defaultPoints)!))
    }
    exit(0)
case "gamma":
    let displays = externalDisplays()
    guard args.count >= 3, let n = Int(args[1]), displays.indices.contains(n) else { fail(usage, code: 64) }
    guard let dimmer = GammaDimmer(id: displays[n].id) else { fail("display \(n): gamma table unavailable") }
    guard dimmer.set(percent(args[2])) else { fail("display \(n): gamma write failed") }
    print(String(format: "applied factor: %.3f", dimmer.appliedFactor() ?? -1))
    fflush(stdout)
    if args.count > 3, let secs = Double(args[3]) {
        Thread.sleep(forTimeInterval: secs)
    } else {
        RunLoop.main.run()
    }
    exit(0)
default:
    break
}

guard let id = builtinDisplayID() else { fail("no built-in display online (lid closed?)") }

if command == "info" {
    print("built-in display id: \(id)")
    print(NativeAPI.shared.description)
    print("probe ds/cd: \(BuiltinControl.supports(.displayServices, id: id))/\(BuiltinControl.supports(.coreDisplay, id: id))")
    print("selected method: \(BuiltinControl(id: id, forced: forced)?.method.rawValue ?? "none")")
    print("macOS auto-brightness: \(BuiltinControl(id: id)?.systemAutoBrightness ?? false)")
    exit(0)
}

guard let control = BuiltinControl(id: id, forced: forced) else {
    fail("no usable brightness API for display \(id)")
}
let method = control.method

switch command {
case "get":
    guard let v = control.get() else { fail("read failed (\(method.rawValue))") }
    print(String(format: "%.1f", v * 100))
case "set":
    guard control.set(percent(args.dropFirst().first)) else { fail("write failed (\(method.rawValue))") }
case "smooth":
    let target = percent(args.dropFirst().first)
    let secs: Double? = args.count > 2 ? Double(args[2]) : nil
    if args.count > 2, secs == nil { fail("secs must be a number", code: 64) }
    guard control.smooth(to: target, duration: secs) else { fail("smooth failed (\(method.rawValue))") }
case "watch":
    if args.contains("--raw") {
        BrightnessObserver.debugUserInfo = { print("userInfo:", $0.map { "\($0)" } ?? "nil") }
    }
    let observer = BrightnessObserver(id: id) { v in
        print(String(format: "%.1f", v * 100))
        fflush(stdout)
    }
    guard observer != nil else { fail("cannot observe brightness changes on display \(id)") }
    print("watching display \(id), press brightness keys (Ctrl-C to stop)")
    fflush(stdout)
    RunLoop.main.run()
default:
    fail(usage, code: 64)
}
