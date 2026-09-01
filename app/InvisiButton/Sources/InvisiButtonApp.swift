// InvisiButton · T-017 · Menu bar application
//
// PHASE 1 DISCIPLINE: this UI is functional and deliberately unstyled. Visual
// design is Phase 2 and does not start until the Phase 1 exit gate is measured
// (PLAN.md). Do not make this pretty. D-005: DESIGN.md is written at Phase 2
// finish, from what shipped.
//
// LSUIElement, so there is no Dock icon and no main window. There is no
// permission prompt to negotiate at first run (D-008, D-021) — the only action
// type that needs one is a media key, and only if the user binds it.

import AppKit
import os
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var support: HardwareSupport = .noSPUDriver
    @Published var running = false
    @Published var lastKnock: KnockEvent?
    @Published var lastPattern: String = "—"
    @Published var knockCount = 0
    /// Gap between the last two knocks. The single/double question is entirely
    /// about this number against the assembler's window, so show it.
    @Published var lastIntervalMS: Double? = nil
    /// Most recent reason a candidate knock was thrown away, for the menu.
    @Published var lastRejection = ""
    @Published var rejectCount = 0
    private var previousKnockTime: UInt64 = 0
    @Published var log: [String] = []

    /// Live signal strength, 0…1, sampled at 10 Hz for display.
    ///
    /// T-024 requires a non-visual equivalent from the start, so the numeric
    /// values below are the source of truth and the bar is drawn from them —
    /// not the other way round. Never signal detection state by colour alone.
    @Published var levelAccel = 0.0
    @Published var levelGyro = 0.0
    @Published var dieTemperature = 0.0

    let bindings = Bindings()
    let direction = DirectionStore()
    let rhythmStore = RhythmStore()
    let profiles = ProfileStore()
    @Published var verifyResult: VerifyResult?

    @Published var sensitivity: Sensitivity = .balanced {
        didSet { applySensitivity() }
    }

    private func applySensitivity() {
        // A calibrated threshold beats a preset: it is measured from this user.
        detector.config.minAccelG = direction.model?.suggestedMinAccelG
                                    ?? sensitivity.minAccelG
        // Double knocks are the gesture that works, so the detector looks for
        // one: after a confirmed knock it relaxes its thresholds ONLY across the
        // band where this user's second knock is due, slightly widened. Outside
        // that band — including the decay immediately after the first knock —
        // nothing is relaxed.
        if let r = rhythmStore.rhythm {
            // From zero, not from the rhythm band — see DetectorConfig.expectLoMS.
            detector.config.expectLoMS = 0
            detector.config.expectHiMS = r.highMS * 1.15
        } else {
            detector.config.expectLoMS = 0
            detector.config.expectHiMS = 0
        }
        detector.config.minGyroPerG = sensitivity.minGyroPerG
        UserDefaults.standard.set(sensitivity.rawValue, forKey: "sensitivity")
        note("sensitivity: \(sensitivity.label)")
    }

    // ── Calibration (D-004: the interaction contract is a Phase 1 deliverable) ──
    /// Blocks alternate left/right rather than one long block of each. Blocked
    /// collection inflates any accuracy you then report from it (D-017), and the
    /// number this flow shows the user has to be one they can trust.
    static let calibrationPlan: [Area] = [.left, .right, .left, .right, .left, .right]
    /// Topping up is short on purpose — twelve knocks, not thirty-six. A model
    /// that can be nudged in half a minute actually gets used.
    static let topUpPlan: [Area] = [.left, .right]
    @Published var usingTopUpPlan = false
    var activePlan: [Area] { usingTopUpPlan ? Self.topUpPlan : Self.calibrationPlan }
    /// Six per block, thirty-six in total across the six alternating blocks.
    ///
    /// The first attempt used three per block — eighteen knocks — and produced a
    /// held-out direction accuracy of 61%, barely above chance. The template is
    /// a mean over 80 samples per class; eighteen examples do not estimate it.
    static let knocksPerBlock = 6
    static let minimumPerBlock = 6

    @Published var calibrating = false {
        didSet {
            let v = calibrating
            calibratingFlag.withLock { $0 = v }
        }
    }
    private let calibratingFlag = OSAllocatedUnfairLock(initialState: false)
    private let verifyingFlag = OSAllocatedUnfairLock(initialState: false)
    @Published var calBlock = 0
    @Published var calCollected = 0
    @Published var calMessage = ""
    /// Direction and rhythm are calibrated independently.
    ///
    /// They were one chained flow, which meant a rhythm phase that would not
    /// register discarded the thirty-six direction knocks that preceded it. They
    /// also fail for different reasons and are worth redoing separately.
    @Published var calPhase: CalPhase = .direction
    enum CalPhase { case direction, rhythm }
    private var rhythmGaps: [Double] = []
    private var lastRhythmKnock: UInt64 = 0
    @Published var rhythmPairs = 0
    /// Every knock heard during the rhythm phase, paired or not.
    ///
    /// Distinguishes "no knocks are being detected" from "knocks are detected
    /// but never pair up" — two very different failures that look identical
    /// when only the pair count is shown.
    @Published var rhythmKnocksHeard = 0
    @Published var rhythmLastGapMS: Double? = nil
    /// Knocks heard since the last "Record this pair" press.
    @Published var pairKnocks = 0
    private var pairTimes: [UInt64] = []
    /// Peak amplitude of each knock in the current block, so the operator can
    /// see whether they are knocking consistently instead of guessing.
    @Published var blockPeaksMG: [Int] = []
    static let rhythmPairsNeeded = 8
    private var calLeftBlocks: [[[Double]]] = []
    private var calRightBlocks: [[[Double]]] = []
    private var calCurrentBlock: [[Double]] = []
    private var calPeaks: [Double] = []
    private var pendingCalibration: CalibrationData?

    var calibrationTarget: Area? {
        calibrating && calPhase == .direction && calBlock < activePlan.count
            ? activePlan[calBlock] : nil
    }

    /// True when the current run adds to an existing calibration rather than
    /// replacing it.
    @Published var improving = false

    func beginDirectionCalibration() {
        improving = false
        usingTopUpPlan = false
        calPhase = .direction
        beginCalibration()
    }

    var canImproveDirection: Bool {
        direction.model?.leftMean != nil || profiles.active?.calibration != nil
    }

    /// Add more knocks to the calibration already stored for this profile.
    ///
    /// A direction model gets better with data — the first attempt here used 18
    /// knocks and scored 61%, thirty-six scored 75% — and there is no reason to
    /// discard good knocks to collect more. New blocks are appended to the
    /// stored ones and the model is retrained on everything.
    func improveDirectionCalibration() {
        improving = true
        usingTopUpPlan = canImproveDirection
        calPhase = .direction
        beginCalibration()
    }

    /// Gaps of pairs the rhythm window turned away during ordinary use.
    ///
    /// These are the measurement that matters for widening the window. A pair
    /// rejected at 445 ms when the window ends at 421 is the user knocking
    /// normally and being refused; a pair rejected at 90 ms is not.
    @Published var rejectedGapsMS: [Double] = []

    /// Add the rejected gaps to the learned rhythm and refit.
    ///
    /// Calibration is done deliberately, one pair at a time, with a button
    /// press between each — which produces a tighter spread than real use. On
    /// one calibration sd was 14 ms, giving a window of only 120 ms wide, and
    /// ordinary double knocks fell outside it. Feeding the refused gaps back in
    /// widens the window by exactly as much as the user's real variation, rather
    /// than by a number picked in advance.
    func widenRhythmFromRejections() {
        guard !rejectedGapsMS.isEmpty else {
            calMessage = "No refused pairs to learn from yet."
            return
        }
        let added = rejectedGapsMS

        // Grow the window to cover the refused gaps. Never re-fit from scratch:
        // refitting shifts the centre toward whatever was refused, which moved
        // one window off the user's real knocks entirely (D-032).
        let merged = rhythmStore.rhythm?.widened(toAdmit: added)

        guard let r = merged else {
            calMessage = "Could not combine those pairs with your rhythm."
            return
        }
        let before = rhythmStore.rhythm
        rhythmStore.rhythm = r
        rhythmStore.save()
        assembler.rhythm = r
        profiles.update { p in
            p.rhythm = r
            p.rhythmGapsMS = (p.rhythmGapsMS ?? []) + added
        }
        applySensitivity()
        rejectedGapsMS = []
        let old = before.map { String(format: "%.0f–%.0f", $0.lowMS, $0.highMS) } ?? "—"
        calMessage = String(format: "Rhythm widened: window %@ ms → %.0f–%.0f ms "
                                  + "(%.0f ± %.0f, %d pairs).",
                            old, r.lowMS, r.highMS, r.meanGapMS, r.toleranceMS, r.samples)
        note(calMessage)
    }

    var improvingRhythm = false

    /// Add more pairs to the rhythm already stored, instead of replacing it.
    func improveRhythmCalibration() {
        improvingRhythm = true
        beginRhythmCalibration()
    }

    func beginRhythmCalibration() {
        rhythmGaps = []; rhythmPairs = 0; lastRhythmKnock = 0
        rhythmKnocksHeard = 0; rhythmLastGapMS = nil
        pairTimes = []; pairKnocks = 0
        calPhase = .rhythm
        calibrating = true
        calMessage = ""
        // Chicken and egg: the boost that catches the weak second knock is aimed
        // by the learned rhythm, but rhythm calibration is when it is needed most
        // and no rhythm exists yet. During calibration it covers a broad band
        // instead — one calibration produced a "rhythm" of 605 ms because the
        // second knock kept being missed and the pause BETWEEN pairs was
        // recorded in its place.
        detector.config.expectLoMS = 80
        detector.config.expectHiMS = 900
    }

    private func beginCalibration() {
        calLeftBlocks = []; calRightBlocks = []; calCurrentBlock = []; calPeaks = []
        calBlock = 0; calCollected = 0
        rhythmGaps = []; rhythmPairs = 0; lastRhythmKnock = 0; blockPeaksMG = []
        rhythmKnocksHeard = 0; rhythmLastGapMS = nil
        calPhase = .direction
        calibrating = true
        calMessage = ""
    }

    var canAdvance: Bool {
        calPhase == .direction ? calCollected >= Self.minimumPerBlock
                               : rhythmPairs >= 3
    }
    /// A pair can be recorded once exactly two knocks have been heard.
    var canRecordPair: Bool { calPhase == .rhythm && pairKnocks == 2 }

    /// Commit the two knocks just made as one double, or throw them away.
    ///
    /// Pairs are recorded one at a time on an explicit press rather than
    /// inferred from a running stream. Inferring them chained a missed second
    /// knock into the next pair and recorded the pause BETWEEN pairs as if it
    /// were a double — one calibration learned a "rhythm" of 605 ms that way,
    /// which then rejected every real double the user made.
    func recordPair() {
        guard pairTimes.count >= 2 else { return }
        let gap = Double(pairTimes[1] &- pairTimes[0]) / 1e6
        if gap > 40 && gap < 1200 {
            rhythmGaps.append(gap)
            rhythmPairs += 1
        }
        pairTimes = []
        pairKnocks = 0
    }

    func discardPair() {
        pairTimes = []
        pairKnocks = 0
        rhythmLastGapMS = nil
    }
    var advanceRequirement: String {
        calPhase == .direction
            ? "At least \(Self.minimumPerBlock) knocks before you can continue."
            : "At least 3 double knocks before you can continue."
    }
    var isLastBlock: Bool { calBlock >= activePlan.count - 1 }

    /// Advancing is an explicit action, never automatic on a knock count.
    ///
    /// Counting knocks alone deadlocks: one knock the detector misses and the
    /// block can never complete, with no way forward and no explanation. The
    /// operator decides when a block is done.
    func advanceCalibration() {
        guard calibrating, canAdvance else { return }
        if calPhase == .rhythm { finishRhythm(); return }
        sealBlock()
        if isLastBlock {
            finishDirection()
        } else {
            calBlock += 1
            calCollected = 0
            blockPeaksMG = []
        }
    }

    func cancelCalibration() {
        calibrating = false
        calMessage = ""
        applySensitivity()
    }

    private func collectCalibration(_ k: KnockEvent) {
        if calPhase == .rhythm {
            rhythmKnocksHeard += 1
            pairTimes.append(k.t)
            pairKnocks = pairTimes.count
            if pairTimes.count >= 2 {
                rhythmLastGapMS = Double(pairTimes[1] &- pairTimes[0]) / 1e6
            }
            return
        }
        guard calibrationTarget != nil else { return }
        guard k.rollWaveform.count == DirectionModel.windowSamples else {
            calMessage = "a knock was detected but its window was incomplete — ignored"
            return
        }
        calCurrentBlock.append(k.rollWaveform)
        calPeaks.append(k.accelPeak)
        blockPeaksMG.append(Int((k.accelPeak * 1000).rounded()))
        calCollected += 1
        calMessage = ""
    }

    /// Write the raw calibration knocks to disk.
    ///
    /// Without this a poor model cannot be diagnosed: the trained template says
    /// nothing about whether the knocks behind it were inconsistent, mislabelled
    /// or simply too few, and the only remedy is to make the user knock another
    /// forty times. Every other stage of this project keeps its raw measurements
    /// for exactly this reason.
    private func dumpCalibration() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("InvisiButton", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        func pack(_ blocks: [[[Double]]], _ side: String) -> [[String: Any]] {
            blocks.enumerated().flatMap { (bi, blk) in
                blk.map { ["side": side, "block": bi, "roll": $0] as [String: Any] }
            }
        }
        let doc: [String: Any] = [
            "schema": "invisibutton.calibration/1",
            "created": ISO8601DateFormatter().string(from: Date()),
            "machine": sysctlString("hw.model"),
            "windowSamples": DirectionModel.windowSamples,
            "peaksG": calPeaks,
            "rhythmGapsMS": rhythmGaps,
            "knocks": pack(calLeftBlocks, "left") + pack(calRightBlocks, "right"),
        ]
        if let d = try? JSONSerialization.data(withJSONObject: doc) {
            let stamp = Int(Date().timeIntervalSince1970)
            try? d.write(to: base.appendingPathComponent("calibration-\(stamp).json"),
                         options: .atomic)
        }
    }

    /// Pull the active profile's models into the live pipeline.
    func loadActiveProfile() {
        guard let p = profiles.active else { return }
        if let d = p.direction, d.isCompatible {
            direction.model = d
            direction.staleVersion = nil
        } else {
            direction.model = nil
            direction.staleVersion = p.direction?.version
        }
        rhythmStore.rhythm = p.rhythm
        assembler.rhythm = p.rhythm
        directionAvailable = direction.model != nil
        applySensitivity()
        verifyResult = nil
        note("profile: \(p.name) — \(p.summary)")
    }

    private func storeToProfile() {
        profiles.update { p in
            p.direction = direction.model
            p.rhythm = rhythmStore.rhythm
            if let c = pendingCalibration { p.calibration = c }
        }
        pendingCalibration = nil
    }

    func forgetDirectionCalibration() {
        profiles.update { $0.forgetDirectionCalibration() }
        direction.clear()
        directionAvailable = false
        pendingCalibration = nil
        verifyResult = nil
        applySensitivity()
        note("direction calibration forgotten for this desk")
    }

    func forgetRhythmCalibration() {
        profiles.update { $0.forgetRhythmCalibration() }
        rhythmStore.clear()
        assembler.rhythm = nil
        rejectedGapsMS = []
        applySensitivity()
        note("rhythm calibration forgotten for this desk")
    }

    // ── Verify (returning to a desk) ────────────────────────────────────────
    @Published var verifying = false {
        didSet { let v = verifying; verifyingFlag.withLock { $0 = v } }
    }
    @Published var verifyTarget: Area = .left
    @Published var verifyDone = 0
    private var verifyCorrect = 0
    static let verifyPerSide = 4

    func beginVerify() {
        guard direction.model != nil else { return }
        verifying = true
        verifyDone = 0
        verifyCorrect = 0
        verifyTarget = .left
        verifyResult = nil
    }

    func cancelVerify() { verifying = false }

    private func collectVerify(_ k: KnockEvent) {
        guard let m = direction.model,
              k.rollWaveform.count == DirectionModel.windowSamples else { return }
        if m.classify(k.rollWaveform) == verifyTarget { verifyCorrect += 1 }
        verifyDone += 1
        if verifyDone == Self.verifyPerSide { verifyTarget = .right }
        if verifyDone >= Self.verifyPerSide * 2 {
            verifying = false
            verifyResult = VerifyResult(correct: verifyCorrect, total: verifyDone)
        }
    }

    private func sealBlock() {
        guard !calCurrentBlock.isEmpty, let target = calibrationTarget else { return }
        if target == .left { calLeftBlocks.append(calCurrentBlock) }
        else { calRightBlocks.append(calCurrentBlock) }
        calCurrentBlock = []
    }

    private func finishRhythm() {
        calibrating = false
        defer { applySensitivity() }     // restore the learned window
        var allGaps = rhythmGaps
        if improvingRhythm, let existing = profiles.active?.rhythmGapsMS {
            allGaps = existing + rhythmGaps
        }
        improvingRhythm = false
        guard let r = KnockRhythm.learn(gapsMS: allGaps) else {
            calMessage = "Not enough double knocks to learn a rhythm. Try again."
            return
        }
        // A "rhythm" this loose is not a rhythm. It means the second knock of
        // each pair was missed and the gaps recorded are the pauses between
        // pairs, which would produce a window that accepts everything and
        // silently removes the entire benefit.
        guard r.sdGapMS <= 120, r.meanGapMS <= 700 else {
            calMessage = String(
                format: "Those knocks were too inconsistent to learn a rhythm "
                      + "(%.0f ± %.0f ms). Usually this means the second knock of each "
                      + "pair was not detected. Knock the pair a little slower, and "
                      + "about as hard on the second as the first.",
                r.meanGapMS, r.sdGapMS)
            return
        }
        rhythmStore.rhythm = r
        rhythmStore.save()
        assembler.rhythm = r
        applySensitivity()
        profiles.update { $0.rhythmGapsMS = allGaps }
        storeToProfile()
        calMessage = String(format: "Rhythm learned: %.0f ± %.0f ms, from %d double knocks.",
                            r.meanGapMS, r.toleranceMS, r.samples)
        note(calMessage)
    }

    private func finishDirection() {
        calibrating = false
        dumpCalibration()

        var data = CalibrationData(leftBlocks: calLeftBlocks,
                                   rightBlocks: calRightBlocks,
                                   peaks: calPeaks)
        let previousKnocks = profiles.active?.calibration?.knockCount ?? 0

        // No raw knocks stored, but the model carries its class means: merge
        // into those, and report how the OLD model scored on these new knocks —
        // a genuinely held-out number, since it never saw them.
        if improving, profiles.active?.calibration == nil,
           let old = direction.model,
           let (mergedModel, heldOut) = old.merged(
                withLeft: calLeftBlocks.flatMap { $0 },
                right: calRightBlocks.flatMap { $0 },
                peaks: calPeaks) {
            direction.model = mergedModel
            directionAvailable = true
            pendingCalibration = data
            applySensitivity()
            storeToProfile()
            calMessage = String(
                format: "Merged: now %d left and %d right knocks. The previous model got "
                      + "%.0f%% of these new knocks right — held out, not fitted.",
                mergedModel.leftCount, mergedModel.rightCount, heldOut * 100)
            note(calMessage)
            return
        }

        if improving, var existing = profiles.active?.calibration {
            existing.append(data)
            data = existing
        }
        guard let m = DirectionModel.train(leftBlocks: data.leftBlocks,
                                           rightBlocks: data.rightBlocks,
                                           peaks: data.peaks,
                                           desk: profiles.activeName ?? "this desk") else {
            calMessage = "Not enough usable knocks. Try again."
            return
        }
        pendingCalibration = data
        direction.model = m
        direction.save()
        directionAvailable = true
        // The detection threshold now comes from this user's own knocks rather
        // than a constant that cannot fit everyone.
        applySensitivity()
        note(String(format: "threshold set from your knocks: %.0f mg",
                    m.suggestedMinAccelG * 1000))
        storeToProfile()
        let acc = String(format: "%.0f%%", m.trainingAccuracy * 100)
        if improving && previousKnocks > 0 {
            calMessage = "Improved: \(previousKnocks) knocks became "
                + "\(m.leftCount + m.rightCount). Held-out accuracy \(acc)."
        } else {
            calMessage = "Direction calibrated on \(m.leftCount) left and "
                + "\(m.rightCount) right knocks. Held-out accuracy \(acc)."
        }
        note(calMessage)
    }

    private let reader = SensorReader()
    private let detector = KnockDetector()
    private let assembler = PatternAssembler()
    private var uiTimer: Timer?
    private var healthTimer: Timer?
    private var peakAccel = 0.0
    private var peakGyro = 0.0
    private var lastTemp: UInt32 = 0
    private var lastReportCount: UInt64 = 0

    func stop() {
        uiTimer?.invalidate()
        healthTimer?.invalidate()
        reader.stop()
        running = false
    }

    func start() {
        guard !running else { return }
        if let raw = UserDefaults.standard.string(forKey: "sensitivity"),
           let s = Sensitivity(rawValue: raw) { sensitivity = s }
        applySensitivity()
        bindings.load()
        direction.load()
        profiles.load()
        if profiles.profiles.isEmpty { profiles.create(name: "This desk") }
        rhythmStore.load()
        assembler.rhythm = rhythmStore.rhythm
        loadActiveProfile()
        directionAvailable = direction.model != nil
        if let v = direction.staleVersion {
            note("saved direction calibration is from an older version (v\(v)) — "
                 + "recalibrate to use it")
        }
        let survey = SensorReader.survey()
        support = survey.support
        guard survey.support.isUsable else {
            note(survey.support.message)
            return
        }

        detector.onRejected = { [weak self] why in
            Task { @MainActor in
                self?.lastRejection = why
                self?.rejectCount += 1
            }
        }
        assembler.onRhythmReject = { [weak self] why, gap in
            Task { @MainActor in
                guard let self else { return }
                self.lastRejection = why
                self.rejectCount += 1
                // Only gaps near the window are evidence the window is too
                // tight; a 90 ms pair is not a slow version of a 361 ms one.
                if let r = self.rhythmStore.rhythm,
                   gap > r.lowMS * 0.5, gap < r.highMS * 1.8 {
                    self.rejectedGapsMS.append(gap)
                    if self.rejectedGapsMS.count > 20 { self.rejectedGapsMS.removeFirst() }
                }
                self.note("pattern rejected — \(why)")
            }
        }
        detector.onKnock = { [weak self] k in
            guard let self else { return }
            // `calibrating` is read without hopping to the main actor: a `return`
            // inside a Task returns from the Task, not from this closure, so the
            // earlier version fed every calibration knock to the assembler too.
            if self.calibratingFlag.withLock({ $0 }) {
                Task { @MainActor in self.collectCalibration(k) }
                return
            }
            if self.verifyingFlag.withLock({ $0 }) {
                Task { @MainActor in self.collectVerify(k) }
                return
            }
            self.assembler.add(k)
            let prev = self.previousKnockTime
            self.previousKnockTime = k.t
            Task { @MainActor in
                self.lastKnock = k
                self.knockCount += 1
                self.lastIntervalMS = prev == 0 ? nil : Double(k.t &- prev) / 1e6
            }
        }
        assembler.onPattern = { [weak self] batch in
            guard let self else { return }
            Task { @MainActor in self.fire(batch) }
        }
        reader.onSample = { [weak self] channel, sample in
            guard let self else { return }
            self.detector.ingest(channel, sample)
            switch channel {
            case .accel:
                let m = max(abs(sample.gx), max(abs(sample.gy), abs(sample.gz) - 1.0))
                if m > self.peakAccel { self.peakAccel = m }
                self.lastTemp = sample.temp
            case .gyro:
                let m = max(abs(sample.gx), abs(sample.gy))
                if m > self.peakGyro { self.peakGyro = m }
            }
        }

        reader.start(devices: survey.devices)
        running = true
        note(survey.support.message)

        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // T-045 / T-032: the driver wake is not guaranteed to survive system
        // sleep, and the failure is silent — the stream simply stops. Watch for
        // a quiet stream and re-wake.
        healthTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHealth() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.note("system woke — re-waking SPU driver")
                SPUDriverWaker.wake()
            }
        }
    }

    private func tick() {
        levelAccel = min(1.0, peakAccel / 0.3)
        levelGyro = min(1.0, peakGyro / 8.0)
        dieTemperature = Double(lastTemp) / 65536
        peakAccel *= 0.6
        peakGyro *= 0.6
    }

    private func checkHealth() {
        let n = reader.reportCount
        defer { lastReportCount = n }
        guard running, n == lastReportCount else { return }
        note("sensor stream went quiet — re-waking driver")
        SPUDriverWaker.wake()
    }

    private func fire(_ batch: [KnockEvent]) {
        guard !calibrating else { return }
        // Direction comes from the per-desk model when one has been calibrated.
        // The first knock of the pattern decides: later knocks in a pattern land
        // on a chassis that is still ringing, so their roll waveform is polluted.
        var area = Area.any
        if let m = direction.model, let first = batch.first,
           let a = m.classify(first.rollWaveform) { area = a }
        let g = Gesture(count: min(batch.count, 3), area: area)
        lastPattern = g.describe
        let action = bindings.action(for: g)
        note("\(g.describe) → \(action.describe)")
        ActionDispatcher.perform(action) { [weak self] msg in
            Task { @MainActor in self?.note(msg) }
        }
    }

    func note(_ s: String) {
        log.insert(s, at: 0)
        if log.count > 40 { log.removeLast() }
    }
}

struct MenuView: View {
    @ObservedObject var state: AppState

    private var activeGestures: [Gesture] {
        Bindings.allGestures.filter { state.bindings.action(for: $0) != .none }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("InvisiButton").font(.headline)
                    Text("Local desk-knock controls")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(state.running ? "Listening" : "Stopped",
                      systemImage: state.running ? "waveform.circle.fill" : "pause.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(state.running ? Color.green : Color.secondary)
            }

            if !state.support.isUsable {
                // T-030: refuse specifically, naming what is missing.
                // Never fail silently (Product Principle 2).
                Text(state.support.message)
                    .font(.system(size: 11))
                    .frame(maxWidth: 320, alignment: .leading)
                    .textSelection(.enabled)
                Divider()
                Button("Quit InvisiButton") { NSApplication.shared.terminate(nil) }
            } else {
                running
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    @ViewBuilder
    private var running: some View {
        Group {
            Text("knocks detected: \(state.knockCount)   last pattern: \(state.lastPattern)")
                .font(.system(size: 11, design: .monospaced))
            Text(state.lastRejection.isEmpty
                 ? "no rejected knocks yet"
                 : "last rejected (\(state.rejectCount)): \(state.lastRejection)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text(state.lastIntervalMS.map {
                    String(format: "gap since previous knock: %.0f ms  (grouped if under %.0f)",
                           $0, 600.0)
                 } ?? "gap since previous knock: —")
                .font(.system(size: 10, design: .monospaced))

            // T-024: numeric first. The bars are drawn from these numbers so a
            // VoiceOver user gets the same information, not a decorative label.
            Text(String(format: "accel %.0f%%   gyro %.0f%%   die %.1f °C",
                        state.levelAccel * 100, state.levelGyro * 100,
                        state.dieTemperature))
                .font(.system(size: 11, design: .monospaced))
                .accessibilityLabel(String(
                    format: "Signal strength: accelerometer %.0f percent, gyroscope %.0f percent",
                    state.levelAccel * 100, state.levelGyro * 100))

            HStack(spacing: 2) {
                ProgressView(value: state.levelAccel).frame(width: 120)
                ProgressView(value: state.levelGyro).frame(width: 120)
            }
            .accessibilityHidden(true)

            if let k = state.lastKnock {
                Text(String(format: "last: %.0f mg, %.1f °/s, rise %.0f ms, %.0f ms wide",
                            k.accelPeak * 1000, k.gyroPeakXY, k.riseMS, k.durationMS))
                    .font(.system(size: 10, design: .monospaced))
            }

            Divider()
            HStack {
                Label("Actions", systemImage: "bolt.fill")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("Configure…") { SettingsWindow.show(state: state) }
                    .font(.system(size: 11))
            }
            if activeGestures.isEmpty {
                Text("No actions configured. Add a double-knock action to get started.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(activeGestures.prefix(8), id: \.self) { g in
                Text("\(g.describe): \(state.bindings.action(for: g).describe)")
                    .font(.system(size: 10, design: .monospaced))
            }
            Label(state.bindings.allowSingleKnockActions
                  ? "Single-knock actions enabled"
                  : "Safe mode · single-knock actions blocked",
                  systemImage: state.bindings.allowSingleKnockActions
                    ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(state.bindings.allowSingleKnockActions
                                 ? Color.orange : Color.secondary)
            if let m = state.direction.model {
                Text(String(format: "direction: calibrated, %.0f%% held-out",
                            m.trainingAccuracy * 100))
                    .font(.system(size: 10, design: .monospaced))
            } else {
                Text("direction: not calibrated").font(.system(size: 10, design: .monospaced))
            }
            Text(state.rhythmStore.rhythm == nil
                 ? "rhythm: not calibrated — configure before relying on double knocks"
                 : "rhythm: calibrated for this desk")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(state.rhythmStore.rhythm == nil ? Color.orange : Color.secondary)

            Divider()
            Text("Log").font(.system(size: 11)).bold()
            ForEach(Array(state.log.prefix(6).enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 10, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            }

            Divider()
            Button("Quit InvisiButton") { NSApplication.shared.terminate(nil) }
        }
    }
}

/// Starts the sensor at launch.
///
/// This must NOT live in the menu content's `.onAppear`: MenuBarExtra only
/// instantiates its content when the user first clicks the icon, so the app sat
/// deaf until someone opened the menu — 0.00 CPU-seconds over 30 s of what
/// should have been 48 000 samples. A knock utility that only listens while you
/// are looking at its menu is useless, and the failure is completely silent.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.stop()
    }
}

@main
struct InvisiButtonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("InvisiButton", systemImage: "hand.tap") {
            MenuView(state: delegate.state)
        }
        .menuBarExtraStyle(.window)
    }
}
