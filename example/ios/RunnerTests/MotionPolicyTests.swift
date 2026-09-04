import XCTest

@testable import background_geo_tracker

final class MotionPolicyTests: XCTestCase {
    private func policy(
        stopTimeoutSeconds: Int = 300,
        stationaryRadiusMeters: Double = 150,
        elasticityMultiplier: Double = 1,
        base: Double = 20
    ) -> MotionPolicy {
        MotionPolicy(
            stopTimeoutSeconds: stopTimeoutSeconds,
            stationaryRadiusMeters: stationaryRadiusMeters,
            elasticityMultiplier: elasticityMultiplier,
            baseDistanceFilterMeters: base
        )
    }

    /// ~0.0009° of latitude is ~100 m; the anchor sits at (0, 0).
    private let hundredMeters = 0.0009
    private let fiveHundredMeters = 0.0045

    func testShortSilenceKeepsCollecting() {
        let p = policy()
        _ = p.onFix(lat: 0, lon: 0, speedMps: 0, atMillis: 0)
        guard case .keepGoing = p.onFix(lat: 0, lon: 0, speedMps: 0, atMillis: 299_000)
        else { return XCTFail("expected to keep collecting") }
        XCTAssertTrue(p.isMoving)
    }

    func testSilencePastTheTimeoutStops() {
        let p = policy()
        _ = p.onFix(lat: 0, lon: 0, speedMps: 0, atMillis: 0)
        guard case let .stop(_, _, radius, still) =
            p.onFix(lat: 0, lon: 0, speedMps: 0, atMillis: 300_000)
        else { return XCTFail("expected a stop") }
        XCTAssertEqual(radius, 150)
        XCTAssertEqual(still, 300)
        XCTAssertFalse(p.isMoving)
    }

    func testAFixBeyondTheRadiusRestartsTheCount() {
        let p = policy()
        _ = p.onFix(lat: 0, lon: 0, speedMps: 0, atMillis: 0)
        _ = p.onFix(lat: fiveHundredMeters, lon: 0, speedMps: 1.4, atMillis: 240_000)
        guard case .keepGoing =
            p.onFix(lat: fiveHundredMeters, lon: 0, speedMps: 0, atMillis: 400_000)
        else { return XCTFail("expected the count to restart") }
    }

    func testDriftInsideTheRadiusDoesNotRestartTheCount() {
        let p = policy()
        _ = p.onFix(lat: 0, lon: 0, speedMps: 0, atMillis: 0)
        _ = p.onFix(lat: hundredMeters, lon: 0, speedMps: 0, atMillis: 200_000)
        guard case .stop = p.onFix(lat: 0, lon: 0, speedMps: 0, atMillis: 301_000)
        else { return XCTFail("a wandering fix must not hold the GPS on") }
    }

    func testAZeroTimeoutSwitchesStopDetectionOff() {
        let p = policy(stopTimeoutSeconds: 0)
        _ = p.onFix(lat: 0, lon: 0, speedMps: 0, atMillis: 0)
        guard case .keepGoing =
            p.onFix(lat: 0, lon: 0, speedMps: 0, atMillis: 86_400_000)
        else { return XCTFail("zero means off, not stop immediately") }
        XCTAssertTrue(p.isMoving)
    }

    func testADetectorWakesThePolicyExactlyOnce() {
        let p = policy()
        _ = p.onFix(lat: 0, lon: 0, speedMps: 0, atMillis: 0)
        _ = p.onFix(lat: 0, lon: 0, speedMps: 0, atMillis: 300_000)
        XCTAssertTrue(p.onMovementDetected(atMillis: 310_000))
        XCTAssertFalse(p.onMovementDetected(atMillis: 311_000))
    }

    func testAStrayFixDoesNotResumeTheSession() {
        let p = policy()
        _ = p.onFix(lat: 0, lon: 0, speedMps: 0, atMillis: 0)
        _ = p.onFix(lat: 0, lon: 0, speedMps: 0, atMillis: 300_000)
        _ = p.onFix(lat: 0, lon: 0, speedMps: 0, atMillis: 301_000)
        XCTAssertFalse(p.isMoving)
    }

    func testElasticity() {
        let p = policy()
        XCTAssertEqual(p.distanceFilterFor(speedMps: 0), 20)
        XCTAssertEqual(p.distanceFilterFor(speedMps: 1.39), 20)
        XCTAssertEqual(p.distanceFilterFor(speedMps: 25), 357.142857, accuracy: 0.01)
        XCTAssertEqual(p.distanceFilterFor(speedMps: 300), MotionPolicy.elasticityMaxMeters)
    }

    func testAZeroMultiplierSwitchesStretchingOff() {
        let p = policy(elasticityMultiplier: 0)
        XCTAssertEqual(p.distanceFilterFor(speedMps: 25), 20)
        XCTAssertEqual(p.steppedDistanceFilterFor(speedMps: 25), 20)
    }

    func testStepsAreMultiplesOfTheBase() {
        let p = policy()
        XCTAssertEqual(p.steppedDistanceFilterFor(speedMps: 25), 200)
        XCTAssertEqual(p.steppedDistanceFilterFor(speedMps: 1), 20)
        XCTAssertEqual(p.steppedDistanceFilterFor(speedMps: 3), 40)
    }

    func testNeighbouringSpeedsInsideOneStepChangeNothing() {
        let p = policy()
        guard case let .keepGoing(_, firstStep, firstChanged) =
                p.onFix(lat: 0, lon: 0, speedMps: 25, atMillis: 0),
              case let .keepGoing(_, _, secondChanged) =
                p.onFix(lat: hundredMeters, lon: 0, speedMps: 26, atMillis: 10_000),
              case let .keepGoing(_, thirdStep, thirdChanged) =
                p.onFix(lat: fiveHundredMeters, lon: 0, speedMps: 1, atMillis: 20_000)
        else { return XCTFail("expected three keepGoing decisions") }
        XCTAssertEqual(firstStep, 200)
        XCTAssertTrue(firstChanged)
        XCTAssertFalse(secondChanged)
        XCTAssertEqual(thirdStep, 20)
        XCTAssertTrue(thirdChanged)
    }

    func testResetForgetsThePreviousSession() {
        let p = policy()
        _ = p.onFix(lat: 0, lon: 0, speedMps: 0, atMillis: 0)
        _ = p.onFix(lat: 0, lon: 0, speedMps: 0, atMillis: 300_000)
        p.reset()
        XCTAssertTrue(p.isMoving)
        guard case .keepGoing = p.onFix(lat: 0, lon: 0, speedMps: 0, atMillis: 400_000)
        else { return XCTFail("the old anchor should be gone") }
    }
}
