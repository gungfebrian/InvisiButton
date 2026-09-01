// InvisiButton · T-029 · Gesture → action binding
//
// PHASE 1 DISCIPLINE: functional, unstyled. Visual design is Phase 2 (PLAN.md).
//
// The area dimension is shown and disabled. D-020 established that left and
// right separate within a desk, but cross-desk transfer is unestablished and the
// detection pipeline does not compute direction yet. HANDOFF.md is explicit:
// "Do not build UI around direction before T-016 passes." Showing the dimension
// greyed out with the reason is honest; offering a control that silently does
// nothing is not.

import AppKit
import SwiftUI

/// Picks an application by browsing for it, rather than asking for a bundle
/// identifier typed from memory.
///
/// The identifier field was a real defect, not just friction: switching the
/// action type writes an empty identifier, and an empty identifier is a binding
/// that silently does nothing. One was lost that way immediately.
struct AppChooser: View {
    let bundleID: String
    let onPick: (String) -> Void

    private var info: (name: String, icon: NSImage)? {
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared
                  .urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return (FileManager.default.displayName(atPath: url.path),
                NSWorkspace.shared.icon(forFile: url.path))
    }

    var body: some View {
        HStack(spacing: 6) {
            if let info {
                Image(nsImage: info.icon).resizable().frame(width: 16, height: 16)
                Text(info.name).font(.system(size: 12))
            } else if bundleID.isEmpty {
                Text("No app chosen").font(.system(size: 12)).foregroundStyle(.orange)
            } else {
                Text("Not installed: \(bundleID)")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Choose…") { choose() }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose an application"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Read the identifier from the bundle rather than trusting a typed string.
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        onPick(id)
    }
}

enum ActionKind: String, CaseIterable, Identifiable {
    case none, shortcut, shell, appleScript, launchApp, mediaKey
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none:        return "Do nothing"
        case .shortcut:    return "Run a Shortcut"
        case .shell:       return "Run a shell command"
        case .appleScript: return "Run AppleScript"
        case .launchApp:   return "Open an app"
        case .mediaKey:    return "Media key"
        }
    }

    static func of(_ a: Action) -> ActionKind {
        switch a {
        case .none:        return .none
        case .shortcut:    return .shortcut
        case .shell:       return .shell
        case .appleScript: return .appleScript
        case .launchApp:   return .launchApp
        case .mediaKey:    return .mediaKey
        }
    }
}

struct BindingRow: View {
    let gesture: Gesture
    @ObservedObject var bindings: Bindings
    var state_singleRate: Int = 42

    private var action: Action { bindings.map[gesture] ?? .none }

    private func set(_ a: Action) {
        bindings.map[gesture] = a
        bindings.save()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(gesture.describe).bold().font(.system(size: 12))

            HStack {
                Picker("", selection: Binding(
                    get: { ActionKind.of(action) },
                    set: { kind in
                        switch kind {
                        case .none:        set(.none)
                        case .shortcut:    set(.shortcut(name: ""))
                        case .shell:       set(.shell(command: ""))
                        case .appleScript: set(.appleScript(source: ""))
                        case .launchApp:
                            // Keep any app already chosen when the type is
                            // re-selected, instead of blanking it.
                            if case .launchApp(let existing) = action {
                                set(.launchApp(bundleID: existing))
                            } else {
                                set(.launchApp(bundleID: ""))
                            }
                        case .mediaKey:    set(.mediaKey(.playPause))
                        }
                    })) {
                    ForEach(ActionKind.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 170)

                switch action {
                case .shortcut(let n):
                    TextField("Shortcut name", text: Binding(
                        get: { n }, set: { set(.shortcut(name: $0)) }))
                case .shell(let c):
                    TextField("command", text: Binding(
                        get: { c }, set: { set(.shell(command: $0)) }))
                case .appleScript(let src):
                    TextField("AppleScript", text: Binding(
                        get: { src }, set: { set(.appleScript(source: $0)) }))
                case .launchApp(let b):
                    AppChooser(bundleID: b) { set(.launchApp(bundleID: $0)) }
                case .mediaKey(let k):
                    Picker("", selection: Binding(
                        get: { k }, set: { set(.mediaKey($0)) })) {
                        ForEach([MediaKey.playPause, .next, .previous,
                                 .mute, .volumeUp, .volumeDown], id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .labelsHidden()
                case .none:
                    Text("").frame(maxWidth: .infinity)
                }
            }

            if gesture.count == 1 && action != .none {
                Text("⚠︎ Single-knock bindings fire by accident. At this sensitivity that is "
                     + "roughly \(state_singleRate) times an hour of ordinary use. A double "
                     + "knock needs two knocks inside 600 ms and fired nothing false in the "
                     + "same measurement.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if action.requiresAccessibility {
                Text("Media keys need Accessibility permission. Every other action type "
                     + "needs none — bind something else to keep InvisiButton prompt-free.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct CalibrationSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Knock location").font(.system(size: 12)).bold()

            if state.calibrating {
                if state.calPhase == .rhythm {
                    Text("Now knock your DOUBLE knock, the way you actually would")
                        .font(.system(size: 13)).bold()
                    Text("\(AppState.rhythmPairsNeeded) times, pausing between each pair. "
                         + "This learns your timing — a pair that arrives at the wrong "
                         + "rhythm is not your knock, and gets rejected.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("double knocks registered: \(state.rhythmPairs) "
                         + "of \(AppState.rhythmPairsNeeded)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(state.canAdvance ? .primary : .secondary)
                    Text("knocks in this pair: \(state.pairKnocks) of 2"
                         + (state.rhythmLastGapMS.map {
                                String(format: "   gap %.0f ms", $0) } ?? ""))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(state.canRecordPair ? .primary : .secondary)

                    HStack {
                        Button("Record this pair") { state.recordPair() }
                            .disabled(!state.canRecordPair)
                        Button("Discard") { state.discardPair() }
                            .disabled(state.pairKnocks == 0)
                    }

                    if state.pairKnocks == 1 {
                        Text("Only one knock landed. Knock the second, or Discard and redo the "
                             + "pair — the second knock of a double is weaker and is the one "
                             + "that gets missed.")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if state.pairKnocks > 2 {
                        Text("More than two knocks. Discard and do a clean pair.")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                    }
                } else {
                    let side = state.calibrationTarget == .left ? "LEFT" : "RIGHT"
                    let total = state.activePlan.count
                    let suffix = state.improving ? "  (adding to your existing calibration)" : ""
                    Text(verbatim: "Block \(state.calBlock + 1) of \(total) — "
                         + "knock \(side) of the laptop" + suffix)
                        .font(.system(size: 13)).bold()
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Knock exactly as you would in normal use — not harder. "
                         + "Same spot every time, about 15 cm out from the edge. "
                         + "Consistent placement matters far more than force.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("knocks in this block: \(state.calCollected) "
                         + "of \(AppState.knocksPerBlock)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(state.canAdvance ? .primary : .secondary)

                    // Live amplitudes: an inconsistent column here is the cause
                    // of a poor direction model, and it is visible while there is
                    // still time to fix it.
                    if !state.blockPeaksMG.isEmpty {
                        Text("strength: "
                             + state.blockPeaksMG.map { "\($0)" }.joined(separator: "  ")
                             + " mg")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                ProgressView(value: Double(state.calBlock),
                             total: Double(AppState.calibrationPlan.count))
                    .frame(width: 260)

                if !state.calMessage.isEmpty {
                    Text(state.calMessage).font(.system(size: 10)).foregroundStyle(.secondary)
                }

                HStack {
                    Button(state.calPhase == .rhythm ? "Finish calibration"
                           : state.isLastBlock ? "Next: learn your rhythm" : "Next block") {
                        state.advanceCalibration()
                    }
                    .disabled(!state.canAdvance)
                    .keyboardShortcut(.defaultAction)

                    Button("Cancel") { state.cancelCalibration() }
                }
                Text(state.canAdvance
                     ? "Knock more if you like — extra knocks make the model better."
                     : state.advanceRequirement)
                    .font(.system(size: 10)).foregroundStyle(.secondary)

                // The rejection reason belongs here, where calibration happens,
                // not only in the menu bar popover.
                if !state.lastRejection.isEmpty {
                    Text("last rejected (\(state.rejectCount)): \(state.lastRejection)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // Direction and rhythm are separate, so a failure in one does not
                // discard the other's work.
                if let m = state.direction.model {
                Text(String(format: "Calibrated on %d left and %d right knocks.",
                            m.leftCount, m.rightCount))
                    .font(.system(size: 11))
                Text(String(format: "Held-out accuracy: %.0f%%", m.trainingAccuracy * 100))
                    .font(.system(size: 11, design: .monospaced))
                Text(String(format: "Your knocks: %.0f mg · detection threshold set to %.0f mg",
                            m.knockP10G * 1000, m.suggestedMinAccelG * 1000))
                    .font(.system(size: 11, design: .monospaced))
                if m.knockP10G > 0 && m.knockP10G < DirectionModel.softKnockWarningG {
                    Text("⚠︎ Those knocks are soft. Setting a cup down measures about 26 mg and "
                         + "nudging the laptop about 47 mg, so knocks in this range cannot be "
                         + "separated from ordinary desk noise by any threshold — expect false "
                         + "triggers. Recalibrate with firmer knocks: a solid knuckle rap "
                         + "measures 180 mg or more and sits well clear of everything else.")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Measured by holding out whole calibration blocks, not single knocks — "
                     + "knocks from one block are too similar to each other and would "
                     + "flatter the result.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if m.trainingAccuracy < 0.8 {
                    Text("⚠︎ Too low to use. At this accuracy the app cannot reliably tell "
                         + "which side you knocked, so left and right bindings will fire more "
                         + "or less at random. Recalibrate: knock the same distance from the "
                         + "laptop every time on each side, and keep your other hand off the "
                         + "machine. If it stays below 80% after a careful attempt, direction "
                         + "does not work on this desk — bind “Double knock” with no side "
                         + "instead, which ignores direction entirely.")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    // Adding to a calibration beats replacing it: the model gets
                    // better with data, and good knocks should not be thrown away
                    // to collect more.
                    Button("Improve (add 36 more knocks)") {
                        state.improveDirectionCalibration()
                    }
                    .disabled(state.profiles.active?.calibration == nil)
                    Button("Start over") { state.beginDirectionCalibration() }
                }
                if let c = state.profiles.active?.calibration {
                    Text("built from \(c.knockCount) knocks in \(c.blockCount) blocks — "
                         + "Improve adds to these rather than discarding them")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("This model was made before knocks were kept, so Improve is "
                         + "unavailable — one more full calibration will enable it.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Forget") { state.forgetDirectionCalibration() }
                } else {
                    if let v = state.direction.staleVersion {
                        Text("Your saved calibration (v\(v)) was made before a fix to how the "
                             + "gyroscope window is located, so the model it produced is "
                             + "misaligned and cannot be used. It is still on disk — nothing was "
                             + "deleted — but it needs redoing once.")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Direction not calibrated. Left and right bindings do nothing until "
                         + "InvisiButton learns this desk. A plain “Double knock” binding "
                         + "works without it.")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Calibrate direction (36 knocks)") {
                        state.beginDirectionCalibration()
                    }
                }

                Divider().padding(.vertical, 2)

                if let r = state.rhythmStore.rhythm {
                    Text(String(format: "Rhythm: %.0f ± %.0f ms, from %d double knocks",
                                r.meanGapMS, r.toleranceMS, r.samples))
                        .font(.system(size: 11, design: .monospaced))
                    Text("Pairs outside that window are rejected rather than fired. Measured: "
                         + "47.6 false double-knock actions an hour down to zero, keeping "
                         + "every real one.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Add more pairs") { state.improveRhythmCalibration() }
                            .disabled(state.profiles.active?.rhythmGapsMS == nil)
                        Button("Start over") { state.beginRhythmCalibration() }
                        Button("Forget") { state.forgetRhythmCalibration() }
                    }

                    // Pairs the window turned away are the evidence for widening
                    // it — and the only honest basis for doing so.
                    if !state.rejectedGapsMS.isEmpty {
                        let g = state.rejectedGapsMS.map { Int($0) }
                        Text("\(g.count) double knocks were refused for timing: "
                             + g.map { "\($0)" }.joined(separator: ", ") + " ms")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Accept these as your rhythm too") {
                            state.widenRhythmFromRejections()
                        }
                        if !state.calMessage.isEmpty {
                            Text(state.calMessage)
                                .font(.system(size: 10, design: .monospaced))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("This widens the window by your actual variation rather than by a "
                             + "guess. It will also let through more false doubles — the "
                             + "window is the only thing separating your knock from two "
                             + "unrelated ones.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Rhythm not learned. Without it a double knock is any two knocks "
                         + "within 600 ms, which is the main source of false triggers — and the "
                         + "detector cannot boost its sensitivity for the second knock of a pair.")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Calibrate rhythm (8 double knocks)") {
                        state.beginRhythmCalibration()
                    }
                }
            }

            if !state.calMessage.isEmpty && !state.calibrating {
                Text(state.calMessage).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("""
                 Direction is learned per desk and does not carry to another one. \
                 Measured: left and right separate reliably on a single desk, but a model \
                 trained on one desk classifies another at chance. Move to a different \
                 desk and you will need to calibrate again.
                 """)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

struct ProfileSection: View {
    @ObservedObject var state: AppState
    @State private var newName = ""
    @State private var renaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Desk profile").font(.system(size: 12)).bold()
            HStack {
                Picker("", selection: Binding(
                    get: { state.profiles.activeName ?? "" },
                    set: { state.profiles.activeName = $0; state.loadActiveProfile() })) {
                    ForEach(state.profiles.profiles) { p in
                        Text(p.name).tag(p.name)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                Button("New…") { renaming = false; newName = ""; addFocus = true }
                if let n = state.profiles.activeName, state.profiles.profiles.count > 1 {
                    Button("Delete") { state.profiles.delete(n); state.loadActiveProfile() }
                }
            }
            if addFocus {
                HStack {
                    TextField("Name this desk, e.g. Home or Studio", text: $newName)
                        .frame(width: 240)
                    Button("Create") {
                        state.profiles.create(name: newName)
                        state.loadActiveProfile()
                        addFocus = false
                    }
                    Button("Cancel") { addFocus = false }
                }
            }
            if let p = state.profiles.active {
                Text(p.summary).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Verify: whether the stored profile still fits this desk today.
            if state.direction.model != nil {
                if state.verifying {
                    Text("Knock \(state.verifyTarget == .left ? "LEFT" : "RIGHT") — "
                         + "\(state.verifyDone) of \(AppState.verifyPerSide * 2)")
                        .font(.system(size: 12)).bold()
                    Button("Cancel") { state.cancelVerify() }
                } else {
                    HStack {
                        Button("Verify this profile (8 knocks)") { state.beginVerify() }
                        if let v = state.verifyResult {
                            Text("\(v.correct)/\(v.total) correct")
                                .font(.system(size: 11, design: .monospaced))
                        }
                    }
                    if let v = state.verifyResult {
                        Text(v.verdict).font(.system(size: 10))
                            .foregroundStyle(v.accuracy >= 0.85
                                             ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Whether a profile still fits after you return to a desk has never "
                         + "been measured — earlier claims that it survives moving the laptop "
                         + "were withdrawn as unsound. Eight knocks and a number beats assuming.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @State private var addFocus = false
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var bindings: Bindings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ProfileSection(state: state)
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Sensitivity").font(.system(size: 12)).bold()
                    Picker("", selection: Binding(
                        get: { state.sensitivity },
                        set: { state.sensitivity = $0 })) {
                        ForEach(Sensitivity.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 300)
                    Text(state.sensitivity.summary)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Measured over ten minutes of ordinary use on two desks — typing, "
                         + "trackpad, moving the laptop, setting a cup down.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                Divider()

                CalibrationSection(state: state)
                Divider()

                Text("Knock bindings").font(.system(size: 14)).bold()

                ForEach(Bindings.allGestures, id: \.self) { g in
                    BindingRow(gesture: g, bindings: bindings,
                               state_singleRate: state.sensitivity == .cautious ? 12
                                                 : state.sensitivity == .balanced ? 42 : 220)
                    Divider()
                }

                Text("Detection is not finished. The target is one false action per hour and "
                     + "no setting reaches it for single knocks. Double-knock bindings are the "
                     + "safe ones today.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .frame(width: 460, height: 520)
    }
}

@MainActor
final class SettingsWindow {
    private static var window: NSWindow?

    static func show(state: AppState) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        w.title = "InvisiButton Settings"
        w.contentView = NSHostingView(
            rootView: SettingsView(state: state, bindings: state.bindings))
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
