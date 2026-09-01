// InvisiButton · T-028 · Action dispatch
//
// Actions run in the user's own process. There is no daemon (D-008), so the old
// rule that "the root daemon never executes user actions" is satisfied by there
// being no root daemon — but the spirit still holds: the detection path never
// touches the filesystem, spawns a process, or loads code. Dispatch is the only
// place any of that happens, and it happens only after a pattern is recognised.

import AppKit
import Foundation

enum Action: Codable, Equatable {
    case shortcut(name: String)          // Shortcuts.app
    case appleScript(source: String)
    case shell(command: String)
    case launchApp(bundleID: String)
    case mediaKey(MediaKey)
    case none

    /// Whether this action needs Accessibility / Input Monitoring.
    ///
    /// Only media keys do. That matters: D-008 removed every permission prompt
    /// from onboarding and D-021 removed the last reason to add one back, so
    /// media keys are the single action type that reintroduces a TCC dialog.
    /// They stay available, but a user who never binds one is never prompted.
    var requiresAccessibility: Bool {
        if case .mediaKey = self { return true }
        return false
    }

    var describe: String {
        switch self {
        case .shortcut(let n):    return "Run Shortcut “\(n)”"
        case .appleScript:        return "Run AppleScript"
        case .shell(let c):       return "Run: \(c.prefix(40))"
        case .launchApp(let b):   return "Open \(b)"
        case .mediaKey(let k):    return k.label
        case .none:               return "Do nothing"
        }
    }
}

enum MediaKey: Int, Codable, Equatable {
    case playPause = 16, next = 17, previous = 18, mute = 7,
         volumeUp = 0, volumeDown = 1

    var label: String {
        switch self {
        case .playPause: return "Play / Pause"
        case .next:      return "Next track"
        case .previous:  return "Previous track"
        case .mute:      return "Mute"
        case .volumeUp:  return "Volume up"
        case .volumeDown: return "Volume down"
        }
    }
}

enum ActionDispatcher {
    /// Fire and forget. Never blocks the caller; failures are reported, not thrown,
    /// because a failed action must not take the detector down with it.
    static func perform(_ action: Action, log: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            switch action {
            case .none:
                log("no action bound")

            case .shortcut(let name):
                run("/usr/bin/shortcuts", ["run", name], log: log)

            case .appleScript(let src):
                var err: NSDictionary?
                _ = NSAppleScript(source: src)?.executeAndReturnError(&err)
                log(err == nil ? "AppleScript ran" : "AppleScript failed: \(err!)")

            case .shell(let cmd):
                run("/bin/sh", ["-c", cmd], log: log)

            case .launchApp(let bundleID):
                guard let url = NSWorkspace.shared
                        .urlForApplication(withBundleIdentifier: bundleID) else {
                    log("no application with bundle id \(bundleID)")
                    return
                }
                NSWorkspace.shared.openApplication(at: url,
                                                   configuration: .init()) { _, e in
                    log(e == nil ? "opened \(bundleID)" : "open failed: \(e!)")
                }

            case .mediaKey(let key):
                postMediaKey(key)
                log("sent \(key.label)")
            }
        }
    }

    private static func run(_ path: String, _ args: [String],
                            log: @escaping (String) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let e = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                               encoding: .utf8) ?? ""
                log("\(path) exited \(p.terminationStatus): \(e.prefix(120))")
            } else {
                log("ran \(args.joined(separator: " "))")
            }
        } catch {
            log("could not run \(path): \(error.localizedDescription)")
        }
    }

    /// Media keys are NX system-defined events. Posting them needs Accessibility;
    /// every other action type does not.
    private static func postMediaKey(_ key: MediaKey) {
        for down in [true, false] {
            let flags: NSEvent.ModifierFlags = down ? .init(rawValue: 0xA00) : .init(rawValue: 0xB00)
            let data1 = Int((key.rawValue << 16) | ((down ? 0xA : 0xB) << 8))
            guard let ev = NSEvent.otherEvent(with: .systemDefined,
                                              location: .zero,
                                              modifierFlags: flags,
                                              timestamp: 0,
                                              windowNumber: 0,
                                              context: nil,
                                              subtype: 8,
                                              data1: data1,
                                              data2: -1),
                  let cg = ev.cgEvent else { continue }
            cg.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Gesture binding

enum Area: String, Codable, CaseIterable, Hashable {
    case any, left, right, front

    /// Areas the direction model can actually classify. `front` remains a
    /// decoding case so older bindings files still load, but it is not offered
    /// for new bindings until a three-way model exists.
    static let bindable: [Area] = [.left, .right]

    var label: String {
        switch self {
        case .any:   return "anywhere"
        case .left:  return "left of the laptop"
        case .right: return "right of the laptop"
        case .front: return "in front"
        }
    }
    var short: String { self == .any ? "anywhere" : rawValue }
}

struct Gesture: Codable, Equatable, Hashable {
    var count: Int                 // 1, 2, 3
    var area: Area = .any

    var describe: String {
        let n = ["", "Single", "Double", "Triple"][min(count, 3)]
        return area == .any ? "\(n) knock" : "\(n) knock, \(area.short)"
    }
}

/// Whether knock *location* can be used as a binding dimension.
///
/// False, and it must stay false until T-016 passes. D-020 established that left
/// and right separate within a desk (p = 0.016 and 0.029 on two desks) but
/// cross-desk transfer is unestablished, and the detection pipeline does not
/// compute direction at all yet. HANDOFF.md: "Do not build UI around direction
/// before T-016 passes." The UI shows the dimension and disables it, rather than
/// offering a control that silently does nothing.
/// Set once a per-desk direction model has been calibrated. Until then the area
/// dimension is shown and disabled rather than silently doing nothing.
@MainActor var directionAvailable = false

@MainActor
final class Bindings: ObservableObject {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("InvisiButton", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("bindings.json")
    }

    struct Entry: Codable { var gesture: Gesture; var action: Action }

    func save() {
        let list = map.map { Entry(gesture: $0.key, action: $0.value) }
        guard let d = try? JSONEncoder().encode(list) else { return }
        try? d.write(to: Self.fileURL, options: .atomic)
    }

    func load() {
        guard let d = try? Data(contentsOf: Self.fileURL),
              let list = try? JSONDecoder().decode([Entry].self, from: d) else { return }
        var m: [Gesture: Action] = [:]
        for e in list { m[e.gesture] = e.action }
        if !m.isEmpty { map = m }
    }

    /// Every gesture the UI offers a row for.
    @MainActor
    static var allGestures: [Gesture] {
        var out: [Gesture] = []
        for c in 1...3 {
            out.append(Gesture(count: c, area: .any))
            if directionAvailable {
                for a in Area.bindable {
                    out.append(Gesture(count: c, area: a))
                }
            }
        }
        return out
    }
    /// Everything is unbound by default, deliberately.
    ///
    /// The detector currently produces roughly 390 false positives an hour
    /// (RESEARCH.md nineteenth pass). Shipping a default binding at that rate
    /// would fire actions the user did not ask for, which Product Principle 1
    /// calls trust-ending. Nothing is bound until the Phase 1 gate is met and
    /// the user chooses a binding themselves.
    @Published var map: [Gesture: Action] = [
        Gesture(count: 1, area: .any): .none,
        Gesture(count: 2, area: .any): .none,
        Gesture(count: 3, area: .any): .none,
    ]

    /// Exact match first, then fall back to the area-agnostic binding.
    func action(for g: Gesture) -> Action {
        map[g] ?? map[Gesture(count: g.count, area: .any)] ?? .none
    }
}
