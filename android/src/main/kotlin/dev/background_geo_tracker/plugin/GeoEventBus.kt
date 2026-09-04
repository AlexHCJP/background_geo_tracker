package dev.background_geo_tracker.plugin

import android.os.Handler
import android.os.Looper

/**
 * Carries points and status from the service to whichever plugin instance is
 * currently attached. When no engine is attached the events are simply
 * dropped — collection and upload do not depend on anyone listening.
 */
object GeoEventBus {
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    var onPoint: ((Map<String, Any?>) -> Unit)? = null

    @Volatile
    var onStatus: ((Map<String, Any?>) -> Unit)? = null

    fun emitPoint(point: Map<String, Any?>) {
        val sink = onPoint ?: return
        main.post { sink(point) }
    }

    fun emitStatus(status: Map<String, Any?>) {
        val sink = onStatus ?: return
        main.post { sink(status) }
    }
}
