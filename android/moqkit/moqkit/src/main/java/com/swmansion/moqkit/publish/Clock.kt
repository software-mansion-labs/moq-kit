package com.swmansion.moqkit.publish

import java.util.concurrent.atomic.AtomicLong

internal class Clock {
    private val epochUs = AtomicLong(-1L)

    fun start(epochUs: Long) {
        check(this.epochUs.compareAndSet(-1L, epochUs)) { "Clock already started" }
    }

    fun timestampUs(presentationUs: Long): Long {
        val epoch = epochUs.get()
        check(epoch >= 0L) { "Clock has not started" }
        return maxOf(0L, presentationUs - epoch)
    }

    fun reset() {
        epochUs.set(-1L)
    }
}
