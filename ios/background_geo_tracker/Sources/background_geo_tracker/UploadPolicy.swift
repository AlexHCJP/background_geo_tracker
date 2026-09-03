import Foundation

/// What to do with a batch after the backend answered.
enum UploadOutcome {
    /// Delete the points — they landed.
    case success

    /// Credentials are stale. Stop uploading, keep collecting.
    case authFailed

    /// The backend refused this batch as it stands. Keep it, stand it down
    /// for a while, and let everything behind it through.
    ///
    /// Was `poisoned`, and was deleted on sight. That reasoning — a
    /// permanently rejected batch would otherwise retry forever and block
    /// every point behind it — was right about the problem and wrong about
    /// the fix: the queue already bounds itself by rows and by age, so nothing
    /// has to be thrown away to keep it from growing.
    case deferred

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
        case 400...499: return .deferred
        default: return .retry
        }
    }

    /// How long a refused batch stands down for.
    ///
    /// An hour, so a batch the backend will never accept costs one request an
    /// hour until the queue's own ceilings evict it, while a backend that was
    /// merely broken for a while is picked back up with nothing lost.
    static let deferWindowMillis: Int64 = 3_600_000

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
