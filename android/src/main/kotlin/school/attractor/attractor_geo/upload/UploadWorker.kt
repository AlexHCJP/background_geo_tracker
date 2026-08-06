package school.attractor.attractor_geo.upload

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import school.attractor.attractor_geo.GeoConfigStore
import school.attractor.attractor_geo.GeoEventBus
import school.attractor.attractor_geo.GeoStatus
import school.attractor.attractor_geo.db.GeoDatabase
import school.attractor.attractor_geo.db.PointQueue

/**
 * Drains the queue. Runs under WorkManager so it survives process death and
 * gets retried by the system when there is no network.
 */
class UploadWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val config = GeoConfigStore(applicationContext)
        if (!config.isConfigured() || config.authFailed) {
            return@withContext Result.success()
        }

        val queue = PointQueue(GeoDatabase.open(applicationContext).points())

        while (true) {
            val batch = queue.oldest(config.batchSize)
            if (batch.isEmpty()) return@withContext Result.success()

            val request = Request.Builder()
                .url(config.baseUrl.trimEnd('/') + config.path)
                .post(
                    PointJson.encode(batch)
                        .toRequestBody("application/json".toMediaType()),
                )
                .apply {
                    config.headers.forEach { (name, value) ->
                        header(name, value)
                    }
                }
                .build()

            val outcome = try {
                http.newCall(request).execute().use {
                    UploadPolicy.classify(it.code)
                }
            } catch (_: IOException) {
                UploadOutcome.RETRY
            }

            when (outcome) {
                UploadOutcome.SUCCESS -> queue.drop(batch.map { it.id })

                // Dropping the batch is deliberate: a permanently rejected
                // batch would otherwise retry forever and block every point
                // behind it.
                UploadOutcome.POISONED -> queue.drop(batch.map { it.id })

                UploadOutcome.AUTH_FAILED -> {
                    config.authFailed = true
                    GeoEventBus.emitStatus(
                        GeoStatus.map(applicationContext, config, queue.count()),
                    )
                    return@withContext Result.success()
                }

                UploadOutcome.RETRY -> return@withContext Result.retry()
            }
        }

        // Unreachable: the loop only exits through an explicit return.
        @Suppress("UNREACHABLE_CODE")
        return@withContext Result.success()
    }

    companion object {
        private const val PERIODIC = "attractor_geo_upload_periodic"
        private const val ONE_SHOT = "attractor_geo_upload_now"

        /**
         * One client for every run. WorkManager builds a fresh worker per
         * execution, and a client per instance throws away the connection
         * pool that makes a batched upload cheap.
         */
        private val http by lazy { OkHttpClient() }

        private val networked = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()

        /**
         * WorkManager's floor for periodic work is 15 minutes, so the
         * configured interval can only raise it — this is the net, not the
         * schedule. What actually honours `uploadIntervalSeconds` is the
         * collector's own drain loop, and the batch-size trigger keeps
         * latency low between its ticks. This exists for the case neither
         * covers: the collector killed by the OS with points still queued.
         */
        fun schedule(context: Context, intervalSeconds: Int) {
            val minutes = maxOf(15L, intervalSeconds / 60L)
            val request = PeriodicWorkRequestBuilder<UploadWorker>(
                minutes,
                TimeUnit.MINUTES,
            ).setConstraints(networked).build()

            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                PERIODIC,
                ExistingPeriodicWorkPolicy.UPDATE,
                request,
            )
        }

        fun enqueueNow(context: Context) {
            val request = OneTimeWorkRequestBuilder<UploadWorker>()
                .setConstraints(networked)
                // `Result.retry()` hands the schedule to WorkManager, so the
                // retry policy has to be declared here or the default is used
                // and our own is dead code.
                .setBackoffCriteria(
                    BackoffPolicy.EXPONENTIAL,
                    UploadPolicy.BASE_BACKOFF_SECONDS,
                    TimeUnit.SECONDS,
                )
                .build()

            WorkManager.getInstance(context).enqueueUniqueWork(
                ONE_SHOT,
                ExistingWorkPolicy.KEEP,
                request,
            )
        }

        /**
         * Both, not just the periodic one. A one-shot enqueued moments before
         * the session ended is still sitting in WorkManager's queue, and it
         * would wake up afterwards and drain the queue using credentials the
         * app has already stopped trusting.
         */
        fun cancel(context: Context) {
            val manager = WorkManager.getInstance(context)
            manager.cancelUniqueWork(PERIODIC)
            manager.cancelUniqueWork(ONE_SHOT)
        }
    }
}
