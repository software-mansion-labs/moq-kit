package com.swmansion.moqkit

import android.util.Log
import uniffi.moq.moqLogLevel

/**
 * Utility object for configuring the native MoQ transport layer.
 */
object MoQ {
    /**
     * Sets the native log level for the underlying Rust transport layer.
     *
     * @param level Log level string accepted by the Rust `tracing` crate:
     *   `"error"`, `"warn"`, `"info"`, `"debug"`, or `"trace"`.
     */
    fun setLogLevel(level: String) {
        try {
            moqLogLevel(level)
        } catch (e: Exception) {
            Log.w("MoQ", "Failed to set log level '$level': $e")
        }
    }
}
