import Foundation
import CoreFoundation
typealias ESC = UnsafeMutableRawPointer
typealias SVC = UnsafeMutableRawPointer
typealias EVT = UnsafeMutableRawPointer
let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)!
func sym(_ n: String) -> UnsafeMutableRawPointer? { dlsym(h, n) }

let createWithType = unsafeBitCast(sym("IOHIDEventSystemClientCreateWithType")!, to: (@convention(c) (CFAllocator?, Int32, CFDictionary?) -> ESC?).self)
let plainCreate    = unsafeBitCast(sym("IOHIDEventSystemClientCreate")!,        to: (@convention(c) (CFAllocator?) -> ESC?).self)
let copySvc        = unsafeBitCast(sym("IOHIDEventSystemClientCopyServices")!,  to: (@convention(c) (ESC) -> CFArray?).self)
let setMatch       = unsafeBitCast(sym("IOHIDEventSystemClientSetMatching")!,   to: (@convention(c) (ESC, CFDictionary?) -> Int32).self)
let copyProp       = unsafeBitCast(sym("IOHIDServiceClientCopyProperty")!,      to: (@convention(c) (SVC, CFString) -> CFTypeRef?).self)
let copyEvt        = unsafeBitCast(sym("IOHIDServiceClientCopyEvent")!,         to: (@convention(c) (SVC, Int64, Int32, Int64) -> EVT?).self)
let getFloat       = unsafeBitCast(sym("IOHIDEventGetFloatValue")!,             to: (@convention(c) (EVT, Int32) -> Double).self)
func fld(_ t: Int64, _ i: Int32) -> Int32 { Int32(t << 16) | i }

print("uid=\(getuid())\n")
let names = [0:"Admin",1:"Monitor",2:"RateControlled",3:"Simple"]

func dump(_ label: String, _ c: ESC?) {
    guard let c else { print("\(label): create FAILED"); return }
    let svcs = (copySvc(c) as? [SVC]) ?? []
    print("\(label): services=\(svcs.count)")
    guard !svcs.isEmpty else { return }
    for s in svcs {
        let up = (copyProp(s, "PrimaryUsagePage" as CFString) as? NSNumber)?.intValue ?? -1
        let u  = (copyProp(s, "PrimaryUsage" as CFString) as? NSNumber)?.intValue ?? -1
        let nm = (copyProp(s, "Product" as CFString) as? String) ?? ""
        let mark = up == 0xFF00 ? " ★SPU" : ""
        print(String(format: "    page=0x%04X usage=%-4d %@%@", up, u, nm as NSString, mark as NSString))
        if up == 0xFF00 {
            for (l, t) in [("ACCEL", Int64(13)), ("GYRO", Int64(20)), ("ALS", Int64(12))] {
                if let e = copyEvt(s, t, 0, 0) {
                    print(String(format:"        ✅ %@ x=%+.5f y=%+.5f z=%+.5f", l,
                          getFloat(e, fld(t,0)), getFloat(e, fld(t,1)), getFloat(e, fld(t,2))))
                }
            }
        }
    }
}

// A: typed clients, NO SetMatching call at all
for t in 0...3 { dump("typed \(t) (\(names[t]!)) — no SetMatching", createWithType(kCFAllocatorDefault, Int32(t), nil)) }
// B: typed client + EMPTY matching dictionary
for t in [0, 1] {
    if let c = createWithType(kCFAllocatorDefault, Int32(t), nil) {
        _ = setMatch(c, [:] as CFDictionary)
        dump("typed \(t) (\(names[t]!)) — empty dict", c)
    }
}
// C: plain client, no matching
dump("plain create — no SetMatching", plainCreate(kCFAllocatorDefault))
