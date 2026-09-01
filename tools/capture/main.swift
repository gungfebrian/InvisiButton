// InvisiButton · T-004 · capture
//
// Streams the SPU IMU — accelerometer (usage 3) and gyroscope (usage 9) — at the
// native 800 Hz and writes every report to a session file. Undecimated (D-006),
// all three axes preserved (Product Principle 5), labelled by keypress.
//
// This is the instrument every later stage is measured with. It stores raw sensor
// integers rather than scaled floats, keeps the device sequence counter so dropped
// reports are detectable rather than silently interpolated, and never averages,
// filters, or collapses anything.
//
// ── Session file layout ─────────────────────────────────────────────────────
//
// `<name>.ibcap` is a flat array of 32-byte little-endian records, one per HID
// report, in arrival order, both channels interleaved:
//
//   off  size  field   meaning
//   ---  ----  ------  ------------------------------------------------------
//     0     8  t_ns    CLOCK_MONOTONIC_RAW ns since session t0, at callback entry
//     8     4  seq     device sequence counter, report bytes 0..3 — 16-bit, wraps
//    12     1  chan    0 = accel, 1 = gyro
//    13     1  label   label id; the id→name table is in the sidecar JSON
//    14     1  force   0 unset · 1 soft · 2 normal · 3 hard
//    15     1  mark    mark counter mod 256, increments on SPACE
//    16     4  x       raw int32 — divide by 65536 for g (accel) or deg/s (gyro)
//    20     4  y
//    24     4  z
//    28     4  temp    IMU die temperature, raw — divide by 65536 for °C
//
// `<name>.json` is the sidecar: machine, desk, pose, user, the label table, every
// label and mark event with its timestamp, and per-channel report/drop/temperature
// counts.
//
// ── Temperature ─────────────────────────────────────────────────────────────
//
// Report bytes 18..21 are the sensor die temperature in the same ÷65536 fixed
// point as the axes. Verified 2026-08-30 on Mac17,2: the value is identical on
// the accelerometer and gyroscope reports (one die, one temperature sensor) and
// rose +0.31 °C over 25 s of ten-core load while sitting flat beforehand. It is
// captured because IMU zero-g offset and gyro bias both drift with temperature,
// and corpus sessions will be recorded at different thermal states.
//
// ── Two things about timing ─────────────────────────────────────────────────
//
// `t_ns` is when the run loop handed us the report, not when the sensor sampled
// it. It jitters: measured p50 1246 µs, p95 1615 µs, max 2365 µs on Mac17,2,
// because reports arrive batched. `seq` is the ground truth for sample ordering
// and for spacing at the nominal 1250 µs period. Use seq for anything that cares
// about time; use t_ns only to align against wall-clock label events.
//
// **`seq` is 16-bit and wraps at 65535 → 0, every 81.92 s at 800 Hz.** The high
// two bytes of the field are always zero. Any offline tool must unwrap it —
// `delta = (seq - prev) mod 65536` — before using it as a sample index. A
// one-hour typing session wraps 44 times. Getting this wrong does not throw; it
// silently reorders the corpus.
//
// `mark` records that the operator said an event happened. It carries human
// reaction delay of a few hundred milliseconds and is NOT an onset timestamp.
// Onsets get recovered offline by the T-007 detector. Marks are for counting
// ("did the detector find the ten knocks I made?") and coarse segmentation only.

import Foundation
import IOKit
import IOKit.hid

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Labels

struct LabelDef {
    let id: UInt8
    let key: Character
    let name: String
}

let labelTable: [LabelDef] = [
    LabelDef(id:  0, key: "0", name: "none"),
    LabelDef(id:  1, key: "l", name: "knock-left"),
    LabelDef(id:  2, key: "r", name: "knock-right"),
    LabelDef(id:  3, key: "f", name: "knock-front"),
    LabelDef(id:  4, key: "b", name: "knock-back"),
    LabelDef(id:  5, key: "c", name: "knock-chassis"),
    LabelDef(id:  6, key: "t", name: "typing"),
    LabelDef(id:  7, key: "p", name: "trackpad-click"),
    LabelDef(id:  8, key: "n", name: "laptop-nudge"),
    LabelDef(id:  9, key: "u", name: "cup-down"),
    LabelDef(id: 10, key: "d", name: "desk-impact-other"),
    LabelDef(id: 11, key: "a", name: "ambient"),
]

let labelByKey  = Dictionary(uniqueKeysWithValues: labelTable.map { ($0.key, $0) })
let labelByID   = Dictionary(uniqueKeysWithValues: labelTable.map { ($0.id, $0) })

let forceNames = ["unset", "soft", "normal", "hard"]

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Terminal

nonisolated(unsafe) var savedTermios: termios? = nil

func enterRawMode() {
    var t = termios()
    guard tcgetattr(STDIN_FILENO, &t) == 0 else { return }
    savedTermios = t
    var raw = t
    raw.c_lflag &= ~(tcflag_t(ICANON) | tcflag_t(ECHO))
    raw.c_cc.16 = 1   // VMIN  — block until at least one byte
    raw.c_cc.17 = 0   // VTIME — no inter-byte timer
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
}

func restoreTerminal() {
    if var t = savedTermios {
        tcsetattr(STDIN_FILENO, TCSANOW, &t)
        savedTermios = nil
    }
}

func out(_ s: String) { fputs(s, stdout); fflush(stdout) }
func clearLine()      { out("\r\u{1B}[2K") }

/// Left-justify to `n` columns. `String(format:)`'s `%-6s` wants a C string and
/// fights Swift about it; this is shorter than the cast that satisfies it.
func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Record writer
//
// The HID callback must never touch the disk. It memcpys 32 bytes into a
// preallocated buffer; a background queue writes full buffers. If the writer is
// still busy when a buffer fills, the callback writes synchronously rather than
// drop a sample, and counts the stall. Losing data is not an option the
// instrument gets to take.

final class RecordWriter: @unchecked Sendable {
    private let fd: Int32
    private let cap: Int
    private var buf: UnsafeMutableRawPointer
    private var spare: UnsafeMutableRawPointer?
    private var len = 0
    private let lock = NSLock()
    private let q = DispatchQueue(label: "com.invisibutton.capture.writer")

    private(set) var bytesWritten = 0
    private(set) var syncStalls = 0

    init?(path: String, capacity: Int = 1 << 18) {
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return nil }
        cap = capacity
        buf   = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 32)
        spare = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 32)
    }

    func append(t: UInt64, seq: UInt32, chan: UInt8, label: UInt8, force: UInt8,
                mark: UInt8, x: Int32, y: Int32, z: Int32, temp: UInt32) {
        lock.lock()
        if len + 32 > cap { rotateLocked() }
        let p = buf.advanced(by: len)
        p.storeBytes(of: t.littleEndian,    toByteOffset:  0, as: UInt64.self)
        p.storeBytes(of: seq.littleEndian,  toByteOffset:  8, as: UInt32.self)
        p.storeBytes(of: chan,              toByteOffset: 12, as: UInt8.self)
        p.storeBytes(of: label,             toByteOffset: 13, as: UInt8.self)
        p.storeBytes(of: force,             toByteOffset: 14, as: UInt8.self)
        p.storeBytes(of: mark,              toByteOffset: 15, as: UInt8.self)
        p.storeBytes(of: x.littleEndian,    toByteOffset: 16, as: Int32.self)
        p.storeBytes(of: y.littleEndian,    toByteOffset: 20, as: Int32.self)
        p.storeBytes(of: z.littleEndian,    toByteOffset: 24, as: Int32.self)
        p.storeBytes(of: temp.littleEndian, toByteOffset: 28, as: UInt32.self)
        len += 32
        lock.unlock()
    }

    func flush() { lock.lock(); rotateLocked(); lock.unlock() }

    /// Drain the writer queue and close. Call once, at the end.
    func close() {
        flush()
        q.sync {}
        _ = Darwin.close(fd)
    }

    /// Caller must hold `lock`. `writeBlock` deliberately does not take it — the
    /// stall path below runs with the lock already held and NSLock is not
    /// recursive.
    private func rotateLocked() {
        guard len > 0 else { return }
        if let s = spare {
            let old = buf, oldLen = len
            buf = s; spare = nil; len = 0
            q.async {
                let n = self.writeBlock(old, oldLen)
                self.lock.lock()
                self.bytesWritten += n
                self.spare = old
                self.lock.unlock()
            }
        } else {
            // Writer still busy. Block here rather than lose reports.
            bytesWritten += writeBlock(buf, len)
            len = 0
            syncStalls += 1
        }
    }

    private func writeBlock(_ p: UnsafeMutableRawPointer, _ n: Int) -> Int {
        var off = 0
        while off < n {
            let w = write(fd, p.advanced(by: off), n - off)
            if w <= 0 { break }
            off += w
        }
        return off
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Channel state

final class ChannelState {
    let chan: UInt8
    let name: String
    var reports: UInt64 = 0
    var drops: UInt64 = 0
    var seqResets: UInt64 = 0
    var lastSeq: UInt32? = nil
    var firstSeq: UInt32? = nil
    var wraps: UInt64 = 0
    var seqAdvance: UInt64 = 0      // sum of modular deltas; == reports-1+drops
    var tempMin: Double = .infinity
    var tempMax: Double = -.infinity
    var tempLast: Double = 0

    // Per-axis peak absolute value since the last mark. Display only — this is a
    // liveness and sanity readout for the operator, never a stored feature.
    var pkX = 0.0, pkY = 0.0, pkZ = 0.0

    init(chan: UInt8, name: String) { self.chan = chan; self.name = name }

    func resetPeaks() { pkX = 0; pkY = 0; pkZ = 0 }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Capture session

struct SessionMeta {
    var desk = ""
    var material = ""
    var compliance = ""
    var pose = "default"
    var user = ProcessInfo.processInfo.environment["USER"] ?? "unknown"
    var note = ""
}

final class Capture: @unchecked Sendable {
    let writer: RecordWriter?
    let meta: SessionMeta
    let t0: UInt64
    let startedAt = Date()

    let accel = ChannelState(chan: 0, name: "accel")
    let gyro  = ChannelState(chan: 1, name: "gyro")

    private let lock = NSLock()
    private var _label: UInt8 = 0
    private var _force: UInt8 = 0
    private var _mark: UInt8 = 0

    var labelEvents: [[String: Any]] = []
    var markEvents:  [[String: Any]] = []

    /// Every keystroke, timestamped. A finger hitting the keyboard is a chassis
    /// impulse the accelerometer sees — measured at 0–13 ms before the key
    /// registers in software, at roughly the amplitude of a light desk knock.
    /// Without this list those artifacts are indistinguishable from real events
    /// in the corpus. See D-011.
    var keyEvents: [[String: Any]] = []

    var running = true

    /// Set before the writer closes. The HID run loop keeps delivering reports
    /// while `finish()` is tearing down on another thread; without this the
    /// counters advance past the last record actually written and the sidecar
    /// disagrees with its own file.
    var stopped = false

    init(writer: RecordWriter?, meta: SessionMeta) {
        self.writer = writer
        self.meta = meta
        self.t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    }

    func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) &- t0 }

    // Read by the HID callback on every report; written rarely, from the key thread.
    func state() -> (UInt8, UInt8, UInt8) {
        lock.lock(); defer { lock.unlock() }
        return (_label, _force, _mark)
    }

    func logKey(_ c: Character) {
        keyEvents.append(["t_ns": now(), "key": String(c)])
    }

    func halt() { lock.lock(); stopped = true; lock.unlock() }

    func setLabel(_ id: UInt8) {
        let t = now()
        lock.lock(); _label = id; lock.unlock()
        labelEvents.append(["t_ns": t, "label": Int(id), "name": labelByID[id]?.name ?? "?"])
        writer?.flush()
    }

    func setForce(_ f: UInt8) {
        let t = now()
        lock.lock(); _force = f; lock.unlock()
        labelEvents.append(["t_ns": t, "force": Int(f), "name": forceNames[Int(f)]])
    }

    func addMark() -> UInt8 {
        let t = now()
        lock.lock(); _mark = _mark &+ 1; let m = _mark; let l = _label; lock.unlock()
        markEvents.append(["t_ns": t, "mark": Int(m), "label": Int(l),
                           "name": labelByID[l]?.name ?? "?"])
        writer?.flush()
        return m
    }

    func ingest(_ cs: ChannelState, seq: UInt32, x: Int32, y: Int32, z: Int32, temp: UInt32) {
        lock.lock(); let halted = stopped; lock.unlock()
        if halted { return }
        if let last = cs.lastSeq {
            // 16-bit counter: modular difference handles the wrap transparently.
            let delta = (UInt64(seq) &+ 65536 &- UInt64(last)) % 65536
            if delta == 0 {
                cs.seqResets += 1           // duplicate seq — should never happen
            } else {
                cs.seqAdvance += delta
                if delta > 1 { cs.drops += delta - 1 }
                if seq < last { cs.wraps += 1 }
            }
        } else {
            cs.firstSeq = seq
        }
        cs.lastSeq = seq
        cs.reports += 1
        let tc = Double(temp) / 65536
        cs.tempLast = tc
        if tc < cs.tempMin { cs.tempMin = tc }
        if tc > cs.tempMax { cs.tempMax = tc }

        let fx = abs(Double(x)) / 65536, fy = abs(Double(y)) / 65536, fz = abs(Double(z)) / 65536
        if fx > cs.pkX { cs.pkX = fx }
        if fy > cs.pkY { cs.pkY = fy }
        if fz > cs.pkZ { cs.pkZ = fz }

        let (l, f, m) = state()
        writer?.append(t: now(), seq: seq, chan: cs.chan, label: l, force: f,
                       mark: m, x: x, y: y, z: z, temp: temp)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Sensor plumbing

/// Wake the `AppleSPUHIDDriver` **services** before opening any HID device.
/// Opening the device without this succeeds and then delivers zero reports
/// forever, with no error. See D-008 — this is the single most important call
/// in the project.
@discardableResult
func wakeSPUDrivers() -> Int {
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

struct FoundDevice {
    let device: IOHIDDevice
    let usage: Int
    let maxInput: Int
}

/// T-044: match on `Transport == "SPU"`. The Apple Internal Keyboard/Trackpad
/// also publishes usage 3 on vendor page 0xFF00 with `Transport == "FIFO"` and a
/// 108-byte report; it opens fine and never delivers an accelerometer sample.
func findSPUDevices() -> [FoundDevice] {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    IOHIDManagerSetDeviceMatching(mgr, [kIOHIDPrimaryUsagePageKey: 0xFF00] as CFDictionary)
    _ = IOHIDManagerOpen(mgr, 0)
    var found: [FoundDevice] = []
    for d in (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? [] {
        guard (IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String) == "SPU"
        else { continue }
        let u = IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
        let m = IOHIDDeviceGetProperty(d, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
        guard u == 3 || u == 9, m == 22 else { continue }
        found.append(FoundDevice(device: d, usage: u, maxInput: m))
    }
    return found
}

func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    guard size > 0 else { return "?" }
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buf, &size, nil, 0)
    return String(cString: buf)
}

// Kept alive for the lifetime of the process; the HID callback holds unretained
// pointers into these.
final class DeviceCtx {
    var buf = [UInt8](repeating: 0, count: 64)
    let cs: ChannelState
    let cap: Capture
    init(cs: ChannelState, cap: Capture) { self.cs = cs; self.cap = cap }
}

let reportCallback: IOHIDReportCallback = { context, _, _, _, _, report, length in
    guard let context, length >= 22 else { return }
    let ctx = Unmanaged<DeviceCtx>.fromOpaque(context).takeUnretainedValue()
    func u32(_ o: Int) -> UInt32 {
        var v: UInt32 = 0; memcpy(&v, report.advanced(by: o), 4); return UInt32(littleEndian: v)
    }
    func i32(_ o: Int) -> Int32 {
        var v: Int32 = 0; memcpy(&v, report.advanced(by: o), 4); return Int32(littleEndian: v)
    }
    ctx.cap.ingest(ctx.cs, seq: u32(0), x: i32(6), y: i32(10), z: i32(14), temp: u32(18))
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Arguments

func usage() -> String {
    var s = """
    capture — InvisiButton T-004 · full-rate SPU IMU session recorder

    USAGE
      capture --desk <id> --material <str> --compliance hard|compliant [options]
      capture --sanity
      capture --list

    REQUIRED
      --desk <id>          short desk identifier, e.g. oak-dining, office-standing
      --material <str>     solid-oak · particleboard-veneer · glass · mdf · steel …
      --compliance <c>     hard | compliant   (does the surface flex under a knock?)

    OPTIONS
      --pose <str>         laptop pose, default "default". Use rot15 / rot30 /
                           moved10cm / edge for T-015 robustness sessions.
      --user <id>          who is knocking, default $USER
      --note <str>         free text, goes in the sidecar
      --out <dir>          output directory, default ./data/sessions
      --duration <sec>     stop automatically after N seconds
      --sanity             3-second health check, writes nothing, exits
      --list               list matched SPU devices and exit

    KEYS DURING CAPTURE

    """
    for l in labelTable where l.id != 0 {
        s += "      \(l.key)                    \(l.name)\n"
    }
    s += """
          0                    clear label to none
          1 2 3                force: soft / normal / hard
          SPACE                mark — "an event just happened" (counting, not timing)
          q                    finish and write the session
          ?                    show these keys

    LABELLING PROTOCOL
      Set the label first, then knock. The label is a span: every sample carries it
      until you change it. Onset times are recovered offline by the detector, so
      your reaction time never contaminates them. SPACE marks are for counting
      events, not for timing them.
    """
    return s
}

var meta = SessionMeta()
var outDir = "data/sessions"
var duration: Double? = nil
var sanity = false
var listOnly = false

let args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    let a = args[i]
    func next() -> String { i += 1; return i < args.count ? args[i] : "" }
    switch a {
    case "--desk":       meta.desk = next()
    case "--material":   meta.material = next()
    case "--compliance": meta.compliance = next()
    case "--pose":       meta.pose = next()
    case "--user":       meta.user = next()
    case "--note":       meta.note = next()
    case "--out":        outDir = next()
    case "--duration":   duration = Double(next())
    case "--sanity":     sanity = true
    case "--list":       listOnly = true
    case "-h", "--help": print(usage()); exit(0)
    default:
        FileHandle.standardError.write("unknown argument: \(a)\n\n".data(using: .utf8)!)
        print(usage()); exit(64)
    }
    i += 1
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Preflight
//
// Product Principle 2: degrade loudly and specifically. Name what is missing.

let woken = wakeSPUDrivers()
if woken == 0 {
    FileHandle.standardError.write("""
    FATAL: no AppleSPUHIDDriver services found.

      machine: \(sysctlString("hw.model"))
      os:      \(ProcessInfo.processInfo.operatingSystemVersionString)

    This Mac has no SPU sensor hub, or macOS has removed the driver. InvisiButton
    requires an Apple Silicon MacBook. Intel Macs, Mac mini, Mac Studio and iMac
    have no usable SPU IMU.

    """.data(using: .utf8)!)
    exit(3)
}

let devices = findSPUDevices()

if listOnly {
    print("AppleSPUHIDDriver services woken: \(woken)")
    print("SPU IMU devices matched (Transport == \"SPU\", 22-byte reports):")
    for d in devices {
        print("  usage \(d.usage)  \(d.usage == 3 ? "accelerometer" : "gyroscope")  maxInput \(d.maxInput)")
    }
    exit(devices.isEmpty ? 3 : 0)
}

let hasAccel = devices.contains { $0.usage == 3 }
let hasGyro  = devices.contains { $0.usage == 9 }
if !hasAccel {
    FileHandle.standardError.write("""
    FATAL: accelerometer not found.

      machine: \(sysctlString("hw.model"))
      os:      \(ProcessInfo.processInfo.operatingSystemVersionString)
      looked for: Transport "SPU", usage page 0xFF00, usage 3, 22-byte reports
      SPU driver services woken: \(woken)
      matched SPU IMU devices: \(devices.map { "usage \($0.usage)" }.joined(separator: ", "))

    Without the accelerometer there is nothing to capture.

    """.data(using: .utf8)!)
    exit(3)
}
if !hasGyro {
    FileHandle.standardError.write(
        "WARNING: gyroscope (usage 9) not found — capturing accelerometer only.\n"
        .data(using: .utf8)!)
}

if !sanity {
    for (flag, val) in [("--desk", meta.desk), ("--material", meta.material),
                        ("--compliance", meta.compliance)] where val.isEmpty {
        FileHandle.standardError.write("missing required argument \(flag)\n\n".data(using: .utf8)!)
        print(usage()); exit(64)
    }
    guard ["hard", "compliant"].contains(meta.compliance) else {
        FileHandle.standardError.write("--compliance must be 'hard' or 'compliant'\n".data(using: .utf8)!)
        exit(64)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Open session

let stamp: String = {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    f.timeZone = TimeZone(identifier: "UTC")
    return f.string(from: Date())
}()

var basePath = ""
var writer: RecordWriter? = nil

if !sanity {
    try? FileManager.default.createDirectory(atPath: outDir,
                                             withIntermediateDirectories: true)
    let safe = { (s: String) in s.replacingOccurrences(of: "/", with: "-")
                                 .replacingOccurrences(of: " ", with: "-") }
    basePath = "\(outDir)/\(stamp)_desk-\(safe(meta.desk))_pose-\(safe(meta.pose))_user-\(safe(meta.user))"
    guard let w = RecordWriter(path: basePath + ".ibcap") else {
        FileHandle.standardError.write("FATAL: cannot open \(basePath).ibcap for writing\n"
                                       .data(using: .utf8)!)
        exit(4)
    }
    writer = w
}

let cap = Capture(writer: writer, meta: meta)
nonisolated(unsafe) var gCapture: Capture? = cap

var ctxs: [DeviceCtx] = []
for d in devices {
    let cs = d.usage == 3 ? cap.accel : cap.gyro
    guard IOHIDDeviceOpen(d.device, 0) == kIOReturnSuccess else {
        FileHandle.standardError.write("WARNING: could not open usage \(d.usage)\n"
                                       .data(using: .utf8)!)
        continue
    }
    let ctx = DeviceCtx(cs: cs, cap: cap)
    ctxs.append(ctx)
    ctx.buf.withUnsafeMutableBufferPointer { p in
        IOHIDDeviceRegisterInputReportCallback(
            d.device, p.baseAddress!, p.count, reportCallback,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(ctx).toOpaque()))
    }
    IOHIDDeviceScheduleWithRunLoop(d.device, CFRunLoopGetCurrent(),
                                   CFRunLoopMode.defaultMode.rawValue)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Finish

nonisolated(unsafe) var finished = false
nonisolated(unsafe) var statusTimer: DispatchSourceTimer? = nil

func writeSidecar() {
    guard !basePath.isEmpty else { return }
    let elapsed = Double(cap.now()) / 1e9

    func chanDict(_ c: ChannelState) -> [String: Any] {
        [
            "name": c.name, "chan": Int(c.chan),
            "reports": c.reports, "drops": c.drops,
            "seq_resets": c.seqResets,
            "seq_advance": c.seqAdvance,
            "seq_wraps": c.wraps,
            "lossless": c.reports > 0 && c.seqAdvance == c.reports - 1,
            "temp_c_min": c.reports > 0 ? c.tempMin : 0,
            "temp_c_max": c.reports > 0 ? c.tempMax : 0,
            "temp_c_last": c.tempLast,
            "first_seq": c.firstSeq.map { Int($0) } as Any,
            "last_seq": c.lastSeq.map { Int($0) } as Any,
            "mean_rate_hz": elapsed > 0 ? Double(c.reports) / elapsed : 0,
        ]
    }

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    let doc: [String: Any] = [
        "schema": "invisibutton.capture/1",
        "record_bytes": 32,
        "record_fields": [
            "t_ns:u64@0", "seq:u32@8", "chan:u8@12", "label:u8@13",
            "force:u8@14", "mark:u8@15", "x:i32@16", "y:i32@20",
            "z:i32@24", "temp:u32@28",
        ],
        "scale_divisor": 65536,
        "temp_note": "report bytes 18..21 = IMU die temperature, same /65536 scale, shared by both channels",
        "nominal_rate_hz": 800,
        "nominal_report_interval_us": 1250,
        "started_at": iso.string(from: cap.startedAt),
        "duration_s": elapsed,
        "machine": [
            "model": sysctlString("hw.model"),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ],
        "desk": [
            "id": meta.desk,
            "material": meta.material,
            "compliance": meta.compliance,
        ],
        "pose": meta.pose,
        "user": meta.user,
        "note": meta.note,
        "spu_driver_services_woken": woken,
        "labels": labelTable.map { ["id": Int($0.id), "key": String($0.key), "name": $0.name] },
        "forces": forceNames,
        "label_events": cap.labelEvents,
        "mark_events": cap.markEvents,
        "key_events": cap.keyEvents,
        "key_artifact_note": "every keystroke injects a chassis impulse the accelerometer sees, 0-13 ms before the key registers; exclude onsets near these timestamps",
        "channels": [chanDict(cap.accel), chanDict(cap.gyro)],
        "writer": [
            "bytes": cap.writer?.bytesWritten ?? 0,
            "sync_stalls": cap.writer?.syncStalls ?? 0,
        ],
    ]

    if let data = try? JSONSerialization.data(withJSONObject: doc,
                                              options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: basePath + ".json"))
    }
}

func finish(_ reason: String) {
    guard !finished else { return }
    finished = true
    cap.running = false
    statusTimer?.cancel()
    cap.halt()              // stop ingest before the writer closes
    cap.writer?.close()
    writeSidecar()
    restoreTerminal()

    let elapsed = Double(cap.now()) / 1e9
    clearLine()
    print("\n═══ session complete — \(reason) ═══")
    for c in [cap.accel, cap.gyro] where c.reports > 0 {
        let rate = elapsed > 0 ? Double(c.reports) / elapsed : 0
        let lossPct = c.reports + c.drops > 0
            ? 100.0 * Double(c.drops) / Double(c.reports + c.drops) : 0
        let lossless = c.seqAdvance == c.reports - 1
        print("  \(pad(c.name, 7))"
              + String(format: "%8llu reports  %6.1f Hz  drops %llu (%.3f%%)  wraps %llu  ",
                       c.reports, rate, c.drops, lossPct, c.wraps)
              + (lossless ? "LOSSLESS" : "GAPPED"))
        print(String(format: "          die temp %.2f – %.2f °C", c.tempMin, c.tempMax))
    }
    if let w = cap.writer {
        print(String(format: "  wrote  %.1f MB  (%llu sync stalls)",
                     Double(w.bytesWritten) / 1_048_576, UInt64(w.syncStalls)))
    }
    print(String(format: "  marks  %d   label spans %d", cap.markEvents.count, cap.labelEvents.count))

    // Name the labels that were actually recorded. A block whose label keypress
    // never landed is invisible until analysis, by which point the desk may be
    // gone — one session was lost that way on 2026-08-30.
    let used = cap.labelEvents.compactMap { $0["label"] != nil ? $0["name"] as? String : nil }
    var seen: [String] = []
    for u in used where !seen.contains(u) { seen.append(u) }
    print("  labels " + (seen.isEmpty ? "NONE — every sample is unlabelled"
                                      : seen.joined(separator: ", ")))
    if seen.count < 2 {
        print("")
        print("  ⚠︎  only \(seen.count) label span in this session.")
        print("     If you meant to record more than one class, a label keypress did not land")
        print("     and everything is filed under the label above. Recapture before moving on.")
    }
    if !basePath.isEmpty {
        print("  file   \(basePath).ibcap")
        print("  meta   \(basePath).json")
    }
    exit(0)
}

atexit { restoreTerminal() }

signal(SIGINT, SIG_IGN)
let sigsrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
sigsrc.setEventHandler { finish("interrupted") }
sigsrc.resume()

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Sanity mode

if sanity {
    print("SPU driver services woken: \(woken)")
    print("devices: " + devices.map { $0.usage == 3 ? "accel" : "gyro" }.joined(separator: ", "))
    print("sampling 3 s — hold still…")
    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { CFRunLoopStop(CFRunLoopGetMain()) }
    CFRunLoopRun()
    let el = Double(cap.now()) / 1e9
    var ok = true
    for c in [cap.accel, cap.gyro] {
        let rate = Double(c.reports) / el
        let good = c.reports > 0 && rate > 700 && c.drops == 0
        if c.reports > 0 && !good { ok = false }
        print("  \(pad(c.name, 7))"
              + String(format: "%6llu reports  %6.1f Hz  drops %llu   ", c.reports, rate, c.drops)
              + (c.reports == 0 ? "ABSENT" : (good ? "ok" : "DEGRADED")))
    }
    let a = cap.accel
    if a.reports > 0 {
        print(String(format: "  accel peak-abs since start  x=%.4f  y=%.4f  z=%.4f g",
                     a.pkX, a.pkY, a.pkZ))
        print("  (z near 1.0 g at rest means gravity is where it should be)")
        print(String(format: "  IMU die temperature  %.2f °C", a.tempLast))
    }
    print(ok && cap.accel.reports > 0 ? "\n  READY" : "\n  NOT READY")
    exit(ok && cap.accel.reports > 0 ? 0 : 1)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Interactive capture

print("""
InvisiButton capture · \(sysctlString("hw.model")) · \(woken) SPU driver services woken
desk \(meta.desk) (\(meta.material), \(meta.compliance)) · pose \(meta.pose) · user \(meta.user)
writing \(basePath).ibcap

keys:  l left  r right  f front  b back  c chassis  |  t typing  p trackpad
       n nudge  u cup  d other-impact  a ambient  0 none
       1/2/3 force soft/normal/hard  ·  SPACE mark  ·  ? help  ·  q finish

Set the label BEFORE you knock. The label is a span, not a point.

Every keypress is itself a chassis impulse the accelerometer records. Avoid
pressing keys between knocks — set the label, knock your whole block, then move
on. All keystrokes are timestamped in the sidecar so artifacts stay identifiable.
""")

enterRawMode()

let keyThread = Thread {
    var byte: UInt8 = 0
    while cap.running {
        let n = read(STDIN_FILENO, &byte, 1)
        if n == 0 { return }                       // stdin closed — unattended run
        if n < 0 { if errno == EINTR { continue }; return }
        if n != 1 { continue }
        // Lowercase before dispatch: a shifted or caps-locked "L" is the same
        // instruction as "l", and silently ignoring it costs a whole session.
        // One was lost that way on 2026-08-30.
        let raw = Character(UnicodeScalar(byte))
        let ch = Character(raw.lowercased())
        cap.logKey(ch)
        switch ch {
        case "q":
            finish("finished by operator")
        case " ":
            let m = cap.addMark()
            let a = cap.accel, g = cap.gyro
            let name = pad(labelByID[cap.state().0]?.name ?? "?", 18)
            clearLine()
            print("  mark \(pad(String(Int(m)), 4))\(name)"
                  + String(format: "accel pk x=%.3f y=%.3f z=%.3f g   gyro pk x=%.1f y=%.1f z=%.1f °/s",
                           a.pkX, a.pkY, a.pkZ, g.pkX, g.pkY, g.pkZ))
            a.resetPeaks(); g.resetPeaks()
        case "1", "2", "3":
            let f = UInt8(String(ch))!
            cap.setForce(f)
            clearLine(); print("  force → \(forceNames[Int(f)])")
        case "?":
            clearLine(); print(usage())
        default:
            if let l = labelByKey[ch] {
                cap.setLabel(l.id)
                cap.accel.resetPeaks(); cap.gyro.resetPeaks()
                clearLine(); print("  label → \(l.name)")
            } else if !ch.isWhitespace && !ch.isNewline {
                // Never swallow a keystroke. An unrecognised key means the
                // operator thinks they labelled something and did not.
                clearLine()
                print("  ?? unrecognised key '\(raw)' — nothing changed. Press ? for the key list.")
            }
        }
    }
}
keyThread.start()

// Status line, 5 Hz, plus a periodic flush so a crash costs at most a second.
var lastReports: (UInt64, UInt64) = (0, 0)
var lastT = cap.now()
let timer = DispatchSource.makeTimerSource(queue: .global())
statusTimer = timer
timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
timer.setEventHandler {
    let t = cap.now()
    let dt = Double(t - lastT) / 1e9
    let ar = cap.accel.reports, gr = cap.gyro.reports
    let aHz = dt > 0 ? Double(ar - lastReports.0) / dt : 0
    let gHz = dt > 0 ? Double(gr - lastReports.1) / dt : 0
    lastReports = (ar, gr); lastT = t

    let (l, f, m) = cap.state()
    let el = Int(Double(t) / 1e9)
    let a = cap.accel
    let mb = Double(cap.writer?.bytesWritten ?? 0) / 1_048_576
    _ = gHz
    clearLine()
    out(String(format: " %02d:%02d · %@/%@ · m%d · %.0fHz d%llu/%llu · pk %.2f/%.2f/%.2f g · %.1f°C · %.1fMB",
               el / 60, el % 60,
               labelByID[l]?.name ?? "?", forceNames[Int(f)], Int(m),
               aHz, cap.accel.drops, cap.gyro.drops,
               a.pkX, a.pkY, a.pkZ, a.tempLast, mb))
    cap.writer?.flush()
}
timer.resume()

if let d = duration {
    DispatchQueue.global().asyncAfter(deadline: .now() + d) { finish("duration reached") }
}

CFRunLoopRun()
finish("run loop exited")
