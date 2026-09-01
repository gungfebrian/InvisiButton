import Foundation

@main
@MainActor
struct BindingTests {
    static func main() {
        directionAvailable = true
        let offeredAreas = Set(Bindings.allGestures.map(\.area))

        guard offeredAreas == Set([.any, .left, .right]) else {
            let names = offeredAreas.map(\.rawValue).sorted().joined(separator: ", ")
            FileHandle.standardError.write(
                Data("FAIL: offered gesture areas were \(names)\n".utf8))
            exit(1)
        }

        let bindings = Bindings()
        let single = Gesture(count: 1)
        let double = Gesture(count: 2)
        bindings.map[single] = .shell(command: "single")
        bindings.map[double] = .shell(command: "double")

        require(bindings.action(for: single) == .none,
                "single-knock actions should be inactive by default")
        require(bindings.action(for: double) == .shell(command: "double"),
                "multi-knock actions should remain active")

        bindings.allowSingleKnockActions = true
        require(bindings.action(for: single) == .shell(command: "single"),
                "explicit opt-in should activate a saved single-knock action")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
}
