// Probe the private IOHIDEventSystem API — the surface Apple's own sensor
// readers use, distinct from raw HID report streaming.
import Foundation
import CoreFoundation

typealias IOHIDEventSystemClientRef = UnsafeMutableRawPointer
typealias IOHIDServiceClientRef     = UnsafeMutableRawPointer
typealias IOHIDEventRef             = UnsafeMutableRawPointer

let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)!
func sym(_ n: String) -> UnsafeMutableRawPointer? { dlsym(h, n) }

guard let pCreate  = sym("IOHIDEventSystemClientCreate"),
      let pMatch   = sym("IOHIDEventSystemClientSetMatching"),
      let pCopySvc = sym("IOHIDEventSystemClientCopyServices") else {
    print("MISSING: IOHIDEventSystemClient symbols not exported"); exit(1)
}
let pSvcEvent = sym("IOHIDServiceClientCopyEvent")
let pSvcProp  = sym("IOHIDServiceClientCopyProperty")
let pFloat    = sym("IOHIDEventGetFloatValue")
print("symbols: create=\(pCreate != nil) match=\(pMatch != nil) copySvc=\(pCopySvc != nil) copyEvent=\(pSvcEvent != nil) getFloat=\(pFloat != nil)")

let create  = unsafeBitCast(pCreate,  to: (@convention(c) (CFAllocator?) -> IOHIDEventSystemClientRef?).self)
let setMatch = unsafeBitCast(pMatch,  to: (@convention(c) (IOHIDEventSystemClientRef, CFDictionary?) -> Int32).self)
let copySvc = unsafeBitCast(pCopySvc, to: (@convention(c) (IOHIDEventSystemClientRef) -> CFArray?).self)
let copyEvt = unsafeBitCast(pSvcEvent!, to: (@convention(c) (IOHIDServiceClientRef, Int64, Int32, Int64) -> IOHIDEventRef?).self)
let copyProp = unsafeBitCast(pSvcProp!, to: (@convention(c) (IOHIDServiceClientRef, CFString) -> CFTypeRef?).self)
let getFloat = unsafeBitCast(pFloat!,  to: (@convention(c) (IOHIDEventRef, Int32) -> Double).self)

guard let client = create(kCFAllocatorDefault) else { print("client create FAILED"); exit(1) }
print("event system client: OK")

// no matching = every service the system exposes
_ = setMatch(client, nil)
guard let svcs = copySvc(client) as? [IOHIDServiceClientRef], !svcs.isEmpty else {
    print("CopyServices returned nothing"); exit(1)
}
print("services visible: \(svcs.count)\n")

let ACCEL: Int64 = 13, GYRO: Int64 = 20, ALS: Int64 = 12
func field(_ t: Int64, _ i: Int32) -> Int32 { Int32(t << 16) | i }

for (i, s) in svcs.enumerated() {
    let up = (copyProp(s, "PrimaryUsagePage" as CFString) as? NSNumber)?.intValue ?? -1
    let u  = (copyProp(s, "PrimaryUsage"     as CFString) as? NSNumber)?.intValue ?? -1
    let nm = (copyProp(s, "Product"          as CFString) as? String) ?? ""
    let tr = (copyProp(s, "Transport"        as CFString) as? String) ?? ""
    guard tr == "SPU" || up == 0xFF00 else { continue }
    print("svc[\(i)] page=0x\(String(up, radix:16)) usage=\(u) transport=\(tr) \(nm)")

    for (label, type) in [("ACCEL", ACCEL), ("GYRO", GYRO), ("ALS", ALS)] {
        if let e = copyEvt(s, type, 0, 0) {
            let x = getFloat(e, field(type, 0)), y = getFloat(e, field(type, 1)), z = getFloat(e, field(type, 2))
            print(String(format: "    ✅ %@ event: x=%+.5f y=%+.5f z=%+.5f", label, x, y, z))
        }
    }
}
print("\ndone")
