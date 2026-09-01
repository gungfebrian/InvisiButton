import Foundation
import IOKit.hid
final class Ctx { var buf = [UInt8](repeating: 0, count: 256); var name = "" }
var ctxs: [Ctx] = []; var total = 0
let cb: IOHIDReportCallback = { p, _, _, _, rid, rep, len in
    let c = Unmanaged<Ctx>.fromOpaque(p!).takeUnretainedValue(); total += 1
    if total <= 4 { print("[\(c.name)] len=\(len)") }
}
for opt in [IOOptionBits(kIOHIDOptionsTypeSeizeDevice)] {
  let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
  IOHIDManagerSetDeviceMatching(mgr, [kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDPrimaryUsageKey: 3] as CFDictionary)
  _ = IOHIDManagerOpen(mgr, opt)
  for d in (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? [] {
    let rc = IOHIDDeviceOpen(d, opt)
    print("seize open rc=\(String(format:"0x%X", rc))  \(rc == kIOReturnExclusiveAccess ? "EXCLUSIVE_ACCESS" : rc == kIOReturnNotPermitted ? "NOT_PERMITTED" : "")")
    let c = Ctx(); c.name = "accel"; ctxs.append(c)
    c.buf.withUnsafeMutableBufferPointer { b in
      IOHIDDeviceRegisterInputReportCallback(d, b.baseAddress!, b.count, cb, UnsafeMutableRawPointer(Unmanaged.passUnretained(c).toOpaque())) }
    IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
  }
}
DispatchQueue.global().asyncAfter(deadline: .now()+4) { CFRunLoopStop(CFRunLoopGetMain()) }
CFRunLoopRun()
print("accel reports with SeizeDevice: \(total)")
