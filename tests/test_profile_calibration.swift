import Foundation

// DirectionModel's public behavior only needs these two cases in this focused
// test target; the app's full Area type lives in ActionDispatcher.swift.
enum Area { case left, right }

@main
struct ProfileCalibrationTests {
    static func main() {
        let model = DirectionModel(
            version: DirectionModel.currentVersion,
            template: [1.0],
            threshold: 0,
            trainingAccuracy: 1,
            leftCount: 1,
            rightCount: 1,
            deskLabel: "test",
            createdAt: Date(),
            leftMean: [1.0],
            rightMean: [-1.0]
        )
        let rhythm = KnockRhythm(meanGapMS: 300, sdGapMS: 20, samples: 8)
        let calibration = CalibrationData(
            leftBlocks: [[[1.0]]],
            rightBlocks: [[[-1.0]]],
            peaks: [0.1, 0.1]
        )
        var profile = Profile(
            name: "Desk",
            direction: model,
            rhythm: rhythm,
            calibration: calibration,
            rhythmGapsMS: [280, 300, 320],
            created: Date(),
            lastUsed: Date()
        )

        profile.forgetDirectionCalibration()
        require(profile.direction == nil, "direction model should be removed")
        require(profile.calibration == nil, "raw direction calibration should be removed")
        require(profile.rhythm != nil, "forgetting direction should preserve rhythm")

        profile.direction = model
        profile.calibration = calibration
        profile.forgetRhythmCalibration()
        require(profile.rhythm == nil, "rhythm should be removed")
        require(profile.rhythmGapsMS == nil, "raw rhythm gaps should be removed")
        require(profile.direction != nil, "forgetting rhythm should preserve direction")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
}
