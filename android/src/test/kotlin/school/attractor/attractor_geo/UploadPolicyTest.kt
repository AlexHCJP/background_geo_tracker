package school.attractor.attractor_geo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import school.attractor.attractor_geo.upload.UploadOutcome
import school.attractor.attractor_geo.upload.UploadPolicy

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
    fun `other 4xx are poisoned so they cannot wedge the queue`() {
        assertEquals(UploadOutcome.POISONED, UploadPolicy.classify(400))
        assertEquals(UploadOutcome.POISONED, UploadPolicy.classify(403))
        assertEquals(UploadOutcome.POISONED, UploadPolicy.classify(422))
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
