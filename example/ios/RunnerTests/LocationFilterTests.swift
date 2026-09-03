import XCTest

@testable import background_geo_tracker

/// Mirrors the Kotlin `LocationFilterTest` case for case. A case that exists on
/// one side and not the other is the two platforms drifting apart about which
/// fixes are real, which is what a shared policy exists to prevent.
final class LocationFilterTests: XCTestCase {

    private func makeFilter(
        accuracy: Double = 100,
        displacement: Double = 1,
        speed: Double = 60,
        noise: Double = 3
    ) -> LocationFilter {
        LocationFilter(
            accuracyThresholdMeters: accuracy,
            minDisplacementMeters: displacement,
            maxImpliedSpeedMps: speed,
            kalmanProcessNoiseMps: noise
        )
    }

    /// Moscow, and a second point 100 m north of it.
    private let lat = 55.751244
    private let lon = 37.618423
    private let latPlus100m = 55.752143

    private func accepted(
        _ verdict: LocationFilter.Verdict,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (lat: Double, lon: Double, accuracy: Double) {
        guard case let .accept(lat, lon, accuracy) = verdict else {
            XCTFail("expected accept, got \(verdict)", file: file, line: line)
            throw XCTSkip("rejected")
        }
        return (lat, lon, accuracy)
    }

    func testFirstFixOfASessionIsTakenAtFaceValue() throws {
        let verdict = makeFilter().apply(
            lat: lat, lon: lon, accuracy: 12, recordedAtMillis: 1_000
        )

        let accept = try accepted(verdict)
        XCTAssertEqual(accept.lat, lat, accuracy: 1e-9)
        XCTAssertEqual(accept.lon, lon, accuracy: 1e-9)
        // Not smoothed against anything, so the claim stands as made.
        XCTAssertEqual(accept.accuracy, 12, accuracy: 1e-9)
    }

    func testFixWorseThanTheAccuracyThresholdIsRejected() {
        let subject = makeFilter(accuracy: 100)

        let verdict = subject.apply(
            lat: lat, lon: lon, accuracy: 1500, recordedAtMillis: 1_000
        )

        guard case .reject = verdict else {
            return XCTFail("expected reject, got \(verdict)")
        }
    }

    func testThresholdRejectionDoesNotBecomeTheReferencePoint() throws {
        let subject = makeFilter(accuracy: 100)

        // A cell-tower fix arrives first and is thrown away. The GPS fix that
        // follows must be treated as the session's first, not measured against
        // the one that was discarded.
        _ = subject.apply(
            lat: lat, lon: lon, accuracy: 1500, recordedAtMillis: 1_000
        )
        let verdict = subject.apply(
            lat: latPlus100m, lon: lon, accuracy: 10, recordedAtMillis: 2_000
        )

        let accept = try accepted(verdict)
        XCTAssertEqual(accept.lat, latPlus100m, accuracy: 1e-9)
    }

    func testFixThatHasNotMovedFarEnoughIsRejected() {
        let subject = makeFilter(displacement: 10)
        _ = subject.apply(
            lat: lat, lon: lon, accuracy: 10, recordedAtMillis: 1_000
        )

        // Roughly 1 cm away.
        let verdict = subject.apply(
            lat: lat + 0.0000001,
            lon: lon,
            accuracy: 10,
            recordedAtMillis: 11_000
        )

        guard case .reject = verdict else {
            return XCTFail("expected reject, got \(verdict)")
        }
    }

    func testFixImplyingAnImpossibleSpeedIsRejected() {
        let subject = makeFilter(speed: 60)
        _ = subject.apply(lat: lat, lon: lon, accuracy: 10, recordedAtMillis: 0)

        // 100 m in a tenth of a second is 1000 m/s.
        let verdict = subject.apply(
            lat: latPlus100m, lon: lon, accuracy: 10, recordedAtMillis: 100
        )

        guard case .reject = verdict else {
            return XCTFail("expected reject, got \(verdict)")
        }
    }

    func testSameDisplacementOverAPlausibleIntervalIsAccepted() throws {
        let subject = makeFilter(speed: 60)
        _ = subject.apply(lat: lat, lon: lon, accuracy: 10, recordedAtMillis: 0)

        // The same 100 m, now over 10 seconds — a fast run, not a teleport.
        let verdict = subject.apply(
            lat: latPlus100m, lon: lon, accuracy: 10, recordedAtMillis: 10_000
        )

        _ = try accepted(verdict)
    }

    func testSpeedRejectionIsMeasuredAgainstTheRawPosition() throws {
        let subject = makeFilter(speed: 60)
        _ = subject.apply(lat: lat, lon: lon, accuracy: 10, recordedAtMillis: 0)
        _ = subject.apply(
            lat: latPlus100m, lon: lon, accuracy: 10, recordedAtMillis: 10_000
        )

        // Smoothing pulls the stored estimate back toward the first fix. If the
        // next fix were judged against that estimate rather than against the raw
        // position, continuing at the same real speed would start reading as an
        // impossible one.
        let verdict = subject.apply(
            lat: 55.753042, lon: lon, accuracy: 10, recordedAtMillis: 20_000
        )

        _ = try accepted(verdict)
    }

    func testSmoothingPullsAnUncertainFixTowardTheEstablishedPosition() throws {
        let subject = makeFilter(noise: 0.1)
        _ = subject.apply(lat: lat, lon: lon, accuracy: 5, recordedAtMillis: 0)

        // A 90 m fix 100 m away, ten seconds later — an interval the speed
        // check is comfortable with, so what is tested here is only the
        // smoothing. Barely believed, so the reported position lands nearer
        // where we were than where it claims.
        let accept = try accepted(
            subject.apply(
                lat: latPlus100m,
                lon: lon,
                accuracy: 90,
                recordedAtMillis: 10_000
            )
        )

        XCTAssertLessThan(accept.lat, (lat + latPlus100m) / 2)
        XCTAssertGreaterThan(accept.lat, lat)
    }

    func testConfidentFixMovesTheEstimateMostOfTheWay() throws {
        let subject = makeFilter(noise: 3)
        _ = subject.apply(lat: lat, lon: lon, accuracy: 50, recordedAtMillis: 0)

        // The mirror of the case above: a 3 m fix against a 50 m history is
        // believed, so the estimate goes nearly all the way to it.
        let accept = try accepted(
            subject.apply(
                lat: latPlus100m,
                lon: lon,
                accuracy: 3,
                recordedAtMillis: 10_000
            )
        )

        XCTAssertGreaterThan(accept.lat, (lat + latPlus100m) / 2)
    }

    func testReportedAccuracyTightensAsAgreeingFixesArrive() throws {
        let subject = makeFilter(noise: 0.1)
        let first = try accepted(
            subject.apply(lat: lat, lon: lon, accuracy: 20, recordedAtMillis: 0)
        )
        let second = try accepted(
            subject.apply(
                lat: lat + 0.0001,
                lon: lon,
                accuracy: 20,
                recordedAtMillis: 1_000
            )
        )
        let third = try accepted(
            subject.apply(
                lat: lat + 0.0002,
                lon: lon,
                accuracy: 20,
                recordedAtMillis: 2_000
            )
        )

        XCTAssertLessThan(second.accuracy, first.accuracy)
        XCTAssertLessThan(third.accuracy, second.accuracy)
    }

    func testZeroAccuracyClaimCannotFreezeTheEstimate() throws {
        let subject = makeFilter()
        _ = subject.apply(lat: lat, lon: lon, accuracy: 0, recordedAtMillis: 0)

        // Believing a zero-error claim absolutely would set the variance to 0
        // and make every later gain 0 — the estimate would never move again.
        let accept = try accepted(
            subject.apply(
                lat: latPlus100m,
                lon: lon,
                accuracy: 10,
                recordedAtMillis: 5_000
            )
        )

        XCTAssertGreaterThan(abs(accept.lat - lat), 1e-7)
    }

    func testResetForgetsTheSession() throws {
        let subject = makeFilter(displacement: 10)
        _ = subject.apply(
            lat: lat, lon: lon, accuracy: 10, recordedAtMillis: 1_000
        )

        subject.reset()

        // Without the reset this sits inside the displacement floor and is
        // rejected; after it, it is simply the first fix of a new session.
        let accept = try accepted(
            subject.apply(
                lat: lat, lon: lon, accuracy: 10, recordedAtMillis: 2_000
            )
        )
        XCTAssertEqual(accept.lat, lat, accuracy: 1e-9)
        XCTAssertEqual(accept.accuracy, 10, accuracy: 1e-9)
    }
}
