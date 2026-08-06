import Foundation

/// What to do with a batch after the backend answered.
enum UploadOutcome {
    /// Delete the points — they landed.
    case success

    /// Credentials are stale. Stop uploading, keep collecting.
    case authFailed

    /// The backend will never accept this batch. Drop it, or it retries
    /// forever and blocks every point behind it.
    case poisoned

    /// Transient. Keep the points and back off.
    case retry
}

/// Must stay identical to the Kotlin `UploadPolicy`, or the two platforms
/// disagree about what a given status code means.
enum UploadPolicy {
    static func classify(_ statusCode: Int) -> UploadOutcome {
        switch statusCode {
        case 200...299: return .success
        case 401: return .authFailed
        case 408, 429: return .retry
        case 400...499: return .poisoned
        default: return .retry
        }
    }

    private static let baseBackoff: TimeInterval = 30
    private static let maxBackoff: TimeInterval = 3600
    private static let maxDoublings = 7

    /// Exponential backoff from 30 s, capped at an hour.
    static func backoffSeconds(attempt: Int) -> TimeInterval {
        let doublings = min(max(attempt, 0), maxDoublings)
        let delay = baseBackoff * pow(2, Double(doublings))
        return min(delay, maxBackoff)
    }

    /// Whether an attempt may go out now.
    ///
    /// The periodic drain fires on its own schedule and knows nothing about a
    /// backoff in progress, so without this a backend that is down gets hit
    /// every `uploadIntervalSeconds` regardless — the backoff computed above
    /// would only ever delay the retry that lost the race. `nil` means no
    /// attempt has failed yet.
    static func mayAttempt(now: Date, notBefore: Date?) -> Bool {
        guard let notBefore else { return true }
        return now >= notBefore
    }
}
