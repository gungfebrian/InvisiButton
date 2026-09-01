// Replays a captured .ibcap session through the app's own KnockDetector.
//
// The Swift pipeline and the Python reference in tools/detect/ must agree. If
// they drift, every number in RESEARCH.md describes a detector that is not the
// one shipping.
import Foundation

let args = CommandLine.arguments.dropFirst()
guard !args.isEmpty else {
    print("usage: replay <session.ibcap> [...]")
    exit(64)
}

func loadSpans(_ path: String) -> [(UInt64, String)] {
    let side = (path as NSString).deletingPathExtension + ".json"
    guard let d = FileManager.default.contents(atPath: side),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let evs = o["label_events"] as? [[String: Any]] else { return [] }
    return evs.compactMap { e in
        guard let t = e["t_ns"] as? UInt64, e["label"] != nil,
              let n = e["name"] as? String else { return nil }
        return (t, n)
    }
}

for path in args {
    guard let data = FileManager.default.contents(atPath: path) else {
        print("cannot read \(path)"); continue
    }
    let spans = loadSpans(path)
    func labelAt(_ t: UInt64) -> String {
        var cur = "none"
        for (ts, n) in spans where ts <= t { cur = n }
        return cur
    }

    let det = KnockDetector()
    var byClass: [String: Int] = [:]
    det.onKnock = { k in byClass[labelAt(k.t), default: 0] += 1 }

    let n = data.count / 32
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        for i in 0..<n {
            let o = i * 32
            let t = raw.loadUnaligned(fromByteOffset: o, as: UInt64.self)
            let seq = raw.loadUnaligned(fromByteOffset: o + 8, as: UInt32.self)
            let chan = raw.loadUnaligned(fromByteOffset: o + 12, as: UInt8.self)
            let x = raw.loadUnaligned(fromByteOffset: o + 16, as: Int32.self)
            let y = raw.loadUnaligned(fromByteOffset: o + 20, as: Int32.self)
            let z = raw.loadUnaligned(fromByteOffset: o + 24, as: Int32.self)
            let tp = raw.loadUnaligned(fromByteOffset: o + 28, as: UInt32.self)
            let s = Sample(t: t, seq: seq, x: x, y: y, z: z, temp: tp)
            det.ingest(chan == 0 ? .accel : .gyro, s)
        }
    }
    let name = (path as NSString).lastPathComponent
    let knocks = byClass.filter { $0.key.hasPrefix("knock-") }.values.reduce(0, +)
    let other = byClass.filter { !$0.key.hasPrefix("knock-") && $0.key != "none" }
    print("\(name.prefix(46))  detected in knock spans: \(knocks)"
          + (other.isEmpty ? "   false positives: 0"
                           : "   false positives: \(other.values.reduce(0,+)) \(other)"))
}
