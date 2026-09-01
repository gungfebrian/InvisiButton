// InvisiButton · Sensor access
//
// D-008: the SPU IMU streams at 800 Hz from an ordinary user process once the
// AppleSPUHIDDriver *service* has been woken. Opening the HID device without
// that succeeds and then delivers zero reports forever, with no error. This cost
// the project a full investigation cycle — see D-007 and D-008.

import Foundation
import IOKit
import IOKit.hid

/// One sample from either channel. Raw integers are kept: the divide is lossless
/// to redo, and the integer is the sensor's actual quantisation (accel 1 LSB =
/// 15.3 µg; the gyroscope only ever emits multiples of 4000, i.e. 0.061 °/s).
struct Sample: Sendable {
    var t: UInt64          // CLOCK_MONOTONIC_RAW ns
    var seq: UInt32        // 16-bit, wraps every 81.92 s at 800 Hz
    var x: Int32
    var y: Int32
    var z: Int32
    var temp: UInt32       // IMU die temperature, ÷65536 → °C

    var gx: Double { Double(x) / 65536 }
    var gy: Double { Double(y) / 65536 }
    var gz: Double { Double(z) / 65536 }
}

enum SPUDriverWaker {
    /// Must run BEFORE any HID device is opened. Idempotent, so it is also the
    /// recovery path after system sleep (T-045).
    @discardableResult
    static func wake() -> Int {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                IOServiceMatching("AppleSPUHIDDriver"), &it) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(it) }
        var n = 0
        while case let svc = IOIteratorNext(it), svc != 0 {
            for (k, v) in [("SensorPropertyReportingState", 1),
                           ("SensorPropertyPowerState", 1),
                           ("ReportInterval", 1250)] {
                IORegistryEntrySetCFProperty(svc, k as CFString, v as CFNumber)
            }
            IOObjectRelease(svc)
            n += 1
        }
        return n
    }
}

/// T-030: name what is missing rather than failing silently (Product Principle 2).
enum HardwareSupport {
    case ok(accel: Bool, gyro: Bool)
    case noSPUDriver
    case noAccelerometer(found: [Int])

    var isUsable: Bool {
        if case .ok(let accel, let gyro) = self { return accel && gyro }
        return false
    }

    var message: String {
        switch self {
        case .ok(_, let gyro):
            return gyro ? "SPU IMU ready — accelerometer and gyroscope."
                        : "Accelerometer found, but the gyroscope is missing. "
                          + "Knock detection is unavailable because both channels are required."
        case .noSPUDriver:
            return """
            No SPU sensor hub on this Mac (\(sysctlString("hw.model")), \
            \(ProcessInfo.processInfo.operatingSystemVersionString)).

            InvisiButton needs an Apple Silicon MacBook. Intel Macs, Mac mini, \
            Mac Studio and iMac have no usable motion sensor.
            """
        case .noAccelerometer(let found):
            return """
            The SPU driver is present but no accelerometer was found.
            Looked for: Transport "SPU", usage page 0xFF00, usage 3, 22-byte reports.
            Found instead: \(found.isEmpty ? "nothing" : found.map { "usage \($0)" }
                                                              .joined(separator: ", ")).

            This usually means a macOS update changed or removed the private \
            interface InvisiButton depends on.
            """
        }
    }
}

func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    guard size > 0 else { return "?" }
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buf, &size, nil, 0)
    return String(cString: buf)
}

final class SensorReader: @unchecked Sendable {
    enum Channel: Int { case accel = 0, gyro = 1 }

    private final class DeviceContext {
        var buf = [UInt8](repeating: 0, count: 64)
        let channel: Channel
        unowned let owner: SensorReader
        init(channel: Channel, owner: SensorReader) {
            self.channel = channel
            self.owner = owner
        }
    }

    private var contexts: [DeviceContext] = []
    private var manager: IOHIDManager?
    private let lock = NSLock()

    /// Called on the run-loop thread for every report. Keep it cheap.
    var onSample: ((Channel, Sample) -> Void)?

    private(set) var lastSampleTime: UInt64 = 0
    private(set) var reportCount: UInt64 = 0

    static func survey() -> (support: HardwareSupport, devices: [(IOHIDDevice, Int)]) {
        let woken = SPUDriverWaker.wake()
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(mgr, [kIOHIDPrimaryUsagePageKey: 0xFF00] as CFDictionary)
        _ = IOHIDManagerOpen(mgr, 0)

        var matched: [(IOHIDDevice, Int)] = []
        var spuUsages: [Int] = []
        for d in (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? [] {
            // T-044: the Apple Internal Keyboard / Trackpad also publishes usage 3
            // on this vendor page, over "FIFO" with 108-byte reports. It opens
            // fine and never delivers a sample.
            guard (IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String) == "SPU"
            else { continue }
            let u = IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
            let m = IOHIDDeviceGetProperty(d, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
            spuUsages.append(u)
            if (u == 3 || u == 9) && m == 22 { matched.append((d, u)) }
        }

        if woken == 0 { return (.noSPUDriver, []) }
        let hasAccel = matched.contains { $0.1 == 3 }
        let hasGyro = matched.contains { $0.1 == 9 }
        if !hasAccel { return (.noAccelerometer(found: spuUsages.sorted()), matched) }
        return (.ok(accel: true, gyro: hasGyro), matched)
    }

    private var thread: Thread?
    private var runLoop: CFRunLoop?

    /// The HID callbacks run on a dedicated thread, not the main run loop.
    /// At 800 Hz on two channels that is 1600 callbacks a second; putting the
    /// detector on the main thread would fight the UI for it.
    func start(devices: [(IOHIDDevice, Int)]) {
        let t = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            self?.attach(devices: devices)
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 1.0, false)
            }
        }
        t.name = "com.invisibutton.sensor"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    func stop() {
        thread?.cancel()
        if let rl = runLoop { CFRunLoopStop(rl) }
        thread = nil
    }

    private func attach(devices: [(IOHIDDevice, Int)]) {
        for (device, usage) in devices {
            guard IOHIDDeviceOpen(device, 0) == kIOReturnSuccess else { continue }
            let ctx = DeviceContext(channel: usage == 3 ? .accel : .gyro, owner: self)
            contexts.append(ctx)
            ctx.buf.withUnsafeMutableBufferPointer { p in
                IOHIDDeviceRegisterInputReportCallback(
                    device, p.baseAddress!, p.count,
                    { context, _, _, _, _, report, length in
                        guard let context, length >= 22 else { return }
                        let c = Unmanaged<DeviceContext>.fromOpaque(context)
                            .takeUnretainedValue()
                        func u32(_ o: Int) -> UInt32 {
                            var v: UInt32 = 0
                            memcpy(&v, report.advanced(by: o), 4)
                            return UInt32(littleEndian: v)
                        }
                        func i32(_ o: Int) -> Int32 {
                            var v: Int32 = 0
                            memcpy(&v, report.advanced(by: o), 4)
                            return Int32(littleEndian: v)
                        }
                        let s = Sample(t: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW),
                                       seq: u32(0), x: i32(6), y: i32(10), z: i32(14),
                                       temp: u32(18))
                        c.owner.lastSampleTime = s.t
                        c.owner.reportCount &+= 1
                        c.owner.onSample?(c.channel, s)
                    },
                    UnsafeMutableRawPointer(Unmanaged.passUnretained(ctx).toOpaque()))
            }
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(),
                                           CFRunLoopMode.defaultMode.rawValue)
        }
    }
}
