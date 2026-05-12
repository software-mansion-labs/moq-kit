package com.swmansion.moqkit

import android.util.Log
import uniffi.moq.moqLogLevel

/**
 * Configures logs emitted by the native MoQ transport layer.
 *
 * Most apps do not need to call this. It is useful when diagnosing relay connection,
 * subscription, or publishing problems that are not visible from the Kotlin state flows.
 */
object NativeLogging {
    /**
     * Sets the native log level.
     *
     * Invalid values are ignored and logged with Android's [Log] API.
     *
     * @param level One of `"error"`, `"warn"`, `"info"`, `"debug"`, or `"trace"`.
     */
    fun setLogLevel(level: String) {
        try {
            moqLogLevel(level)
        } catch (e: Exception) {
            Log.w("NativeLogging", "Failed to set log level '$level': $e")
        }
    }
}
