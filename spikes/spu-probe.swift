import Foundation
import IOKit
import IOKit.hid

final class Ctx { var buf = [UInt8](repeating: 0, count: 256); var name = "" }
var ctxs: [Ctx] = []
var total = 0
let t0 = Date()

let cb: IOHIDReportCallback = { ctxPtr, result, _, type, rid, report, len in
    let c = Unmanaged<Ctx>.fromOpaque(ctxPtr!).takeUnretainedValue()
    total += 1
    if total <= 6 {
        var hex = ""
        for i in 0..<min(len, 24) { hex += String(format:"%02x ", report[i]) }
        func i32(_ o: Int) -> Int32 { guard o+4 <= len else { return 0 }
            var v: Int32 = 0; memcpy(&v, report.advanced(by: o), 4); return Int32(littleEndian: v) }
        print(String(format:"[%@] rid=%d len=%d  x=%+.4f y=%+.4f z=%+.4f", c.name, rid, len,
              Double(i32(6))/65536, Double(i32(10))/65536, Double(i32(14))/65536))
        print("    raw: \(hex)")
    }
}

// enumerate every SPU HID device, print usage + try to open + set report interval
let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDPrimaryUsagePageKey: 0xFF00] as CFDictionary)
_ = IOHIDManagerOpen(mgr, 0)
let devs = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []

for d in devs {
    let usage = IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
    let transport = IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String ?? "?"
    guard transport == "SPU" else { continue }
    let maxIn = IOHIDDeviceGetProperty(d, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
    let c = Ctx(); c.name = "usage\(usage)/\(maxIn)B"; ctxs.append(c)

    let rc = IOHIDDeviceOpen(d, 0)
    // try to force periodic reporting
    let iv: CFNumber = 1250 as CFNumber   // microseconds -> 800 Hz
    IOHIDDeviceSetProperty(d, "ReportInterval" as CFString, iv)
    let readBack = IOHIDDeviceGetProperty(d, "ReportInterval" as CFString) as? Int ?? -1
    print("dev \(c.name) transport=\(transport) open=\(String(format:"0x%X",rc)) reportInterval=\(readBack)")

    c.buf.withUnsafeMutableBufferPointer { p in
        IOHIDDeviceRegisterInputReportCallback(d, p.baseAddress!, p.count, cb,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(c).toOpaque()))
    }
    IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
}
print("--- listening 6s (SPU devices: \(ctxs.count)) ---")
DispatchQueue.global().asyncAfter(deadline: .now()+6) { CFRunLoopStop(CFRunLoopGetMain()) }
CFRunLoopRun()
print(String(format:"TOTAL reports=%d in %.1fs -> %.0f Hz", total, Date().timeIntervalSince(t0), Double(total)/Date().timeIntervalSince(t0)))
