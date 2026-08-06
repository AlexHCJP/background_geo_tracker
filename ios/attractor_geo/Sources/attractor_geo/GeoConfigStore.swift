import Foundation

/// Everything the native tracker needs to keep working with no Dart isolate
/// alive: the upload policy, the auth headers, and whether a session is on.
final class GeoConfigStore {
    private let defaults = UserDefaults.standard
    private static let headersAccount = "upload_headers"
    private static let prefix = "attractor_geo."

    private func key(_ name: String) -> String { Self.prefix + name }

    func save(_ config: [String: Any]) {
        defaults.set(
            config["base_url"] as? String ?? "", forKey: key("base_url")
        )
        defaults.set(config["path"] as? String ?? "", forKey: key("path"))
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
        defaults.set(true, forKey: key("configured"))

        let headers = config["headers"] as? [String: String] ?? [:]
        if let data = try? JSONSerialization.data(withJSONObject: headers),
           let json = String(data: data, encoding: .utf8) {
            Keychain.set(json, account: Self.headersAccount)
        }

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

    private static let ownedKeys = [
        "base_url",
        "path",
        "distance_filter_meters",
        "min_interval_seconds",
        "batch_size",
        "upload_interval_seconds",
        "queue_max_points",
        "queue_max_age_days",
        "configured",
        "is_tracking",
        "auth_failed",
    ]

    var isConfigured: Bool { defaults.bool(forKey: key("configured")) }

    var baseUrl: String { defaults.string(forKey: key("base_url")) ?? "" }
    var path: String { defaults.string(forKey: key("path")) ?? "" }

    private func int(_ name: String, _ fallback: Int) -> Int {
        defaults.object(forKey: key(name)) == nil
            ? fallback
            : defaults.integer(forKey: key(name))
    }

    var distanceFilterMeters: Int { int("distance_filter_meters", 20) }
    var minIntervalSeconds: Int { int("min_interval_seconds", 10) }
    var batchSize: Int { int("batch_size", 50) }
    var uploadIntervalSeconds: Int { int("upload_interval_seconds", 60) }
    var queueMaxPoints: Int { int("queue_max_points", 20000) }
    var queueMaxAgeDays: Int { int("queue_max_age_days", 7) }

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

    var authFailed: Bool {
        get { defaults.bool(forKey: key("auth_failed")) }
        set { defaults.set(newValue, forKey: key("auth_failed")) }
    }
}
