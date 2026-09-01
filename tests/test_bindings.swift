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
    }
}
