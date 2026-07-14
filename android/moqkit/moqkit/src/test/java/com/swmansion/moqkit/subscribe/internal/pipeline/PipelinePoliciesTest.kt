package com.swmansion.moqkit.subscribe.internal.pipeline

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class PipelinePoliciesTest {
    @Test
    fun defaultPoliciesNameTheExistingAndroidTuningValues() {
        assertEquals(500_000L, PipelinePolicies.timeline.maxGapUs)
        assertEquals(64L * 1024L * 1024L, PipelinePolicies.admission.maxBytes)
        assertEquals(2, PipelinePolicies.recovery.maxRecoveries)
        assertEquals(10_000_000_000L, PipelinePolicies.recovery.windowNanos)
        assertEquals(500_000L, PipelinePolicies.render.maxAheadUs)
        assertEquals(33_333L, PipelinePolicies.render.fallbackFrameDurationUs)
        assertEquals(20_000L, PipelinePolicies.clock.retargetToleranceUs)
        assertEquals(5_000_000L, PipelinePolicies.switch.keyframeTimeoutUs)
    }

    @Test
    fun invalidPolicyBoundsAreRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            AdmissionPolicy(maxBytes = 0, maxFrames = 1, maxDurationUs = 1)
        }
        assertThrows(IllegalArgumentException::class.java) {
            RecoveryPolicy(maxRecoveries = -1, windowNanos = 1)
        }
        assertThrows(IllegalArgumentException::class.java) {
            RenderPolicy(lateDropThresholdUs = -1)
        }
        assertThrows(IllegalArgumentException::class.java) {
            ClockPolicy(minRate = 1.01, maxRate = 1.05)
        }
        assertThrows(IllegalArgumentException::class.java) {
            ClockPolicy(minRate = 0.95, maxRate = Double.POSITIVE_INFINITY)
        }
    }
}
