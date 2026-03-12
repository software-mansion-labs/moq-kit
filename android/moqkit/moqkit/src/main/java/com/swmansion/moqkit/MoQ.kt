package com.swmansion.moqkit

import android.util.Log
import uniffi.moq.moqLogLevel

object MoQ {
    fun setLogLevel(level: String) {
        try {
            moqLogLevel(level)
        } catch (e: Exception) {
            Log.w("MoQ", "Failed to set log level '$level': $e")
        }
    }
}
