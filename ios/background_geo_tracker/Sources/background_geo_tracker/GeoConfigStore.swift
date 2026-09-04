import Foundation

/// Everything the native tracker needs to keep working with no Dart isolate
/// alive: the upload policy, the auth headers, and whether a session is on.
final class GeoConfigStore {
    private let defaults = UserDefaults.standard
    private static let headersAccount = "upload_headers"
    private static let prefix = "attractor_geo."

    private func key(_ name: String) -> String { Self.prefix + name }

    func save(_ config: [String: Any]) throws {
        try validate(config)
        let headers = config["headers"] as? [String: String] ?? [:]
        guard let data = try? JSONSerialization.data(withJSONObject: headers),
              let json = String(data: data, encoding: .utf8),
              Keychain.set(json, account: Self.headersAccount)
        else {
            throw GeoConfigError.invalid(
                "secure credential storage is unavailable"
            )
        }

        defaults.set(
            config["session_id"] as? String ?? "", forKey: key("session_id")
        )
        defaults.set(config["url"] as? String ?? "", forKey: key("url"))
        defaults.set(
            config["distance_filter_meters"] as? Int ?? 20,
            forKey: key("distance_filter_meters")
        )
        defaults.set(
            config["min_interval_seconds"] as? Int ?? 10,
            forKey: key("min_interval_seconds")
        )
        defaults.set(
            config["batch_size"] as? Int ?? 50, forKey: key("batch_size")
        )
        defaults.set(
            config["send_after_points"] as? Int
                ?? config["batch_size"] as? Int ?? 50,
            forKey: key("send_after_points")
        )
        defaults.set(
            config["upload_interval_seconds"] as? Int ?? 60,
            forKey: key("upload_interval_seconds")
        )
        defaults.set(
            config["queue_max_points"] as? Int ?? 20000,
            forKey: key("queue_max_points")
        )
        defaults.set(
            config["queue_max_age_days"] as? Int ?? 7,
            forKey: key("queue_max_age_days")
        )
        for (name, fallback) in Self.filterDefaults {
            // `as? Double` alone would miss a whole number, which the codec
            // hands over as Int — a `filter_min_displacement_meters: 1` from
            // Dart would then silently fall back instead of being honoured.
            let value = (config[name] as? Double)
                ?? (config[name] as? NSNumber)?.doubleValue
                ?? fallback
            defaults.set(value, forKey: key(name))
        }
        defaults.set(
            config["motion_stop_timeout_seconds"] as? Int ?? 300,
            forKey: key("motion_stop_timeout_seconds")
        )
        for (name, fallback) in Self.motionDefaults {
            // Same reason as the filter loop above: the codec hands a whole
            // number over as Int, and `as? Double` alone would miss a
            // `motion_elasticity_multiplier: 1` from Dart.
            let value = (config[name] as? Double)
                ?? (config[name] as? NSNumber)?.doubleValue
                ?? fallback
            defaults.set(value, forKey: key(name))
        }
        defaults.set(true, forKey: key("configured"))

        // Fresh credentials are the recovery path out of a 401.
        authFailed = false
    }

    /// Forgets the session and the credentials.
    ///
    /// Keys are removed one by one rather than by wiping the suite: these
    /// defaults are the host app's, and clearing it wholesale would take the
    /// app's own settings with them.
    func clear() {
        for name in Self.ownedKeys {
            defaults.removeObject(forKey: key(name))
        }
        Keychain.delete(account: Self.headersAccount)
    }

    /// The filter knobs and what they are worth when nobody said. Kept as one
    /// list because every place that touches them touches all four.
    static let filterDefaults: [(String, Double)] = [
        ("filter_accuracy_threshold_meters", 100),
        ("filter_min_displacement_meters", 1),
        ("filter_max_implied_speed_mps", 60),
        ("filter_kalman_process_noise_mps", 3),
    ]

    /// The motion knobs that are doubles, and what they are worth when nobody
    /// said. `motion_stop_timeout_seconds` is an Int and lives beside them.
    static let motionDefaults: [(String, Double)] = [
        ("motion_stationary_radius_meters", 150),
        ("motion_elasticity_multiplier", 1),
    ]

    private static let ownedKeys = [
        "session_id",
        "url",
        "distance_filter_meters",
        "min_interval_seconds",
        "batch_size",
        "send_after_points",
        "upload_interval_seconds",
        "queue_max_points",
        "queue_max_age_days",
        "configured",
        "is_tracking",
        "auth_failed",
        "last_upload",
        "motion_stop_timeout_seconds",
        "is_moving",
    ] + filterDefaults.map(\.0) + motionDefaults.map(\.0)

    var isConfigured: Bool { defaults.bool(forKey: key("configured")) }

    var sessionId: String {
        defaults.string(forKey: key("session_id")) ?? ""
    }

    /// The whole endpoint, as the Dart side wrote it down. Not assembled from
    /// parts here — see `GeoUploadConfig.url`.
    var url: String { defaults.string(forKey: key("url")) ?? "" }

    private func int(_ name: String, _ fallback: Int) -> Int {
        defaults.object(forKey: key(name)) == nil
            ? fallback
            : defaults.integer(forKey: key(name))
    }

    var distanceFilterMeters: Int { int("distance_filter_meters", 20) }
    var minIntervalSeconds: Int { int("min_interval_seconds", 10) }
    var batchSize: Int { int("batch_size", 50) }

    /// How many queued points make an arriving point send a request. Falls
    /// back to `batchSize`, which is what this used to be half of.
    var sendAfterPoints: Int { int("send_after_points", batchSize) }
    var uploadIntervalSeconds: Int { int("upload_interval_seconds", 60) }
    var queueMaxPoints: Int { int("queue_max_points", 20000) }
    var queueMaxAgeDays: Int { int("queue_max_age_days", 7) }

    private func double(_ name: String, _ fallback: Double) -> Double {
        defaults.object(forKey: key(name)) == nil
            ? fallback
            : defaults.double(forKey: key(name))
    }

    var filterAccuracyThresholdMeters: Double {
        double("filter_accuracy_threshold_meters", 100)
    }
    var filterMinDisplacementMeters: Double {
        double("filter_min_displacement_meters", 1)
    }
    var filterMaxImpliedSpeedMps: Double {
        double("filter_max_implied_speed_mps", 60)
    }
    var filterKalmanProcessNoiseMps: Double {
        double("filter_kalman_process_noise_mps", 3)
    }

    var motionStopTimeoutSeconds: Int { int("motion_stop_timeout_seconds", 300) }
    var motionStationaryRadiusMeters: Double {
        double("motion_stationary_radius_meters", 150)
    }
    var motionElasticityMultiplier: Double {
        double("motion_elasticity_multiplier", 1)
    }

    var headers: [String: String] {
        guard let json = Keychain.get(account: Self.headersAccount),
              let data = json.data(using: .utf8),
              let map = try? JSONSerialization.jsonObject(with: data)
                as? [String: String]
        else { return [:] }
        return map
    }

    /// Persisted so a session survives process death and relaunch.
    var isTracking: Bool {
        get { defaults.bool(forKey: key("is_tracking")) }
        set { defaults.set(newValue, forKey: key("is_tracking")) }
    }

    /// Whether the collector is currently asking for fixes. Persisted for the
    /// same reason `isTracking` is: the answer has to outlive the process that
    /// decided it. True by default — a session that has never stopped is moving.
    var isMoving: Bool {
        get {
            defaults.object(forKey: key("is_moving")) == nil
                ? true
                : defaults.bool(forKey: key("is_moving"))
        }
        set { defaults.set(newValue, forKey: key("is_moving")) }
    }

    var authFailed: Bool {
        get { defaults.bool(forKey: key("auth_failed")) }
        set { defaults.set(newValue, forKey: key("auth_failed")) }
    }

    /// How the last drain attempt ended. Kept here rather than on the uploader
    /// because it is written on the uploader's serial queue and read from the
    /// main one, and `UserDefaults` is the store this package already trusts
    /// across threads. Persisting it is a bonus: the answer survives the
    /// process, so a drain that failed in the background is still there to
    /// read when the app is next opened.
    var lastUpload: String {
        get { defaults.string(forKey: key("last_upload")) ?? "never" }
        set { defaults.set(newValue, forKey: key("last_upload")) }
    }

    private func validate(_ value: [String: Any]) throws {
        guard let sessionId = value["session_id"] as? String,
              !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw GeoConfigError.invalid("session_id must not be empty") }

        guard let rawUrl = value["url"] as? String,
              let components = URLComponents(string: rawUrl),
              components.scheme == "https",
              !(components.host ?? "").isEmpty,
              components.fragment == nil
        else {
            throw GeoConfigError.invalid(
                "url must be an absolute HTTPS URL without a fragment"
            )
        }
        guard let distance = value["distance_filter_meters"] as? Int,
              distance >= 0
        else {
            throw GeoConfigError.invalid(
                "distance_filter_meters must be zero or greater"
            )
        }
        for key in [
            "min_interval_seconds", "batch_size", "upload_interval_seconds",
            "queue_max_points", "queue_max_age_days",
        ] {
            guard let number = value[key] as? Int, number > 0 else {
                throw GeoConfigError.invalid("\(key) must be greater than zero")
            }
        }
        guard let headers = value["headers"] as? [String: String],
              headers.keys.allSatisfy({ !$0.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty })
        else { throw GeoConfigError.invalid("headers must be a string map") }
    }
}

private enum GeoConfigError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}
