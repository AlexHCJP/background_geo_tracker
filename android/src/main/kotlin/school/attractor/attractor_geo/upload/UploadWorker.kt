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
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import school.attractor.attractor_geo.GeoConfigStore
import school.attractor.attractor_geo.GeoEventBus
import school.attractor.attractor_geo.GeoStatus
import school.attractor.attractor_geo.db.GeoDatabase
import school.attractor.attractor_geo.db.PointQueue
import school.attractor.attractor_geo.log.GeoLogDatabase

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
        val logs = GeoLogDatabase.open(applicationContext).store()

        // Every early return below ends the drain, and each of them is a
        // reason a queue can grow while the collector looks healthy.
        fun giveUp(reason: String): Result {
            config.lastUpload = reason
            logs.write(
                System.currentTimeMillis(), "warning", "upload.giveup", reason,
            )
            return Result.success()
        }
        // Each of these ends the drain, and each used to end it in silence. A
        // queue that grows while the collector reports itself healthy is the
        // symptom of every one of them, so the reason has to survive the
        // return — see `GeoTrackingStatus.lastUpload`.
        if (!config.isConfigured()) {
            return@withContext giveUp("not configured")
        }
        if (config.authFailed) {
            return@withContext giveUp("halted: credentials refused")
        }
        // An empty or malformed endpoint makes `url()` throw, and it throws
        // `IllegalArgumentException` — which the `IOException` catch below
        // does not cover, so the worker would die with nothing to show for it
        // while the collector went on filling a queue that can never be sent.
        val endpoint = config.url.toHttpUrlOrNull()
        if (endpoint == null) {
            return@withContext giveUp(
                if (config.url.isEmpty()) {
                    "no url — never configured"
                } else {
                    "bad url: ${config.url}"
                },
            )
        }

        val queue = PointQueue(GeoDatabase.open(applicationContext).points())

        while (true) {
            val batch = queue.oldest(config.batchSize, System.currentTimeMillis())
            if (batch.isEmpty()) return@withContext Result.success()

            val request = Request.Builder()
                .url(endpoint)
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

            val startedAt = System.currentTimeMillis()
            logs.write(
                startedAt, "info", "upload.attempt",
                "${batch.size} points → $endpoint",
            )

            val outcome = try {
                http.newCall(request).execute().use {
                    val classified = UploadPolicy.classify(it.code)
                    config.lastUpload = if (classified == UploadOutcome.SUCCESS) {
                        "ok (${batch.size} points)"
                    } else {
                        "http ${it.code}"
                    }
                    // Body only on a non-2xx, and truncated: it is what turns
                    // "http 422" into "points.bad_coordinates". A 2xx body is
                    // noise, and any body at all is data from the server.
                    val detail = if (classified == UploadOutcome.SUCCESS) {
                        ""
                    } else {
                        " " + (it.body?.string() ?: "").take(500)
                    }
                    logs.write(
                        System.currentTimeMillis(),
                        if (classified == UploadOutcome.SUCCESS) "info" else "warning",
                        "upload.result",
                        "http ${it.code} in " +
                            "${System.currentTimeMillis() - startedAt}ms " +
                            "${classified.name}$detail",
                    )
                    classified
                }
            } catch (e: IOException) {
                config.lastUpload = "network: ${e.message ?: "failed"}"
                logs.write(
                    System.currentTimeMillis(), "warning", "upload.result",
                    "network after ${System.currentTimeMillis() - startedAt}ms: " +
                        (e.message ?: "failed"),
                )
                UploadOutcome.RETRY
            }

            when (outcome) {
                UploadOutcome.SUCCESS -> queue.drop(batch.map { it.id })

                // Stood down rather than deleted. The blocking this used to
                // prevent is real — the queue is read from the head, so a
                // batch the backend never accepts would be re-read forever —
                // but the queue already bounds itself by rows and by age, so
                // nothing has to be thrown away to keep it from growing.
                UploadOutcome.DEFERRED -> {
                    val until = System.currentTimeMillis() +
                        UploadPolicy.DEFER_WINDOW_MILLIS
                    queue.defer(batch.map { it.id }, until)
                    logs.write(
                        System.currentTimeMillis(), "warning", "upload.deferred",
                        "${batch.size} points stood down for " +
                            "${UploadPolicy.DEFER_WINDOW_MILLIS / 60_000}min",
                    )
                }

                UploadOutcome.AUTH_FAILED -> {
                    config.authFailed = true
                    GeoEventBus.emitStatus(
                        GeoStatus.map(applicationContext, config, queue.count()),
                    )
                    return@withContext Result.success()
                }

                // Handed back to WorkManager only for as long as its schedule
                // is the better one. `enqueueNow` is unique work under KEEP,
                // so while a retry sits in the queue every other trigger —
                // the batch filling up, the collector's own sweep — is
                // dropped on the floor, and the exponential ladder becomes
                // the *only* way anything gets sent. Left uncapped it reaches
                // WorkManager's five-hour ceiling, so a queue that failed
                // once at 09:00 waits until the afternoon on a network that
                // came back at 09:01. Capped, the unique work clears and the
                // next sweep re-enqueues within `uploadIntervalSeconds`.
                UploadOutcome.RETRY -> return@withContext if (
                    runAttemptCount < MAX_RETRY_ATTEMPTS
                ) {
                    Result.retry()
                } else {
                    logs.write(
                        System.currentTimeMillis(), "warning", "upload.giveup",
                        "retries exhausted after $runAttemptCount attempts",
                    )
                    Result.success()
                }
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
         * How many times a run may hand itself back to WorkManager before the
         * schedule returns to the collector's sweep.
         *
         * Three, on the 30-second base below, tops the ladder out at about
         * two minutes — long enough to ride out the blip that a retry is for,
         * short enough that a longer outage is waited out by the sweep, which
         * re-enqueues on the same network constraint anyway.
         */
        private const val MAX_RETRY_ATTEMPTS = 3

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
