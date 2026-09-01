import Foundation

@main
struct HardwareSupportTests {
    static func main() {
        assertUsable(.ok(accel: true, gyro: true), expected: true,
                     "both motion channels should be usable")
        assertUsable(.ok(accel: true, gyro: false), expected: false,
                     "accelerometer-only input cannot satisfy the detector")
        assertUsable(.ok(accel: false, gyro: true), expected: false,
                     "gyroscope-only input cannot satisfy the detector")
        assertUsable(.noSPUDriver, expected: false,
                     "missing sensor hardware should not be usable")
    }

    private static func assertUsable(_ support: HardwareSupport,
                                     expected: Bool,
                                     _ message: String) {
        guard support.isUsable == expected else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
}
