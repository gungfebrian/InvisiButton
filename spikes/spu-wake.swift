// Proves the SPU IMU is readable from Swift, unprivileged, by waking the
// AppleSPUHIDDriver service before opening the HID devices.
import Foundation
import IOKit
import IOKit.hid

// ── 1. Wake the SPU drivers ───────────────────────────────────────────────
func wakeSPUDrivers() -> Int {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("AppleSPUHIDDriver"), &it) == KERN_SUCCESS else { return 0 }
    defer { IOObjectRelease(it) }
    var n = 0
    while case let svc = IOIteratorNext(it), svc != 0 {
        for (k, v) in [("SensorPropertyReportingState", 1), ("SensorPropertyPowerState", 1), ("ReportInterval", 1250)] {
            IORegistryEntrySetCFProperty(svc, k as CFString, v as CFNumber)
        }
        IOObjectRelease(svc); n += 1
    }
    return n
}
print("euid=\(geteuid())")
print("AppleSPUHIDDriver services woken: \(wakeSPUDrivers())")

// ── 2. Stream accel + gyro ────────────────────────────────────────────────
final class Ctx { var buf = [UInt8](repeating: 0, count: 256); var name = ""; var n = 0
                  var peak = 0.0; var last = (0.0, 0.0, 0.0) }
var ctxs: [Ctx] = []
let cb: IOHIDReportCallback = { p, _, _, _, _, rep, len in
    let c = Unmanaged<Ctx>.fromOpaque(p!).takeUnretainedValue()
    guard len >= 18 else { return }
    func i32(_ o: Int) -> Int32 { var v: Int32 = 0; memcpy(&v, rep.advanced(by: o), 4); return Int32(littleEndian: v) }
    let x = Double(i32(6))/65536, y = Double(i32(10))/65536, z = Double(i32(14))/65536
    c.n += 1; c.last = (x, y, z)
    let m = (x*x + y*y + z*z).squareRoot()
    if m > c.peak { c.peak = m }
    if c.n <= 3 { print(String(format:"  [%@] x=%+.4f y=%+.4f z=%+.4f  |v|=%.4f", c.name, x, y, z, m)) }
}

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDPrimaryUsagePageKey: 0xFF00] as CFDictionary)
_ = IOHIDManagerOpen(mgr, 0)
for d in (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? [] {
    let u = IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
    guard u == 3 || u == 9 else { continue }
    _ = IOHIDDeviceOpen(d, 0)
    let c = Ctx(); c.name = u == 3 ? "ACCEL" : "GYRO "; ctxs.append(c)
    c.buf.withUnsafeMutableBufferPointer { p in
        IOHIDDeviceRegisterInputReportCallback(d, p.baseAddress!, p.count, cb,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(c).toOpaque())) }
    IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
}

let t0 = Date()
print("\n--- 6s: TAP THE DESK next to the laptop a few times ---")
DispatchQueue.global().asyncAfter(deadline: .now()+6) { CFRunLoopStop(CFRunLoopGetMain()) }
CFRunLoopRun()
let dt = Date().timeIntervalSince(t0)
print("\n═══ RESULT ═══")
for c in ctxs {
    print(String(format:"  %@  %5d reports  %6.0f Hz   rest |v|=%.4f g   peak |v|=%.3f g",
          c.name, c.n, Double(c.n)/dt,
          (c.last.0*c.last.0 + c.last.1*c.last.1 + c.last.2*c.last.2).squareRoot(), c.peak))
}
print(ctxs.contains { $0.n > 0 } ? "\n  ✅ SPU IMU READABLE FROM SWIFT, euid=\(geteuid())" : "\n  ❌ still nothing")
