package school.attractor.attractor_geo.upload

/** What to do with a batch after the backend answered. */
enum class UploadOutcome {
    /** Delete the points — they landed. */
    SUCCESS,

    /** Credentials are stale. Stop uploading, keep collecting. */
    AUTH_FAILED,

    /**
     * The backend refused this batch as it stands. Keep it, stand it down for
     * a while, and let everything behind it through.
     *
     * Was `POISONED`, and was deleted on sight. That reasoning — a permanently
     * rejected batch would otherwise retry forever and block every point
     * behind it — was right about the problem and wrong about the fix: the
     * queue already bounds itself by rows and by age, so nothing has to be
     * thrown away to keep it from growing. Standing the batch down solves the
     * blocking without the data loss.
     */
    DEFERRED,

    /** Transient. Keep the points and back off. */
    RETRY,
}

object UploadPolicy {
    fun classify(statusCode: Int): UploadOutcome = when {
        statusCode in 200..299 -> UploadOutcome.SUCCESS
        statusCode == 401 -> UploadOutcome.AUTH_FAILED
        statusCode == 408 || statusCode == 429 -> UploadOutcome.RETRY
        statusCode in 400..499 -> UploadOutcome.DEFERRED
        else -> UploadOutcome.RETRY
    }

    /**
     * The first retry delay. Growth is exponential from here, but WorkManager
     * owns the schedule on Android — see [UploadWorker.enqueueNow], which
     * feeds this to `setBackoffCriteria`. iOS runs its own retry loop and so
     * keeps its own backoff function.
     */
    const val BASE_BACKOFF_SECONDS = 30L

    /**
     * How long a refused batch stands down for.
     *
     * An hour, so a batch the backend will never accept costs one request an
     * hour until the queue's own ceilings evict it, while a backend that was
     * merely broken for a while is picked back up with nothing lost.
     */
    const val DEFER_WINDOW_MILLIS = 3_600_000L
}
