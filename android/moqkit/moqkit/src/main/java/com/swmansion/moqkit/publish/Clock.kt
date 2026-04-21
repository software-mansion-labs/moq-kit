package com.swmansion.moqkit.publish

import java.util.concurrent.atomic.AtomicLong

internal class Clock {
    private val epochUs = AtomicLong(-1L)

    fun timestampUs(presentationUs: Long): Long {
        if (epochUs.compareAndSet(-1L, presentationUs)) return 0L
        return maxOf(0L, presentationUs - epochUs.get())
    }

    fun reset() {
        epochUs.set(-1L)
    }
}
