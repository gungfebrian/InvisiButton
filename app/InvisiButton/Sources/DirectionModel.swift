// InvisiButton · Direction, per desk
//
// WHAT THIS IS ALLOWED TO CLAIM
//
// D-020: left and right knocks separate *within* a desk. Measured on two desks
// with leave-one-block-out cross-validation against a block-label permutation
// null: p = 0.016 (desk3, 48 events) and p = 0.029 (desk4, 52 events), Fisher
// combined p ~ 0.004.
//
// D-016 / D-018: transfer BETWEEN desks is not established. One of four
// cross-desk pairs reached p = 0.029 against a Bonferroni threshold of 0.0125,
// and that pair's source failed its own within-session control. There is no
// universal direction model and this file does not pretend to build one.
//
// Therefore direction is per-desk calibrated: the user trains it where they sit,
// it works there, and it is honest about not transferring. Moving the laptop on
// the same desk was measured to preserve a profile (42/50, and 34/36 through a
// 30 degree rotation) — but under the pre-D-016 analysis, so that has NOT been
// re-measured under the block design and must not be relied on.
//
// The feature is the gyroscope roll waveform over 100 ms after onset,
// unit-normalised, projected onto the difference of the two class means. That is
// exactly the analysis in tools/analyze/transfer.py, which is the analysis of
// record.

import Foundation

struct DirectionModel: Codable {
    static let windowSamples = 80        // 100 ms at 800 Hz

    /// Bumped ONLY when a change makes existing models invalid — a different
    /// window length, a different feature, or a fix to how the window is
    /// located. A model from an older version is reported to the user and left
    /// on disk, never silently used and never silently deleted: calibration is
    /// two minutes of the user's time and rebuilding the app is not a reason to
    /// throw it away.
    ///
    /// 1 — initial
    /// 2 — D-027: gyro window aligned by timestamp rather than by counting
    ///     accelerometer samples. Models trained before this are misaligned.
    static let currentVersion = 2
    var version: Int = 1

    var isCompatible: Bool { version == Self.currentVersion }

    /// Unit-normalised (mean_left - mean_right).
    var template: [Double]
    /// Midpoint between the class-mean projections.
    var threshold: Double
    /// How separable the calibration set was, leave-one-out. Shown to the user:
    /// a model that cannot separate its own training data must not be trusted.
    var trainingAccuracy: Double
    var leftCount: Int
    var rightCount: Int
    var deskLabel: String
    var createdAt: Date

    /// Detection threshold derived from the knocks this user actually makes.
    ///
    /// A fixed threshold cannot work. Knock amplitude in this corpus spans 51 mg
    /// to 276 mg depending on desk and on how hard the person knocks, and the
    /// negative classes sit inside that range — desk3's laptop-nudge median is
    /// 47 mg. A 75 mg floor detected 0 of 10 real doubles from a soft knocker
    /// while a 35 mg floor detected 10 of 10 and fired 42 false actions an hour.
    /// The only defensible threshold is one measured from the person using it.
    /// The two class means the template was built from, with their counts.
    ///
    /// The template alone is a dead end: (mean_left - mean_right) cannot be
    /// combined with another session's template in any principled way. Keeping
    /// the means makes merging exact — a weighted average per class — so a
    /// calibration can be topped up with a dozen more knocks instead of being
    /// redone from nothing.
    var leftMean: [Double]?
    var rightMean: [Double]?

    var suggestedMinAccelG: Double = 0.075
    /// Weakest calibration knock, in g. Shown to the user, because if this is
    /// low no threshold will save them.
    var knockP10G: Double = 0

    func classify(_ roll: [Double]) -> Area? {
        guard roll.count == template.count else { return nil }
        var p = 0.0
        for i in 0..<roll.count { p += roll[i] * template[i] }
        return p > threshold ? .left : .right
    }

    /// Template and threshold only. NO cross-validation — this is the primitive
    /// the leave-one-out loop calls, and it must not recurse.
    ///
    /// An earlier version had `train` call itself once per fold, and each of
    /// those calls ran its own leave-one-out loop. With 24 calibration knocks
    /// that is 24^n calls: calibration appeared to hang forever on "Finish".
    private static func fit(left: [[Double]], right: [[Double]]) -> ([Double], Double)? {
        let n = windowSamples
        guard !left.isEmpty, !right.isEmpty else { return nil }
        func mean(_ xs: [[Double]]) -> [Double] {
            var m = [Double](repeating: 0, count: n)
            var used = 0
            for x in xs where x.count == n {
                for i in 0..<n { m[i] += x[i] }
                used += 1
            }
            let c = Double(max(used, 1))
            for i in 0..<n { m[i] /= c }
            return m
        }
        let ml = mean(left), mr = mean(right)
        var t = (0..<n).map { ml[$0] - mr[$0] }
        var norm = 0.0
        for v in t { norm += v * v }
        norm = norm.squareRoot()
        guard norm > 1e-12 else { return nil }
        for i in 0..<n { t[i] /= norm }

        func proj(_ x: [Double]) -> Double {
            var p = 0.0
            for i in 0..<min(n, x.count) { p += x[i] * t[i] }
            return p
        }
        let pl = left.map(proj), pr = right.map(proj)
        let thr = (pl.reduce(0, +) / Double(pl.count)
                   + pr.reduce(0, +) / Double(pr.count)) / 2
        return (t, thr)
    }

    private static func classify(_ x: [Double], _ t: [Double], _ thr: Double) -> Area {
        var p = 0.0
        for i in 0..<min(x.count, t.count) { p += x[i] * t[i] }
        return p > thr ? .left : .right
    }

    /// Calibration knocks grouped by the block they were collected in.
    ///
    /// The grouping is not bookkeeping — it is what makes the reported accuracy
    /// honest. Knocks inside one block share a hand position and a moment in
    /// time, so leaving out a single knock still leaves its block-siblings in
    /// training and reports a number that is too good. On this project's own
    /// corpus that difference was the whole story: sample-level validation said
    /// p = 0.003 for a result that block-level validation put at p = 0.200
    /// (D-018). Whole blocks are held out here for the same reason.
    /// Below this, a knock is inside the range of ordinary desk noise — setting
    /// a cup down, nudging the laptop — and no threshold separates them.
    static let softKnockWarningG = 0.090

    /// Merge more knocks into an existing model, weighting by sample count.
    ///
    /// Returns the merged model and the accuracy the OLD model achieved on the
    /// new knocks — which is a genuinely held-out number, since those knocks
    /// were not used to build it.
    func merged(withLeft newLeft: [[Double]], right newRight: [[Double]],
                peaks: [Double]) -> (model: DirectionModel, heldOut: Double)? {
        guard let ml = leftMean, let mr = rightMean,
              !newLeft.isEmpty, !newRight.isEmpty else { return nil }

        var correct = 0
        for w in newLeft where classify(w) == .left { correct += 1 }
        for w in newRight where classify(w) == .right { correct += 1 }
        let heldOut = Double(correct) / Double(newLeft.count + newRight.count)

        let n = Self.windowSamples
        func avg(_ xs: [[Double]]) -> [Double] {
            var m = [Double](repeating: 0, count: n)
            for x in xs where x.count == n { for i in 0..<n { m[i] += x[i] } }
            for i in 0..<n { m[i] /= Double(max(xs.count, 1)) }
            return m
        }
        func blend(_ a: [Double], _ na: Int, _ b: [Double], _ nb: Int) -> [Double] {
            let wa = Double(na), wb = Double(nb)
            return (0..<n).map { (wa * a[$0] + wb * b[$0]) / (wa + wb) }
        }
        let cl = blend(ml, leftCount, avg(newLeft), newLeft.count)
        let cr = blend(mr, rightCount, avg(newRight), newRight.count)
        var t = (0..<n).map { cl[$0] - cr[$0] }
        var norm = 0.0
        for v in t { norm += v * v }
        norm = norm.squareRoot()
        guard norm > 1e-12 else { return nil }
        for i in 0..<n { t[i] /= norm }
        func proj(_ x: [Double]) -> Double {
            var p = 0.0
            for i in 0..<n { p += x[i] * t[i] }
            return p
        }
        let thr = (proj(cl) + proj(cr)) / 2

        let allPeaks = peaks.sorted()
        let weakest = allPeaks.first ?? 0
        let newFloor = weakest > 0 ? min(suggestedMinAccelG, max(0.030, weakest * 0.65))
                                   : suggestedMinAccelG

        var m = self
        m.version = Self.currentVersion
        m.template = t
        m.threshold = thr
        m.leftMean = cl
        m.rightMean = cr
        m.leftCount = leftCount + newLeft.count
        m.rightCount = rightCount + newRight.count
        m.trainingAccuracy = heldOut
        m.suggestedMinAccelG = newFloor
        m.createdAt = Date()
        return (m, heldOut)
    }

    static func train(leftBlocks: [[[Double]]], rightBlocks: [[[Double]]],
                      peaks: [Double], desk: String) -> DirectionModel? {
        let left = leftBlocks.flatMap { $0 }
        let right = rightBlocks.flatMap { $0 }
        guard left.count >= 4, right.count >= 4 else { return nil }
        guard let (t, thr) = fit(left: left, right: right) else { return nil }

        var correct = 0, total = 0
        for k in leftBlocks.indices {
            let sub = leftBlocks.enumerated().filter { $0.offset != k }
                                .flatMap { $0.element }
            guard !sub.isEmpty, let (ft, fthr) = fit(left: sub, right: right) else { continue }
            for w in leftBlocks[k] {
                total += 1
                if classify(w, ft, fthr) == .left { correct += 1 }
            }
        }
        for k in rightBlocks.indices {
            let sub = rightBlocks.enumerated().filter { $0.offset != k }
                                 .flatMap { $0.element }
            guard !sub.isEmpty, let (ft, fthr) = fit(left: left, right: sub) else { continue }
            for w in rightBlocks[k] {
                total += 1
                if classify(w, ft, fthr) == .right { correct += 1 }
            }
        }
        let acc = total > 0 ? Double(correct) / Double(total) : 0

        // Threshold from the WEAKEST calibration knock, not the tenth
        // percentile, and at 65% of it rather than 75%.
        //
        // The first version took p10 x 0.75. Calibrating with deliberately firm
        // knocks (114 mg) set the threshold to 85 mg, and ordinary knocks in
        // daily use — around 55 mg for this person — were then rejected outright.
        // Nothing fired at all. Calibration force is always higher than daily
        // force, because a calibration screen makes people concentrate, so the
        // threshold has to sit well under the softest thing seen during it.
        let sorted = peaks.sorted()
        let weakest = sorted.first ?? 0
        let suggested = weakest > 0 ? max(0.030, weakest * 0.65) : 0.075

        let n2 = windowSamples
        func avg(_ xs: [[Double]]) -> [Double] {
            var m = [Double](repeating: 0, count: n2)
            for x in xs where x.count == n2 { for i in 0..<n2 { m[i] += x[i] } }
            for i in 0..<n2 { m[i] /= Double(max(xs.count, 1)) }
            return m
        }
        return DirectionModel(version: Self.currentVersion,
                              template: t, threshold: thr, trainingAccuracy: acc,
                              leftCount: left.count, rightCount: right.count,
                              deskLabel: desk, createdAt: Date(),
                              leftMean: avg(left), rightMean: avg(right),
                              suggestedMinAccelG: suggested, knockP10G: weakest)
    }
}

@MainActor
final class DirectionStore: ObservableObject {
    @Published var model: DirectionModel?
    /// A model was found on disk but was built by an incompatible version.
    @Published var staleVersion: Int?

    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("InvisiButton", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("direction.json")
    }

    func load() {
        guard let d = try? Data(contentsOf: Self.url),
              let m = try? JSONDecoder().decode(DirectionModel.self, from: d) else { return }
        if m.isCompatible {
            model = m
            staleVersion = nil
        } else {
            // Kept on disk, not used, and reported.
            model = nil
            staleVersion = m.version
        }
    }

    func save() {
        guard let m = model, let d = try? JSONEncoder().encode(m) else {
            try? FileManager.default.removeItem(at: Self.url)
            return
        }
        try? d.write(to: Self.url, options: .atomic)
    }

    func clear() {
        model = nil
        save()
    }
}


// MARK: - Knock rhythm

/// The interval between the knocks of one person's double knock.
///
/// This is a discriminator, not a convenience. Measured: one person's double
/// knocks landed at 374-445 ms, mean 408, sd 27 — tight. False knocks during
/// ordinary use arrive at scattered intervals: 93, 239, 266, 294, 300, 313, 471,
/// 559, 669 ms. Accepting a pair only when its gap falls inside the learned
/// window kept 10 of 10 real doubles and rejected every false one, taking false
/// double-knock actions from 47.6 per hour to zero.
///
/// It has to be learned rather than fixed: the same person's intra-pair gap
/// measured 84-112 ms in one session and 374-445 ms in another. A fixed window
/// is wrong for everybody, including for the same body on a different day.
struct KnockRhythm: Codable {
    var meanGapMS: Double
    var sdGapMS: Double
    var samples: Int

    /// Explicit window bounds, once the window has been widened from evidence.
    ///
    /// Widening used to merge refused gaps into the mean and standard deviation,
    /// which SHIFTS the window rather than growing it. Two refused gaps at 284
    /// and 292 ms pulled a 361 ms centre down to 271 and moved the window to
    /// 163-380, away from the user's real 374-445 ms knocks. The result was the
    /// worst of every option measured — 3 of 10 doubles caught at 17.8 false per
    /// hour, worse on both counts than having no rhythm gate at all.
    ///
    /// A window may only ever grow to admit new evidence. It never re-centres.
    var minMS: Double?
    var maxMS: Double?

    /// Beyond this the gate stops being worth having: at 250-550 ms it caught
    /// every double at 23.8 false per hour, against 5.9 for a window fitted to
    /// the user's actual spread.
    static let maxWidthMS: Double = 260

    /// Two standard deviations, with a floor so a very consistent knocker is not
    /// held to an impossible tolerance, and a ceiling so a sloppy one still gets
    /// some rejection.
    var toleranceMS: Double { min(max(2 * sdGapMS, 60), 250) }
    var lowMS: Double { max(minMS ?? (meanGapMS - toleranceMS), 40) }
    var highMS: Double { maxMS ?? (meanGapMS + toleranceMS) }
    var widthMS: Double { highMS - lowMS }

    func accepts(gapMS: Double) -> Bool { gapMS >= lowMS && gapMS <= highMS }

    /// How long to wait after a knock before deciding the pattern is over.
    /// Derived, so a fast knocker gets a fast response instead of a fixed 600 ms.
    var settleMS: Double { min(max(highMS + 120, 250), 900) }

    /// Merge new gaps into an existing rhythm without needing the original ones.
    ///
    /// A rhythm learned before raw gaps were stored has only its summary — mean,
    /// sd and sample count — but that is enough: pooled mean and variance
    /// combine two samples exactly. Requiring the raw gaps meant the widen
    /// button silently did nothing for anyone calibrated before they were kept.
    /// Grow the window to admit gaps it refused, without moving its centre.
    ///
    /// Each refused gap extends the near edge toward it, with a small margin.
    /// The opposite edge never moves, so evidence can only ever make the gate
    /// more permissive in the direction the evidence points.
    func widened(toAdmit gaps: [Double]) -> KnockRhythm? {
        let g = gaps.filter { $0 > 40 && $0 < 1200 }
        guard !g.isEmpty else { return nil }
        var lo = lowMS, hi = highMS
        for x in g {
            if x < lo { lo = max(x - 15, 40) }
            if x > hi { hi = x + 15 }
        }
        guard lo < hi else { return nil }
        // Growing past the useful width means the gate is no longer separating
        // anything; keep the side nearest the existing centre.
        if hi - lo > Self.maxWidthMS {
            let centre = (lowMS + highMS) / 2
            if centre - lo > hi - centre { lo = hi - Self.maxWidthMS }
            else { hi = lo + Self.maxWidthMS }
        }
        var r = self
        r.minMS = lo
        r.maxMS = hi
        r.samples = samples + g.count
        return r
    }

    func extended(with newGaps: [Double]) -> KnockRhythm? {
        let g = newGaps.filter { $0 > 40 && $0 < 1200 }
        guard !g.isEmpty else { return nil }
        let n1 = Double(max(samples, 1))
        let n2 = Double(g.count)
        let mu2 = g.reduce(0, +) / n2
        let mu = (n1 * meanGapMS + n2 * mu2) / (n1 + n2)
        let ss2 = g.reduce(0) { $0 + ($1 - mu2) * ($1 - mu2) }
        let ss1 = sdGapMS * sdGapMS * max(n1 - 1, 0)
        let between = n1 * (meanGapMS - mu) * (meanGapMS - mu)
                    + n2 * (mu2 - mu) * (mu2 - mu)
        let variance = (ss1 + ss2 + between) / max(n1 + n2 - 1, 1)
        return KnockRhythm(meanGapMS: mu, sdGapMS: variance.squareRoot(),
                           samples: samples + g.count)
    }

    static func learn(gapsMS: [Double]) -> KnockRhythm? {
        let raw = gapsMS.filter { $0 > 40 && $0 < 1200 }
        guard raw.count >= 3 else { return nil }

        // Reject outliers before fitting. When the second knock of a pair is
        // missed, the gap recorded is the pause BETWEEN pairs — measured at 686,
        // 877 and 715 ms among gaps that were otherwise 295-325 ms. Fitting all
        // of them gave mean 459, sd 231, and a window of -4 to 921 ms, which
        // accepts everything and defeats the whole point of learning a rhythm.
        // Median absolute deviation, which those three cannot drag.
        let sorted = raw.sorted()
        let med = sorted[sorted.count / 2]
        let devs = sorted.map { abs($0 - med) }.sorted()
        let mad = max(devs[devs.count / 2], 1)
        let g = raw.filter { abs($0 - med) <= max(3 * 1.4826 * mad, 60) }
        guard g.count >= 3 else { return nil }

        let mu = g.reduce(0, +) / Double(g.count)
        let sd = (g.map { ($0 - mu) * ($0 - mu) }.reduce(0, +)
                  / Double(max(g.count - 1, 1))).squareRoot()
        return KnockRhythm(meanGapMS: mu, sdGapMS: sd, samples: g.count)
    }
}

@MainActor
final class RhythmStore: ObservableObject {
    @Published var rhythm: KnockRhythm?

    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("InvisiButton", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("rhythm.json")
    }

    func load() {
        guard let d = try? Data(contentsOf: Self.url) else { return }
        rhythm = try? JSONDecoder().decode(KnockRhythm.self, from: d)
    }
    func save() {
        guard let r = rhythm, let d = try? JSONEncoder().encode(r) else {
            try? FileManager.default.removeItem(at: Self.url); return
        }
        try? d.write(to: Self.url, options: .atomic)
    }
    func clear() { rhythm = nil; save() }
}
