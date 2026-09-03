import Foundation
import Network
import UIKit

/// Drains the queue in batches. Runs in-process: while a session is active
/// CoreLocation keeps the app alive in the background, so a plain URLSession
/// request completes. A request still in flight when the app is suspended is
/// abandoned and its points simply stay queued for the next drain.
final class Uploader {
    static let shared = Uploader()

    private let config = GeoConfigStore()
    private var queue: PointQueue? { PointQueue.shared }
    private let session = URLSession(configuration: .default)
    private let serial = DispatchQueue(label: "school.attractor.geo.upload")

    private var draining = false
    private var attempt = 0
    private var timer: DispatchSourceTimer?

    /// Wakes the drain the moment a network comes back.
    ///
    /// iOS has nothing equivalent to Android's job constraint, so without this
    /// a phone coming out of the underground waits out the rest of the sweep
    /// interval with a full queue and a working connection.
    private var networks: NWPathMonitor?

    /// When the next attempt is allowed after a failure. Only touched on
    /// [serial].
    private var notBefore: Date?

    private init() {}

    /// Forgets the session: no timer, no backoff, no in-flight bookkeeping.
    /// Used when signing out, alongside emptying the queue.
    func reset() {
        stopPeriodicDrain()
        serial.async { [weak self] in
            self?.draining = false
            self?.attempt = 0
            self?.notBefore = nil
        }
    }

    /// Starts the sweep that sends a half-full batch, and sweeps once now.
    ///
    /// Safe to call as often as the host likes, which matters because it is
    /// called on every launch and every return to the foreground. It used to
    /// cancel and rebuild the timer each time, and a rebuilt timer starts its
    /// interval over: a reader who opens the app, glances at it and closes it
    /// again would push the next sweep a full interval further away every
    /// time, and the points would sit in the queue indefinitely. An already
    /// running sweep is therefore left exactly as it is.
    ///
    /// The immediate attempt is the other half of the same problem. A queue
    /// that survived the last run has already waited; making it wait out a
    /// fresh interval on top — while the app is open and on a network, which
    /// is the best moment it will get — is the wrong way round.
    func startPeriodicDrain() {
        if timer == nil {
            // A zero interval would spin the timer flat out; the floor keeps a
            // bad config from turning into a battery fire.
            let interval = max(1, config.uploadIntervalSeconds)
            let timer = DispatchSource.makeTimerSource(queue: serial)
            timer.schedule(
                deadline: .now() + .seconds(interval),
                repeating: .seconds(interval)
            )
            timer.setEventHandler { [weak self] in
                self?.drainIfNeeded(force: true)
            }
            timer.resume()
            self.timer = timer

            // Same lifetime as the sweep, deliberately: a monitor outliving
            // the session would wake a drain for a session that is over.
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                guard path.status == .satisfied else { return }
                GeoLogStore.shared?.write(
                    atMillis: Int64(Date().timeIntervalSince1970 * 1000),
                    level: "info",
                    event: "connectivity.available",
                    message: "queue depth=\(PointQueue.shared?.count() ?? 0)"
                )
                self?.drainIfNeeded(force: true)
            }
            monitor.start(queue: serial)
            networks = monitor
        }
        drainIfNeeded(force: true)
    }

    func stopPeriodicDrain() {
        timer?.cancel()
        timer = nil
        networks?.cancel()
        networks = nil
    }

    /// `force` bypasses the send threshold — used by the periodic timer so a
    /// half-full batch still goes out.
    func drainIfNeeded(force: Bool) {
        serial.async { [weak self] in
            guard let self else { return }
            // Each guard below ends a drain, and each used to end it in
            // silence. A queue that grows while the collector reports itself
            // healthy is the symptom of every one of them, so the reason has
            // to survive the return — see `GeoTrackingStatus.lastUpload`.
            guard let queue = self.queue else {
                self.config.lastUpload = "no queue — storage unavailable"
                return
            }
            guard self.config.isConfigured else {
                self.config.lastUpload = "not configured"
                return
            }
            guard !self.config.authFailed else {
                self.config.lastUpload = "halted: credentials refused"
                return
            }
            // These two record nothing on purpose: they are the states of a
            // drain that is working — one in flight, one waiting out a
            // backoff — and writing them would overwrite the outcome that
            // caused the wait, which is the part worth reading.
            guard !self.draining else { return }
            guard UploadPolicy.mayAttempt(
                now: Date(), notBefore: self.notBefore
            ) else { return }
            // The threshold, not the batch size: `sendNextBatch` still takes
            // `batchSize` points, so a low threshold buys freshness without
            // making a backlog leave one point per round trip.
            guard force || queue.count() >= self.config.sendAfterPoints else {
                // Only while nothing has ever been sent. This is the ordinary
                // state between sweeps and it arrives with every point, so
                // writing it unconditionally would bury the outcome of the
                // last real attempt under it seconds later — and that outcome
                // is the whole reason this field exists. It is worth saying
                // exactly once: on an uploader that has never run, `never`
                // alone cannot be told from one that is broken.
                if self.config.lastUpload == "never" {
                    self.config.lastUpload =
                        "waiting for a sweep — \(queue.count())/\(self.config.sendAfterPoints)"
                }
                return
            }
            self.draining = true
            self.sendNextBatch()
        }
    }

    private func sendNextBatch() {
        guard let queue else {
            draining = false
            return
        }

        let batch = queue.oldest(
            limit: config.batchSize,
            nowMillis: Int64(Date().timeIntervalSince1970 * 1000)
        )
        guard !batch.isEmpty else {
            draining = false
            attempt = 0
            return
        }

        guard let url = URL(string: config.url) else {
            // The one failure with no network in it and no way to notice from
            // outside: the collector goes on filling a queue that can never be
            // posted anywhere. Recorded so the status says so.
            let reason = config.url.isEmpty
                ? "no url — never configured"
                : "bad url: \(config.url)"
            config.lastUpload = reason
            GeoLogStore.shared?.write(
                atMillis: Int64(Date().timeIntervalSince1970 * 1000),
                level: "warning", event: "upload.giveup", message: reason
            )
            draining = false
            return
        }

        let startedAt = Date()
        GeoLogStore.shared?.write(
            atMillis: Int64(startedAt.timeIntervalSince1970 * 1000),
            level: "info",
            event: "upload.attempt",
            message: "\(batch.count) points → \(config.url)"
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = PointJson.encode(batch)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in config.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        // Protects an in-flight request from being killed the instant the app
        // is backgrounded.
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }

        session.dataTask(with: request) { [weak self] data, response, error in
            if task != .invalid {
                UIApplication.shared.endBackgroundTask(task)
            }
            guard let self else { return }
            self.serial.async {
                self.handle(
                    data: data, response: response, error: error,
                    batch: batch, startedAt: startedAt
                )
            }
        }.resume()
    }

    private func handle(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        batch: [GeoPointRow],
        startedAt: Date
    ) {
        let outcome: UploadOutcome
        if let error {
            outcome = .retry
            config.lastUpload = "network: \(error.localizedDescription)"
        } else if let http = response as? HTTPURLResponse {
            outcome = UploadPolicy.classify(http.statusCode)
            config.lastUpload = outcome == .success
                ? "ok (\(batch.count) points)"
                : "http \(http.statusCode)"
        } else {
            outcome = .retry
            config.lastUpload = "no response"
        }

        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
        // Body only on a non-2xx, and truncated: it is what turns "http 422"
        // into "points.bad_coordinates". A 2xx body is noise, and any body at
        // all is data from the server.
        let detail = outcome == .success
            ? ""
            : " " + String(
                (data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
                    .prefix(500)
            )
        GeoLogStore.shared?.write(
            atMillis: Int64(Date().timeIntervalSince1970 * 1000),
            level: outcome == .success ? "info" : "warning",
            event: "upload.result",
            message: "\(config.lastUpload) in \(elapsed)ms \(outcome)\(detail)"
        )

        switch outcome {
        case .success:
            queue?.drop(ids: batch.map(\.id))
            attempt = 0
            notBefore = nil
            sendNextBatch()

        // Stood down rather than deleted. The blocking this used to prevent is
        // real — the queue is read from the head, so a batch the backend never
        // accepts would be re-read forever — but the queue already bounds
        // itself by rows and by age, so nothing has to be thrown away.
        case .deferred:
            let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
            queue?.defer(
                ids: batch.map(\.id),
                untilMillis: nowMillis + UploadPolicy.deferWindowMillis
            )
            GeoLogStore.shared?.write(
                atMillis: nowMillis,
                level: "warning",
                event: "upload.deferred",
                message: "\(batch.count) points stood down for "
                    + "\(UploadPolicy.deferWindowMillis / 60_000)min"
            )
            attempt = 0
            notBefore = nil
            sendNextBatch()

        case .authFailed:
            config.authFailed = true
            draining = false
            // Nothing to back off from — uploading is halted until fresh
            // credentials arrive, and those clear the flag themselves.
            notBefore = nil
            GeoEventBus.emitStatus(GeoTracker.shared.statusMap())

        case .retry:
            let delay = UploadPolicy.backoffSeconds(attempt: attempt)
            attempt += 1
            draining = false
            notBefore = Date().addingTimeInterval(delay)
            serial.asyncAfter(deadline: .now() + delay) { [weak self] in
                // This is the attempt the backoff was waiting for, so it lifts
                // its own gate. Comparing wall-clock `Date` against a deadline
                // scheduled on a monotonic clock could otherwise miss by a
                // hair and skip the retry entirely.
                self?.notBefore = nil
                self?.drainIfNeeded(force: true)
            }
        }
    }
}
