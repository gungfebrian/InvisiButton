// InvisiButton · Detection pipeline
//
// Port of tools/detect/detector.py. Every constant here has a measured reason
// recorded in DECISIONS.md D-022 and RESEARCH.md's seventeenth pass; changing one
// without re-running tools/detect/evaluate.py invalidates the numbers.
//
// D-006: the stream is never decimated. Product Principle 5: the 3-axis vector is
// never collapsed to a scalar magnitude — the trigger is the largest single-axis
// excursion and every feature keeps the axes apart.

import Foundation

// MARK: - Ring buffer

/// Fixed-capacity, no allocation after init, single-writer.
struct RingBuffer {
    private var storage: [Sample]
    private(set) var count = 0
    private var head = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        storage = Array(repeating: Sample(t: 0, seq: 0, x: 0, y: 0, z: 0, temp: 0),
                        count: capacity)
    }

    mutating func append(_ s: Sample) {
        storage[head] = s
        head = (head + 1) % capacity
        if count < capacity { count += 1 }
    }

    /// `i` counts back from the newest sample: 0 is newest.
    subscript(back i: Int) -> Sample {
        storage[((head - 1 - i) % capacity + capacity) % capacity]
    }
}

// MARK: - Causal noise tracker (T-007)

/// Running baseline and noise scale per axis.
///
/// The noise scale is NEVER frozen. It updates on a deviation clipped to
/// `devClip` sigma, so one impulse cannot inflate it while sustained activity —
/// typing — legitimately raises it. Freezing it during activity was a real bug:
/// it pinned sigma at the quiet-room floor, read every keystroke as ~50 sigma,
/// and produced 362 false positives in ten minutes.
///
/// Only the baseline freezes, so an impulse does not drag the gravity estimate.
struct NoiseTracker {
    static let baselineAlpha = 1.0 / 400      // ~0.5 s
    static let devAlpha = 1.0 / 800           // ~1 s
    static let devClip = 4.0
    static let holdSamples = 240              // 300 ms
    static let warmup = 1600                  // 2 s

    private var base = [0.0, 0.0, 0.0]
    private var dev = [1e-4, 1e-4, 1e-4]
    private var n = 0
    private var hold = 0

    struct Reading {
        var sigma: Double          // largest single-axis excursion, in sigma
        var dev: (Double, Double, Double)   // absolute deviation per axis
    }

    mutating func push(_ v: (Double, Double, Double)) -> Reading? {
        let a = [v.0, v.1, v.2]
        if n == 0 { base = a }
        n += 1

        var sigma = 0.0
        var d3 = [0.0, 0.0, 0.0]
        for i in 0..<3 {
            let d = abs(a[i] - base[i])
            d3[i] = d
            let s = d / max(dev[i], 1e-12)
            if s > sigma { sigma = s }
        }
        for i in 0..<3 {
            let d = abs(a[i] - base[i])
            dev[i] += Self.devAlpha * (min(d, Self.devClip * dev[i]) - dev[i])
        }
        if hold > 0 {
            hold -= 1
        } else {
            for i in 0..<3 { base[i] += Self.baselineAlpha * (a[i] - base[i]) }
        }
        guard n >= Self.warmup else { return nil }
        return Reading(sigma: sigma, dev: (d3[0], d3[1], d3[2]))
    }

    mutating func freeze() { hold = Self.holdSamples }
}

// MARK: - Detector (T-007 + T-009)

/// Measured operating points. The numbers are false ACTIONS per hour of ordinary
/// use — typing, trackpad, nudging the laptop, setting a cup down — across ten
/// minutes on two desks, after pattern assembly. False *knocks* per hour is the
/// wrong metric: what reaches the user is a fired action, and a double knock
/// needs two false knocks inside 600 ms, which is far rarer than one.
///
///     preset      knock recall   single/hr   double/hr
///     cautious          69%          12         0.0
///     balanced          96%          42         0.0     <- default
///     sensitive         98%         220        17.8
///
/// Balanced is the default because Product Principle 1 says a false trigger
/// costs more than a missed knock, and it is the loosest point at which a
/// double-knock binding fires nothing false at all.
enum Sensitivity: String, Codable, CaseIterable {
    case cautious, balanced, sensitive

    var label: String {
        switch self {
        case .cautious:  return "Cautious"
        case .balanced:  return "Balanced"
        case .sensitive: return "Sensitive"
        }
    }
    var minAccelG: Double {
        switch self {
        case .cautious: return 0.110
        case .balanced: return 0.075
        case .sensitive: return 0.045
        }
    }
    var minGyroPerG: Double {
        switch self {
        case .cautious: return 25
        case .balanced: return 20
        case .sensitive: return 16
        }
    }
    /// Measured, not estimated. See the table above.
    var summary: String {
        switch self {
        case .cautious:
            return "69% of knocks detected · about 12 false single-knock actions per hour · none on doubles"
        case .balanced:
            return "96% of knocks detected · about 42 false single-knock actions per hour · none on doubles"
        case .sensitive:
            return "98% of knocks detected · about 220 false single-knock actions per hour · about 18 on doubles"
        }
    }
}

struct DetectorConfig {
    /// Adaptive gate: finds the onset against the running noise floor.
    var triggerSigma = 8.0
    /// Absolute floor, on the windowed peak. Defensible as a fixed value only
    /// because typing measured 22 and 24 mg on two different desks — keystrokes
    /// couple through the chassis, not the desk.
    var minAccelG = 0.075
    /// Scale-free gate: gyro peak per unit accel peak, ROLL AND PITCH ONLY.
    /// Must be scale-free — knock amplitude spans 52 mg to 276 mg across desks
    /// while laptop nudges sit at 142 mg inside that range. Must exclude yaw —
    /// sliding a laptop is largely yaw, a knock produces almost none, and
    /// including gyro z cost 79 extra false positives on nudges alone.
    var minGyroPerG = 20.0
    /// 110 ms of lookahead, paid as latency.
    ///
    /// Must exceed DirectionModel.windowSamples (80 = 100 ms), or the roll
    /// waveform handed to the direction model runs past the end of what has been
    /// captured and gets zero-padded — the model then trains on a window whose
    /// last fifth is always zero.
    var confirmSamples = 88

    /// Re-arming is by hysteresis, not a fixed dead time.
    ///
    /// A fixed 250 ms refractory made a double knock physically undetectable.
    /// Measured ring duration above the trigger is p50 41 ms, p90 154 ms,
    /// p99 225 ms, so 250 ms was chosen to clear the p99 ring — while a natural
    /// double knock arrives in 100-250 ms. The two requirements are in direct
    /// conflict under a fixed dead time.
    ///
    /// Instead: after a knock, wait for the signal to actually return to
    /// baseline. A fast-decaying knock re-arms in 60 ms; a long ring still
    /// cannot retrigger, because it has not decayed. Shortest interval this
    /// resolves on the corpus is 124 ms, against 251 ms before.
    /// After a confirmed knock, the thresholds drop for the length of the
    /// learned rhythm window, so the SECOND knock of a pair is easier to catch.
    ///
    /// The second knock of a double measures about 10% weaker than the first and
    /// lands on a chassis that is still ringing, so its excursion above the
    /// elevated noise floor is much smaller — the third knock of a triple reads
    /// 7.0 sigma against a first knock's 17.2.
    ///
    /// This was rejected once, when it lifted triples 3/10 to 7/10 but dropped
    /// singles 10/10 to 6/10 by letting a single knock's own ring register as a
    /// second knock. That trade is now worth taking: single knocks are unbound
    /// because they are unsafe at any threshold, and the learned rhythm window
    /// means a stray second knock only matters if it also arrives at exactly the
    /// user's own double-knock interval.
    var inPatternScale = 0.6
    /// The band, after an accepted knock, across which thresholds are relaxed to
    /// catch the weaker second knock of a pair.
    ///
    /// It starts at zero, and that is deliberate — aiming it at the rhythm
    /// instead is worse, which was measured rather than assumed:
    ///
    ///     boost band            doubles   false doubles/hour
    ///     off                     5/10           5.9
    ///     uniform 0-538 ms       10/10           5.9
    ///     aimed  296-538 ms      10/10          11.9
    ///
    /// The reason is that the two defences already cover each other. A spurious
    /// second knock boosted at 100 ms is still thrown out by the rhythm gate and
    /// degrades to two singles. Aiming the boost at the rhythm band puts the
    /// extra sensitivity exactly where the rhythm gate ACCEPTS, so every
    /// spurious knock it finds becomes a false double instead of nothing.
    var expectLoMS = 0.0
    var expectHiMS = 0.0
    var minRefractorySamples = 48             // 60 ms, covers the confirm window
    var rearmSigma = 3.0
    var rearmSamples = 8                      // 10 ms below rearmSigma
}

struct KnockEvent {
    var t: UInt64
    var accelPeak: Double
    var gyroPeakXY: Double
    var gyroYawFraction: Double
    var riseMS: Double
    var durationMS: Double
    var sigma: Double
    /// Gyroscope roll (x) over the 100 ms after onset, unit-normalised.
    ///
    /// This is the direction feature. D-012: the discriminating structure is in
    /// the 30-100 ms ring, not the first 10-20 ms, and it is on the gyroscope
    /// roll axis — the accelerometer's horizontal axes sit at 4-5x the noise
    /// floor and separate nothing. Unit-normalised because absolute amplitude is
    /// desk identity, not direction (D-016).
    var rollWaveform: [Double] = []
}

/// Detection is deferred: the sigma gate fires on the leading edge, before the
/// peak exists, so the decision waits for `confirmSamples` of lookahead.
final class KnockDetector {
    var config = DetectorConfig()

    private var accel = RingBuffer(capacity: 1024)
    private var gyro = RingBuffer(capacity: 1024)
    private var accelReadings = RingBuffer2(capacity: 1024)
    private var gyroReadings = RingBuffer2(capacity: 1024)
    private var accelNoise = NoiseTracker()
    private var gyroNoise = NoiseTracker()

    private var pendingIndex: Int? = nil       // samples since the candidate
    private var pendingSigma = 0.0
    private var pendingTime: UInt64 = 0
    private var sinceLastAccept = Int.max
    private var quietSamples = 0
    private var armed = true
    /// Inside the predicted arrival band for the second knock of a pair.
    private var inPattern: Bool {
        guard config.expectHiMS > 0 else { return false }
        let ms = Double(sinceLastAccept) * 1000.0 / 800.0
        return ms >= config.expectLoMS && ms <= config.expectHiMS
    }

    var onKnock: ((KnockEvent) -> Void)?
    /// Why a candidate that crossed the adaptive trigger was thrown away.
    /// Without this the detector is a black box: a knock either fires or it
    /// does not, and there is no way to tell which gate rejected it.
    var onRejected: ((String) -> Void)?

    /// Parallel ring of noise readings, kept beside the sample ring.
    struct RingBuffer2 {
        private var storage: [(Double, Double, Double, Double)]
        private var head = 0
        private(set) var count = 0
        let capacity: Int
        init(capacity: Int) {
            self.capacity = capacity
            storage = Array(repeating: (0, 0, 0, 0), count: capacity)
        }
        mutating func append(sigma: Double, d: (Double, Double, Double)) {
            storage[head] = (sigma, d.0, d.1, d.2)
            head = (head + 1) % capacity
            if count < capacity { count += 1 }
        }
        subscript(back i: Int) -> (sigma: Double, dx: Double, dy: Double, dz: Double) {
            let v = storage[((head - 1 - i) % capacity + capacity) % capacity]
            return (v.0, v.1, v.2, v.3)
        }
    }

    func ingest(_ channel: SensorReader.Channel, _ s: Sample) {
        switch channel {
        case .gyro:
            gyro.append(s)
            let r = gyroNoise.push((s.gx, s.gy, s.gz))
            gyroReadings.append(sigma: r?.sigma ?? 0, d: r?.dev ?? (0, 0, 0))
            if let r, r.sigma >= NoiseTracker.devClip * 1.5 { gyroNoise.freeze() }
        case .accel:
            accel.append(s)
            let r = accelNoise.push((s.gx, s.gy, s.gz))
            accelReadings.append(sigma: r?.sigma ?? 0, d: r?.dev ?? (0, 0, 0))
            guard let r else { return }
            if r.sigma >= 6.0 { accelNoise.freeze() }

            if sinceLastAccept < Int.max { sinceLastAccept += 1 }

            if r.sigma < config.rearmSigma {
                quietSamples += 1
                if quietSamples >= config.rearmSamples
                    && sinceLastAccept > config.minRefractorySamples {
                    armed = true
                }
            } else {
                quietSamples = 0
            }

            if var age = pendingIndex {
                age += 1
                pendingIndex = age
                if age >= config.confirmSamples { evaluatePending(age: age) }
                return
            }
            let trigger = inPattern ? config.triggerSigma * config.inPatternScale
                                    : config.triggerSigma
            if r.sigma >= trigger && armed
                && sinceLastAccept > config.minRefractorySamples {
                pendingIndex = 0
                pendingSigma = r.sigma
                pendingTime = s.t
            }
        }
    }

    private func evaluatePending(age: Int) {
        defer { pendingIndex = nil }
        guard accelReadings.count > age + 4, gyroReadings.count > age + 4 else { return }

        var accelPeak = 0.0
        var riseAt = 0
        for back in 0...(age + 4) {
            let r = accelReadings[back: back]
            let m = max(r.dx, max(r.dy, r.dz))
            if m > accelPeak { accelPeak = m; riseAt = age - back }
        }
        let floor = inPattern ? config.minAccelG * config.inPatternScale : config.minAccelG
        guard accelPeak >= floor else {
            onRejected?(String(format: "too soft: %.0f mg, needs %.0f mg",
                               accelPeak * 1000, floor * 1000))
            return
        }

        var gyroXY = 0.0, gyroZ = 0.0
        for back in 0...(age + 4) {
            let r = gyroReadings[back: back]
            gyroXY = max(gyroXY, max(r.dx, r.dy))
            gyroZ = max(gyroZ, r.dz)
        }
        let ratio = gyroXY / max(accelPeak, 1e-12)
        guard ratio >= config.minGyroPerG else {
            onRejected?(String(format: "not enough rotation: %.0f per g, needs %.0f "
                               + "(looks like the laptop moving, not a knock)",
                               ratio, config.minGyroPerG))
            return
        }

        var above = 0
        for back in 0...(age + 4) {
            let r = accelReadings[back: back]
            if max(r.dx, max(r.dy, r.dz)) >= accelPeak * 0.5 { above += 1 }
        }

        // Roll waveform for the direction model, oldest-to-newest from onset.
        //
        // The gyro window is aligned by TIMESTAMP, not by counting back the same
        // number of accelerometer samples. The two channels are separate HID
        // devices with independent ring buffers, so "age samples back" in the
        // gyro ring is not the same instant as in the accel ring — the phase
        // offset between them is arbitrary and differs from knock to knock.
        // Counting samples misaligns every window by a random few samples, which
        // is fatal to a template built by averaging them: it showed up as
        // within-class similarity of 0.48 where clean data gives 0.8, and a
        // direction model stuck at 67%. D-012 says to work from the gyroscope's
        // own timeline for exactly this reason.
        let onsetTime = accel[back: age].t
        var gyroBack = 0
        var bestDelta = UInt64.max
        for b in 0..<min(gyro.count, age + DirectionModel.windowSamples + 16) {
            let t = gyro[back: b].t
            let delta = t > onsetTime ? t - onsetTime : onsetTime - t
            if delta < bestDelta { bestDelta = delta; gyroBack = b }
        }
        var roll: [Double] = []
        roll.reserveCapacity(DirectionModel.windowSamples)
        var truncated = false
        for k in 0..<DirectionModel.windowSamples {
            let back = gyroBack - k
            if back < 0 || back >= gyro.count { truncated = true; break }
            roll.append(gyro[back: back].gx)
        }
        // A short window is dropped rather than zero-padded: padding silently
        // teaches the direction model that every knock ends in silence.
        if truncated { roll = [] }
        let mean = roll.reduce(0, +) / Double(max(roll.count, 1))
        var norm = 0.0
        for i in 0..<roll.count { roll[i] -= mean; norm += roll[i] * roll[i] }
        norm = norm.squareRoot()
        if norm > 1e-12 { for i in 0..<roll.count { roll[i] /= norm } }

        sinceLastAccept = 0
        armed = false
        quietSamples = 0
        onKnock?(KnockEvent(
            t: pendingTime,
            accelPeak: accelPeak,
            gyroPeakXY: gyroXY,
            gyroYawFraction: gyroZ / max(gyroXY + gyroZ, 1e-12),
            riseMS: Double(max(riseAt, 0)) * 1000.0 / 800.0,
            durationMS: Double(above) * 1000.0 / 800.0,
            sigma: pendingSigma,
            rollWaveform: roll))
    }
}

// MARK: - Pattern assembler (T-011)

/// Single / double / triple, with user-adjustable windows.
///
/// Generous by default, and adjustable, because the trigger is a motor-accessibility
/// affordance and must not require fast multi-knock timing (PRODUCT.md,
/// Accessibility & Inclusion).
final class PatternAssembler {
    /// Maximum gap between knocks of one pattern. Deliberately wide.
    var maxGapMS: Double = 600
    /// How long to wait after the last knock before emitting.
    ///
    /// This is a real product tension, not a tuning constant. A single knock
    /// cannot be distinguished from the first knock of a double until this
    /// window expires, so binding both a single and a multi gesture costs the
    /// single one `settleMS` of latency. The Phase 1 gate asks for a median
    /// onset-to-action of 150 ms, which is unreachable while both are bound —
    /// the gate and the trigger vocabulary are in conflict and one of them has
    /// to give. Nothing in the corpus measures real double-knock timing yet, so
    /// this value is a placeholder, not a measurement.
    /// Measured on desk3, 10 singles / 10 doubles / 10 triples with the intended
    /// count recorded per span: gaps *within* a pattern run 196-445 ms, the
    /// smallest gap *between* patterns is 1002 ms. A settle window shorter than
    /// the largest within-pattern gap fires before the next knock arrives and
    /// emits a double as two singles — at 350 ms that happened to **10 of 10**
    /// doubles. At 450 ms and above, 10 of 10 are correct.
    ///
    /// 600 ms sits between the 445 ms upper bound of within-pattern gaps and the
    /// 1002 ms lower bound of between-pattern gaps, with margin on both sides.
    var settleMS: Double = 600
    var maxCount = 3

    /// Learned interval between the knocks of this user's double knock. When
    /// set, a pair whose gap falls outside the learned window is not a double —
    /// it is two unrelated knocks, and is emitted as such.
    var rhythm: KnockRhythm?

    private var pending: [KnockEvent] = []
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.invisibutton.pattern")

    /// Emitted with the knocks that formed it, so a later stage can add direction.
    var onPattern: (([KnockEvent]) -> Void)?
    /// Reports a pair rejected for arriving at the wrong rhythm.
    var onRhythmReject: ((String, Double) -> Void)?

    func add(_ k: KnockEvent) {
        queue.async { [self] in
            if let last = pending.last {
                let gap = Double(k.t &- last.t) / 1e6
                // Outside the learned rhythm, this knock does not belong to the
                // pattern in progress: close that one and start a new one.
                let belongs = rhythm.map { $0.accepts(gapMS: gap) } ?? (gap <= maxGapMS)
                if !belongs {
                    if let r = rhythm, gap <= maxGapMS {
                        onRhythmReject?(String(
                            format: "gap %.0f ms is outside your rhythm %.0f–%.0f ms",
                            gap, r.lowMS, r.highMS), gap)
                    }
                    flushLocked()
                }
            }
            pending.append(k)
            if pending.count >= maxCount {
                flushLocked()
                return
            }
            timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + (rhythm?.settleMS ?? settleMS) / 1000.0)
            t.setEventHandler { [weak self] in self?.flushLocked() }
            t.resume()
            timer = t
        }
    }

    private func flushLocked() {
        timer?.cancel()
        timer = nil
        guard !pending.isEmpty else { return }
        let batch = pending
        pending = []
        onPattern?(batch)
    }
}
