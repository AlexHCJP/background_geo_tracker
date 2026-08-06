package school.attractor.attractor_geo.upload

/** What to do with a batch after the backend answered. */
enum class UploadOutcome {
    /** Delete the points — they landed. */
    SUCCESS,

    /** Credentials are stale. Stop uploading, keep collecting. */
    AUTH_FAILED,

    /**
     * The backend will never accept this batch. Drop it, or it retries
     * forever and blocks every point behind it.
     */
    POISONED,

    /** Transient. Keep the points and back off. */
    RETRY,
}

object UploadPolicy {
    fun classify(statusCode: Int): UploadOutcome = when {
        statusCode in 200..299 -> UploadOutcome.SUCCESS
        statusCode == 401 -> UploadOutcome.AUTH_FAILED
        statusCode == 408 || statusCode == 429 -> UploadOutcome.RETRY
        statusCode in 400..499 -> UploadOutcome.POISONED
        else -> UploadOutcome.RETRY
    }

    /**
     * The first retry delay. Growth is exponential from here, but WorkManager
     * owns the schedule on Android — see [UploadWorker.enqueueNow], which
     * feeds this to `setBackoffCriteria`. iOS runs its own retry loop and so
     * keeps its own backoff function.
     */
    const val BASE_BACKOFF_SECONDS = 30L
}
