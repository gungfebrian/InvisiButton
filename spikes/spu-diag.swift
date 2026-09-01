import Foundation
import IOKit
import IOKit.hid

func hex(_ p: UnsafePointer<UInt8>, _ n: Int) -> String {
    (0..<n).map { String(format:"%02x", p[$0]) }.joined(separator: " ")
}
func elemTypeName(_ t: IOHIDElementType) -> String {
    switch t.rawValue {
    case 1: return "Input_Misc"; case 2: return "Input_Button"; case 3: return "Input_Axis"
    case 4: return "Input_Scan"; case 129: return "OUTPUT"; case 257: return "FEATURE"
    case 513: return "Collection"; default: return "type\(t.rawValue)"
    }
}

final class Ctx {
    var buf = [UInt8](repeating: 0, count: 512)
    var name = ""
    var first: [UInt8] = []
    var changed = Set<Int>()
    var n = 0
}
var ctxs: [Ctx] = []

let cb: IOHIDReportCallback = { p, _, _, _, _, rep, len in
    let c = Unmanaged<Ctx>.fromOpaque(p!).takeUnretainedValue()
    c.n += 1
    let bytes = (0..<len).map { rep[$0] }
    if c.first.isEmpty { c.first = bytes; print("  [\(c.name)] first report, \(len)B:\n    \(hex(rep, len))") }
    else { for i in 0..<min(len, c.first.count) where bytes[i] != c.first[i] { c.changed.insert(i) } }
}

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDPrimaryUsagePageKey: 0xFF00] as CFDictionary)
_ = IOHIDManagerOpen(mgr, 0)
let devs = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []

for d in devs.sorted(by: { (IOHIDDeviceGetProperty($0, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0)
                         < (IOHIDDeviceGetProperty($1, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0) }) {
    guard (IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String) == "SPU" else { continue }
    let usage = IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
    let maxIn = IOHIDDeviceGetProperty(d, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
    let maxFt = IOHIDDeviceGetProperty(d, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int ?? 0
    print("\n══════ usage \(usage)  in=\(maxIn)B feature=\(maxFt)B ══════")

    // 1. report descriptor
    if let dd = IOHIDDeviceGetProperty(d, kIOHIDReportDescriptorKey as CFString) as? Data {
        print("  reportDescriptor (\(dd.count)B): " + dd.map { String(format:"%02x", $0) }.joined(separator: " "))
    } else { print("  reportDescriptor: <none>") }

    // 2. elements
    if let els = IOHIDDeviceCopyMatchingElements(d, nil, 0) as? [IOHIDElement], !els.isEmpty {
        print("  elements: \(els.count)")
        for e in els.prefix(24) {
            print(String(format:"    %-14@ page=0x%04X usage=0x%02X rid=%d size=%d cnt=%d",
                  elemTypeName(IOHIDElementGetType(e)) as NSString,
                  IOHIDElementGetUsagePage(e), IOHIDElementGetUsage(e),
                  IOHIDElementGetReportID(e), IOHIDElementGetReportSize(e), IOHIDElementGetReportCount(e)))
        }
    } else { print("  elements: <none>") }

    _ = IOHIDDeviceOpen(d, 0)

    // 3. try reading every feature report id 0..8
    for rid in 0...8 {
        var fb = [UInt8](repeating: 0, count: max(maxFt, 64)); var flen = fb.count
        let r = IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, CFIndex(rid), &fb, &flen)
        if r == kIOReturnSuccess && flen > 0 {
            print("  FEATURE GET rid=\(rid) ok \(flen)B: " + fb.prefix(flen).map { String(format:"%02x",$0) }.joined(separator:" "))
        }
    }

    let c = Ctx(); c.name = "usage\(usage)"; ctxs.append(c)
    c.buf.withUnsafeMutableBufferPointer { p in
        IOHIDDeviceRegisterInputReportCallback(d, p.baseAddress!, p.count, cb,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(c).toOpaque())) }
    IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
}

print("\n--- listening 5s: MOVE / TILT THE LAPTOP NOW ---")
DispatchQueue.global().asyncAfter(deadline: .now()+5) { CFRunLoopStop(CFRunLoopGetMain()) }
CFRunLoopRun()

print("\n══════ WHICH BYTES MOVED ══════")
for c in ctxs {
    print("\(c.name): \(c.n) reports, changing byte offsets: \(c.changed.sorted())")
}
