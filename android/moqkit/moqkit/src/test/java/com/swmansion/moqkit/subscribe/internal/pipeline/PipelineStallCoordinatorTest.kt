package com.swmansion.moqkit.subscribe.internal.pipeline

import com.swmansion.moqkit.subscribe.PipelineContext
import com.swmansion.moqkit.subscribe.PipelineEvent
import com.swmansion.moqkit.subscribe.PipelineMediaKind
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PipelineStallCoordinatorTest {
    @Test
    fun busEventsDriveAttributedStallsAndTransportCloseRemovesTrack() {
        val bus = PipelineBus(capacity = 8)
        val time = FakeTimeSource(0)
        val coordinator = PipelineStallCoordinator(
            bus = bus,
            scope = CoroutineScope(SupervisorJob()),
            policy = StallPolicy(
                arrivalGapUs = 1_000,
                decodeProgressUs = 1_000,
                renderProgressUs = 1_000,
                stallDebounceUs = 100,
            ),
            timeSource = time,
        )
        val observed = mutableListOf<PipelineEvent>()
        val observation = bus.observe { observed += it }
        val context = PipelineContext("video/main", PipelineMediaKind.VIDEO, 0)

        bus.emit(PipelineEvent.FrameArrived(context, 0, null, null, 1))
        time.advance(1_050_000)
        coordinator.evaluate()
        time.advance(100_000)
        coordinator.evaluate()

        assertEquals(1, observed.filterIsInstance<PipelineEvent.StallStarted>().size)

        bus.emit(PipelineEvent.TransportClosed(context, error = null))
        time.advance(1_000_000)
        coordinator.evaluate()
        assertTrue(observed.filterIsInstance<PipelineEvent.StallStarted>().size == 1)

        observation.close()
        coordinator.close()
    }
}
