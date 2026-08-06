import Foundation
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

    func startPeriodicDrain() {
        stopPeriodicDrain()
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
    }

    func stopPeriodicDrain() {
        timer?.cancel()
        timer = nil
    }

    /// `force` bypasses the batch-size threshold — used by the periodic timer
    /// so a half-full batch still goes out.
    func drainIfNeeded(force: Bool) {
        serial.async { [weak self] in
            guard let self, let queue = self.queue else { return }
            guard self.config.isConfigured, !self.config.authFailed else {
                return
            }
            guard !self.draining else { return }
            guard UploadPolicy.mayAttempt(
                now: Date(), notBefore: self.notBefore
            ) else { return }
            guard force || queue.count() >= self.config.batchSize else { return }
            self.draining = true
            self.sendNextBatch()
        }
    }

    private func sendNextBatch() {
        guard let queue else {
            draining = false
            return
        }

        let batch = queue.oldest(limit: config.batchSize)
        guard !batch.isEmpty else {
            draining = false
            attempt = 0
            return
        }

        guard let url = URL(
            string: config.baseUrl.trimmedTrailingSlash + config.path
        ) else {
            draining = false
            return
        }

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

        session.dataTask(with: request) { [weak self] _, response, error in
            if task != .invalid {
                UIApplication.shared.endBackgroundTask(task)
            }
            guard let self else { return }
            self.serial.async {
                self.handle(response: response, error: error, batch: batch)
            }
        }.resume()
    }

    private func handle(
        response: URLResponse?, error: Error?, batch: [GeoPointRow]
    ) {
        let outcome: UploadOutcome
        if error != nil {
            outcome = .retry
        } else if let http = response as? HTTPURLResponse {
            outcome = UploadPolicy.classify(http.statusCode)
        } else {
            outcome = .retry
        }

        switch outcome {
        case .success:
            queue?.drop(ids: batch.map(\.id))
            attempt = 0
            notBefore = nil
            sendNextBatch()

        // Dropping the batch is deliberate: a permanently rejected batch would
        // otherwise retry forever and block every point behind it.
        case .poisoned:
            queue?.drop(ids: batch.map(\.id))
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

private extension String {
    var trimmedTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
