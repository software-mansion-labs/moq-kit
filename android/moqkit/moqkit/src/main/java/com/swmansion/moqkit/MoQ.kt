package com.swmansion.moqkit

import uniffi.moq.moqLogLevel

object MoQ {
    fun setLogLevel(level: String) = moqLogLevel(level)
}
