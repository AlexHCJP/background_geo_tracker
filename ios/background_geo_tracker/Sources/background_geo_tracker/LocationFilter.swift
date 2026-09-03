import Foundation

/// Decides which fixes are real and where the real ones actually are.
///
/// Must stay behaviourally identical to the Kotlin `LocationFilter`, for the
/// same reason `UploadPolicy` must: a point accepted on one platform and
/// rejected on the other is a difference nobody can see until two phones
/// standing side by side disagree about where they are.
///
/// Stateful and session-scoped — it remembers the last accepted fix and the
/// smoother's running estimate. One instance per collector, `reset()` when a
/// session opens.
final class LocationFilter {
    /// Why a fix was turned away, or that it was kept.
    enum Verdict: Equatable {
        /// Keep it — at these coordinates, which may not be the ones offered.
        case accept(lat: Double, lon: Double, accuracy: Double)

        /// Drop it. The string is for logs, never for control flow.
        case reject(String)
    }

    private let accuracyThresholdMeters: Double
    private let minDisplacementMeters: Double
    private let maxImpliedSpeedMps: Double
    private let kalmanProcessNoiseMps: Double

    init(
        accuracyThresholdMeters: Double,
        minDisplacementMeters: Double,
        maxImpliedSpeedMps: Double,
        kalmanProcessNoiseMps: Double
    ) {
        self.accuracyThresholdMeters = accuracyThresholdMeters
        self.minDisplacementMeters = minDisplacementMeters
        self.maxImpliedSpeedMps = maxImpliedSpeedMps
        self.kalmanProcessNoiseMps = kalmanProcessNoiseMps
    }

    /// Where the last accepted fix was *observed*, not where it was smoothed to.
    private var lastLat: Double?
    private var lastLon: Double?
    private var lastMillis: Int64 = 0

    /// The smoother's running estimate, and how far off it might be.
    private var estimateLat: Double = 0
    private var estimateLon: Double = 0

    /// Positional variance in square metres. Negative means the smoother has
    /// never run, which is how the first fix of a session is taken at face
    /// value instead of being averaged against nothing.
    private var variance: Double = -1

    /// Forgets the session. A new one must not be pulled toward the old one.
    func reset() {
        lastLat = nil
        lastLon = nil
        lastMillis = 0
        estimateLat = 0
        estimateLon = 0
        variance = -1
    }

    /// Runs the three rejections, then smooths whatever survives.
    ///
    /// The order is not arbitrary. The cheap self-refuting checks come first
    /// so a garbage fix never reaches the smoother, because the smoother has
    /// no way to reject anything — handed a fix from 5 km away it does not
    /// discard it, it drags the estimate a good part of the way there.
    func apply(
        lat: Double,
        lon: Double,
        accuracy: Double,
        recordedAtMillis: Int64
    ) -> Verdict {
        if accuracy > accuracyThresholdMeters {
            return .reject("accuracy \(Int(accuracy))m")
        }

        // Elapsed time comes from the fixes themselves rather than the clock,
        // so a fix judged late is judged on when it actually happened.
        let elapsedSeconds = Double(abs(recordedAtMillis - lastMillis)) / 1000

        if let previousLat = lastLat, let previousLon = lastLon {
            let moved = Distance.meters(previousLat, previousLon, lat, lon)

            if moved < minDisplacementMeters {
                return .reject("stationary \(Int(moved))m")
            }

            if elapsedSeconds > 0 {
                let impliedSpeed = moved / elapsedSeconds
                if impliedSpeed > maxImpliedSpeedMps {
                    return .reject("implied \(Int(impliedSpeed))m/s")
                }
            }
        }

        let accepted = smooth(
            lat: lat,
            lon: lon,
            accuracy: accuracy,
            elapsedSeconds: elapsedSeconds
        )

        // Deliberately the *raw* position, not the smoothed one. The next
        // fix's displacement and speed have to be measured against where the
        // device was observed to be, or the smoother's own lag starts feeding
        // the rejections and a genuine sprint begins to read as a teleport.
        lastLat = lat
        lastLon = lon
        lastMillis = recordedAtMillis

        return accepted
    }

    /// A constant-position Kalman filter over latitude and longitude.
    ///
    /// One dimension, no matrices: with no velocity term the state is just the
    /// position and its variance, and the whole update is four lines. What it
    /// buys is that each fix moves the estimate in proportion to how much that
    /// fix claims to be worth — a 10 m fix pulls hard, a 90 m fix barely at
    /// all — instead of the queue taking every claim at face value.
    private func smooth(
        lat: Double,
        lon: Double,
        accuracy: Double,
        elapsedSeconds: Double
    ) -> Verdict {
        // An accuracy of zero would make the gain 1 and the variance 0: that
        // fix would be believed absolutely and every fix after it ignored.
        let claimed = max(accuracy, 1)
        let measurementVariance = claimed * claimed

        if variance < 0 {
            estimateLat = lat
            estimateLon = lon
            variance = measurementVariance
            return .accept(lat: lat, lon: lon, accuracy: accuracy)
        }

        // Uncertainty grows with time, because the device may have moved while
        // nothing was being observed.
        if elapsedSeconds > 0 {
            variance += elapsedSeconds
                * kalmanProcessNoiseMps * kalmanProcessNoiseMps
        }

        let gain = variance / (variance + measurementVariance)
        estimateLat += gain * (lat - estimateLat)
        estimateLon += gain * (lon - estimateLon)
        variance *= (1 - gain)

        // Reported accuracy follows the estimate rather than the raw fix, so
        // the number keeps meaning what it meant: how far off this coordinate
        // might be. Smoothing genuinely reduces that, and reporting the raw
        // claim instead would overstate the error of a position the backend
        // stores and shows to other people.
        return .accept(
            lat: estimateLat, lon: estimateLon, accuracy: variance.squareRoot()
        )
    }
}
