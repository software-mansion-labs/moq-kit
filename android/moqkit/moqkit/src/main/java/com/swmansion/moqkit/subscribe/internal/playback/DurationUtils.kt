package com.swmansion.moqkit.subscribe.internal.playback

import java.time.Duration
import kotlin.math.roundToLong

internal fun Duration.toMillisecondsLongClamped(): Long {
    if (isNegative) return 0L
    return try {
        toMillis().coerceAtLeast(0L)
    } catch (_: ArithmeticException) {
        Long.MAX_VALUE
    }
}

internal fun Duration.toMillisecondsIntClamped(): Int =
    toMillisecondsLongClamped().coerceAtMost(Int.MAX_VALUE.toLong()).toInt()

internal fun Duration.toMicrosecondsLongClamped(): Long {
    if (isNegative) return 0L
    val secondsUs = try {
        Math.multiplyExact(seconds, 1_000_000L)
    } catch (_: ArithmeticException) {
        return Long.MAX_VALUE
    }
    val total = try {
        Math.addExact(secondsUs, nano.toLong() / 1_000L)
    } catch (_: ArithmeticException) {
        return Long.MAX_VALUE
    }
    return total.coerceAtLeast(0L)
}

internal fun durationFromMilliseconds(ms: Double?): Duration? {
    val value = ms ?: return null
    if (!value.isFinite() || value < 0.0) return null
    return Duration.ofNanos((value * 1_000_000.0).roundToLong())
}

internal fun durationFromNanoseconds(ns: Long): Duration =
    Duration.ofNanos(ns.coerceAtLeast(0L))

internal fun durationFromMicroseconds(us: Long): Duration =
    try {
        Duration.ofNanos(Math.multiplyExact(us.coerceAtLeast(0L), 1_000L))
    } catch (_: ArithmeticException) {
        Duration.ofNanos(Long.MAX_VALUE)
    }
