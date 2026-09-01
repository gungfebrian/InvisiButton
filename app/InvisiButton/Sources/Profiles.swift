// InvisiButton · Named calibration profiles
//
// One profile per place you work. Holds everything that is a property of a desk
// rather than of knocking: the direction model, the detection threshold derived
// from your knocks there, and your double-knock rhythm.
//
// WHY MANUAL NAMES AND NOT AUTOMATIC DETECTION
//
// The desk's structural resonance looked like a natural fingerprint — it barely
// moves when the laptop is displaced (67.0 to 67.5 Hz across 10 cm). But D-015
// measured it collapsing under rotation: turning the laptop 30 degrees moved
// desk1's dominant peak to 44 Hz, and a rotated desk1 then resembled a
// *different desk* (0.505) about as much as it resembled itself unrotated
// (0.618). Automatic switching on that signal would quietly load the wrong
// profile, which is worse than asking.
//
// WHAT IS NOT KNOWN
//
// Whether a stored profile still classifies correctly when you return to a desk
// another day is unmeasured. D-014 reported a profile surviving a 10 cm move and
// a 30 degree rotation, but D-018 withdrew both — they were measured against a
// null that did not preserve the block structure of the data. Returning to a
// desk is a larger perturbation than either.
//
// That is why Verify exists. Eight knocks and a number beats an assumption.

import Foundation

/// The raw knocks a direction model was trained on, kept with the profile.
///
/// Storing only the trained template makes a calibration a dead end: the only
/// way to improve it is to throw it away and collect everything again. Keeping
/// the knocks means a later session can ADD to them, and means a better training
/// method can be applied to data already collected rather than asking the user
/// to knock another thirty-six times.
struct CalibrationData: Codable {
    var leftBlocks: [[[Double]]] = []
    var rightBlocks: [[[Double]]] = []
    var peaks: [Double] = []

    var knockCount: Int {
        leftBlocks.reduce(0) { $0 + $1.count } + rightBlocks.reduce(0) { $0 + $1.count }
    }
    var blockCount: Int { leftBlocks.count + rightBlocks.count }

    mutating func append(_ other: CalibrationData) {
        leftBlocks += other.leftBlocks
        rightBlocks += other.rightBlocks
        peaks += other.peaks
    }
}

struct Profile: Codable, Identifiable {
    var id: String { name }
    var name: String
    var direction: DirectionModel?
    var rhythm: KnockRhythm?
    var calibration: CalibrationData?
    /// Raw pair gaps behind the rhythm, so more can be added later.
    var rhythmGapsMS: [Double]?
    var created: Date
    var lastUsed: Date

    var summary: String {
        var bits: [String] = []
        if let d = direction {
            bits.append(String(format: "direction %.0f%%", d.trainingAccuracy * 100))
            bits.append(String(format: "%.0f mg", d.suggestedMinAccelG * 1000))
        } else {
            bits.append("no direction")
        }
        if let r = rhythm {
            bits.append(String(format: "rhythm %.0f ms", r.meanGapMS))
        } else {
            bits.append("no rhythm")
        }
        if let c = calibration, c.knockCount > 0 {
            bits.append("\(c.knockCount) knocks")
        }
        return bits.joined(separator: " · ")
    }

    mutating func forgetDirectionCalibration() {
        direction = nil
        calibration = nil
    }

    mutating func forgetRhythmCalibration() {
        rhythm = nil
        rhythmGapsMS = nil
    }
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [Profile] = []
    @Published var activeName: String? {
        didSet { UserDefaults.standard.set(activeName, forKey: "activeProfile") }
    }

    var active: Profile? { profiles.first { $0.name == activeName } }

    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("InvisiButton", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("profiles.json")
    }

    func load() {
        if let d = try? Data(contentsOf: Self.url),
           let p = try? JSONDecoder().decode([Profile].self, from: d) {
            profiles = p
        }
        activeName = UserDefaults.standard.string(forKey: "activeProfile")
        if active == nil { activeName = profiles.first?.name }
    }

    func save() {
        guard let d = try? JSONEncoder().encode(profiles) else { return }
        try? d.write(to: Self.url, options: .atomic)
    }

    @discardableResult
    func create(name: String) -> Profile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let unique = trimmed.isEmpty ? "Desk \(profiles.count + 1)" : trimmed
        if let existing = profiles.first(where: { $0.name == unique }) {
            activeName = existing.name
            return existing
        }
        let p = Profile(name: unique, direction: nil, rhythm: nil, calibration: nil,
                        rhythmGapsMS: nil, created: Date(), lastUsed: Date())
        profiles.append(p)
        activeName = p.name
        save()
        return p
    }

    func update(_ mutate: (inout Profile) -> Void) {
        guard let i = profiles.firstIndex(where: { $0.name == activeName }) else { return }
        mutate(&profiles[i])
        profiles[i].lastUsed = Date()
        save()
    }

    func delete(_ name: String) {
        profiles.removeAll { $0.name == name }
        if activeName == name { activeName = profiles.first?.name }
        save()
    }

    func rename(_ old: String, to new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !profiles.contains(where: { $0.name == trimmed }),
              let i = profiles.firstIndex(where: { $0.name == old }) else { return }
        profiles[i].name = trimmed
        if activeName == old { activeName = trimmed }
        save()
    }
}

/// Result of the short check run when returning to a desk.
struct VerifyResult {
    var correct: Int
    var total: Int
    var accuracy: Double { total > 0 ? Double(correct) / Double(total) : 0 }
    var verdict: String {
        switch accuracy {
        case 0.85...:    return "This profile still fits this desk."
        case 0.65..<0.85: return "Borderline. It will misfire sometimes — recalibrate if it annoys you."
        default:          return "This profile no longer fits. Recalibrate direction."
        }
    }
}
