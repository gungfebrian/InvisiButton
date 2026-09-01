import Foundation
import CoreFoundation
typealias ESC = UnsafeMutableRawPointer
typealias SVC = UnsafeMutableRawPointer
typealias EVT = UnsafeMutableRawPointer

let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)!
func sym(_ n: String) -> UnsafeMutableRawPointer? { dlsym(h, n) }
for n in ["IOHIDEventSystemClientCreate","IOHIDEventSystemClientCreateWithType",
          "IOHIDEventSystemClientCopyServices","IOHIDServiceClientCopyEvent",
          "IOHIDServiceClientCopyProperty","IOHIDEventGetFloatValue",
          "IOHIDEventSystemClientSetMatching"] {
    print(String(format:"  %-42@ %@", n as NSString, sym(n) != nil ? "present" : "MISSING"))
}
guard let pCWT = sym("IOHIDEventSystemClientCreateWithType"),
      let pCopySvc = sym("IOHIDEventSystemClientCopyServices"),
      let pMatch = sym("IOHIDEventSystemClientSetMatching"),
      let pEvt = sym("IOHIDServiceClientCopyEvent"),
      let pProp = sym("IOHIDServiceClientCopyProperty"),
      let pFlt = sym("IOHIDEventGetFloatValue") else { print("missing symbols"); exit(1) }

let createWithType = unsafeBitCast(pCWT, to: (@convention(c) (CFAllocator?, Int32, CFDictionary?) -> ESC?).self)
let copySvc = unsafeBitCast(pCopySvc, to: (@convention(c) (ESC) -> CFArray?).self)
let setMatch = unsafeBitCast(pMatch, to: (@convention(c) (ESC, CFDictionary?) -> Int32).self)
let copyEvt = unsafeBitCast(pEvt, to: (@convention(c) (SVC, Int64, Int32, Int64) -> EVT?).self)
let copyProp = unsafeBitCast(pProp, to: (@convention(c) (SVC, CFString) -> CFTypeRef?).self)
let getFloat = unsafeBitCast(pFlt, to: (@convention(c) (EVT, Int32) -> Double).self)

let typeNames = [0:"Admin", 1:"Monitor", 2:"RateControlled", 3:"Simple"]
func fld(_ t: Int64, _ i: Int32) -> Int32 { Int32(t << 16) | i }

print("\nuid=\(getuid())")
for t in 0...3 {
    guard let c = createWithType(kCFAllocatorDefault, Int32(t), nil) else {
        print("type \(t) (\(typeNames[t]!)): client create FAILED"); continue }
    _ = setMatch(c, nil)
    let svcs = (copySvc(c) as? [SVC]) ?? []
    print("type \(t) (\(typeNames[t]!)): client OK, services=\(svcs.count)")
    var spu = 0
    for s in svcs {
        let up = (copyProp(s, "PrimaryUsagePage" as CFString) as? NSNumber)?.intValue ?? -1
        let u  = (copyProp(s, "PrimaryUsage" as CFString) as? NSNumber)?.intValue ?? -1
        guard up == 0xFF00 else { continue }
        spu += 1
        var hits: [String] = []
        for (lbl, ty) in [("ACCEL", Int64(13)), ("GYRO", Int64(20)), ("ALS", Int64(12))] {
            if let e = copyEvt(s, ty, 0, 0) {
                hits.append(String(format:"%@ x=%+.5f y=%+.5f z=%+.5f", lbl,
                    getFloat(e, fld(ty,0)), getFloat(e, fld(ty,1)), getFloat(e, fld(ty,2))))
            }
        }
        print("    usage=\(u)  " + (hits.isEmpty ? "no events" : "✅ " + hits.joined(separator: " | ")))
    }
    if svcs.count > 0 && spu == 0 { print("    (no 0xFF00 services among them)") }
}
