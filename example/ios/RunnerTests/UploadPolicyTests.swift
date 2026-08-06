import XCTest

@testable import background_geo_tracker

final class UploadPolicyTests: XCTestCase {
    func testSuccessRange() {
        XCTAssertEqual(UploadPolicy.classify(200), .success)
        XCTAssertEqual(UploadPolicy.classify(201), .success)
        XCTAssertEqual(UploadPolicy.classify(204), .success)
    }

    func testUnauthorizedHaltsUploading() {
        XCTAssertEqual(UploadPolicy.classify(401), .authFailed)
    }

    func testTimeoutAndRateLimitAreRetried() {
        XCTAssertEqual(UploadPolicy.classify(408), .retry)
        XCTAssertEqual(UploadPolicy.classify(429), .retry)
    }

    func testOtherClientErrorsArePoisoned() {
        XCTAssertEqual(UploadPolicy.classify(400), .poisoned)
        XCTAssertEqual(UploadPolicy.classify(403), .poisoned)
        XCTAssertEqual(UploadPolicy.classify(422), .poisoned)
    }

    func testServerErrorsAreRetried() {
        XCTAssertEqual(UploadPolicy.classify(500), .retry)
        XCTAssertEqual(UploadPolicy.classify(503), .retry)
    }

    func testAttemptIsAllowedWhenNothingHasFailed() {
        XCTAssertTrue(
            UploadPolicy.mayAttempt(now: Date(), notBefore: nil)
        )
    }

    // The periodic drain runs on its own schedule and knows nothing about a
    // backoff in progress. Without this gate a backend that is down would be
    // hit every upload interval no matter what the backoff computed.
    func testAttemptIsRefusedUntilTheBackoffHasElapsed() {
        let now = Date()

        XCTAssertFalse(
            UploadPolicy.mayAttempt(
                now: now, notBefore: now.addingTimeInterval(30)
            )
        )
    }

    func testAttemptIsAllowedOnceTheBackoffHasElapsed() {
        let now = Date()

        XCTAssertTrue(
            UploadPolicy.mayAttempt(
                now: now, notBefore: now.addingTimeInterval(-1)
            )
        )
        XCTAssertTrue(UploadPolicy.mayAttempt(now: now, notBefore: now))
    }

    func testBackoffGrowsAndIsCapped() {
        XCTAssertEqual(UploadPolicy.backoffSeconds(attempt: 0), 30)
        XCTAssertEqual(UploadPolicy.backoffSeconds(attempt: 1), 60)
        XCTAssertEqual(UploadPolicy.backoffSeconds(attempt: 2), 120)
        XCTAssertEqual(UploadPolicy.backoffSeconds(attempt: 20), 3600)
        XCTAssertLessThanOrEqual(
            UploadPolicy.backoffSeconds(attempt: 100), 3600
        )
    }
}

extension UploadOutcome: @retroactive Equatable {}
