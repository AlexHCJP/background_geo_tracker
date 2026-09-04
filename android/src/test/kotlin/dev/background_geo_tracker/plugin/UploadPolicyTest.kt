package dev.background_geo_tracker.plugin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import dev.background_geo_tracker.plugin.upload.UploadOutcome
import dev.background_geo_tracker.plugin.upload.UploadPolicy

class UploadPolicyTest {
    @Test
    fun `2xx succeeds`() {
        assertEquals(UploadOutcome.SUCCESS, UploadPolicy.classify(200))
        assertEquals(UploadOutcome.SUCCESS, UploadPolicy.classify(201))
        assertEquals(UploadOutcome.SUCCESS, UploadPolicy.classify(204))
    }

    @Test
    fun `401 halts uploading`() {
        assertEquals(UploadOutcome.AUTH_FAILED, UploadPolicy.classify(401))
    }

    @Test
    fun `timeout and rate limit are retried`() {
        assertEquals(UploadOutcome.RETRY, UploadPolicy.classify(408))
        assertEquals(UploadOutcome.RETRY, UploadPolicy.classify(429))
    }

    @Test
    fun `other 4xx are deferred rather than dropped`() {
        // Used to be POISONED, which deleted the batch. At batchSize 50 that
        // meant one bad point taking forty-nine good ones with it, and the
        // only trace was a line in the status.
        assertEquals(UploadOutcome.DEFERRED, UploadPolicy.classify(400))
        assertEquals(UploadOutcome.DEFERRED, UploadPolicy.classify(403))
        assertEquals(UploadOutcome.DEFERRED, UploadPolicy.classify(422))
    }

    @Test
    fun `the defer window is long enough to be worth waiting out`() {
        // A permanently rejected batch costs one request per window until the
        // queue's own ceilings evict it, so the window is what bounds that.
        assertTrue(UploadPolicy.DEFER_WINDOW_MILLIS >= 60_000L)
    }

    @Test
    fun `5xx is retried`() {
        assertEquals(UploadOutcome.RETRY, UploadPolicy.classify(500))
        assertEquals(UploadOutcome.RETRY, UploadPolicy.classify(503))
    }

    @Test
    fun `base backoff is at least WorkManager's floor`() {
        // WorkManager rejects anything under 10 s, silently clamping it.
        assertTrue(UploadPolicy.BASE_BACKOFF_SECONDS >= 10L)
        assertEquals(30L, UploadPolicy.BASE_BACKOFF_SECONDS)
    }
}
