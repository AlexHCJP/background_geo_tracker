import XCTest

@testable import background_geo_tracker

final class GeoConfigStoreTests: XCTestCase {
    private var config: GeoConfigStore!

    /// Stands in for a setting belonging to the host app. The store shares
    /// `UserDefaults.standard` with whoever embeds the plugin, so clearing has
    /// to be surgical.
    private let foreignKey = "host_app.some_setting"

    private let saved: [String: Any] = [
        "base_url": "https://api.attractor.school",
        "path": "/v1/tracking/points",
        "headers": ["Authorization": "Bearer secret"],
        "distance_filter_meters": 20,
        "min_interval_seconds": 10,
        "batch_size": 50,
        "upload_interval_seconds": 60,
        "queue_max_points": 20000,
        "queue_max_age_days": 7,
    ]

    override func setUp() {
        super.setUp()
        config = GeoConfigStore()
    }

    override func tearDown() {
        config.clear()
        UserDefaults.standard.removeObject(forKey: foreignKey)
        super.tearDown()
    }

    func testClearForgetsTheCredentials() {
        config.save(saved)
        XCTAssertEqual(config.headers["Authorization"], "Bearer secret")

        config.clear()

        XCTAssertTrue(config.headers.isEmpty)
    }

    func testClearForgetsTheSessionAndTheEndpoint() {
        config.save(saved)
        config.isTracking = true
        config.authFailed = true

        config.clear()

        XCTAssertFalse(config.isConfigured)
        XCTAssertFalse(config.isTracking)
        XCTAssertFalse(config.authFailed)
        XCTAssertEqual(config.baseUrl, "")
    }

    func testClearLeavesTheHostAppsOwnDefaultsAlone() {
        UserDefaults.standard.set("keep me", forKey: foreignKey)
        config.save(saved)

        config.clear()

        XCTAssertEqual(
            UserDefaults.standard.string(forKey: foreignKey), "keep me"
        )
    }

    func testTuningFallsBackToTheDefaultsAfterAClear() {
        config.save(saved)

        config.clear()

        XCTAssertEqual(config.batchSize, 50)
        XCTAssertEqual(config.queueMaxPoints, 20000)
    }
}
