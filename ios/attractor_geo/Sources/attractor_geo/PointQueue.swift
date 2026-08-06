import Foundation

/// The durable point queue. Enforces both ceilings on every write so the
/// database stays bounded even if uploading has been failing for days.
final class PointQueue {
    private let store: PointStore

    init(store: PointStore) {
        self.store = store
    }

    /// The one queue everything shares.
    ///
    /// The tracker writes while the uploader deletes, and two independent
    /// connections to the same file would leave that overlap to SQLite's file
    /// locking — losing writes to SQLITE_BUSY. One connection, one lock.
    static let shared: PointQueue? = PointStore(path: defaultPath())
        .map(PointQueue.init)

    /// The on-device location, alongside the app's other support files.
    static func defaultPath() -> String {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("attractor_geo.sqlite").path
    }

    @discardableResult
    func enqueue(
        _ point: GeoPointRow, maxPoints: Int, maxAgeDays: Int
    ) -> Bool {
        guard store.insert(point) else { return false }
        // The cutoff is measured from the incoming point rather than the wall
        // clock, so a device whose clock jumped cannot wipe a valid queue.
        let window = Int64(maxAgeDays) * 86_400_000
        store.deleteOlderThan(point.recordedAtMillis - window)
        if store.count() > maxPoints {
            store.trim(to: maxPoints)
        }
        return true
    }

    func oldest(limit: Int) -> [GeoPointRow] { store.oldest(limit: limit) }

    func drop(ids: [String]) { store.delete(ids: ids) }

    func count() -> Int { store.count() }

    /// Throws the whole queue away. For signing out: these points belong to
    /// whoever recorded them, and must not be uploaded by the next account on
    /// this device.
    func clear() { store.deleteAll() }
}
