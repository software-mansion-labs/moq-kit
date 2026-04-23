package com.swmansion.moqkit.subscribe

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.moq.Container
import uniffi.moq.MoqAudio
import uniffi.moq.MoqBroadcastConsumer
import uniffi.moq.MoqDimensions
import uniffi.moq.MoqVideo
import uniffi.moq.NoHandle

class PlayerTest {
    @Test
    fun playerRequiresAtLeastOneSelectedTrack() {
        val fixture = createFixture()

        assertThrows(IllegalStateException::class.java) {
            Player(
                catalog = fixture.catalog,
                videoTrackName = null,
                audioTrackName = null,
                parentScope = CoroutineScope(SupervisorJob()),
            )
        }

        assertFalse(fixture.owner.isClosed())
        fixture.broadcast.close()
        assertTrue(fixture.owner.isClosed())
    }

    @Test
    fun playerRejectsUnknownTrackNames() {
        val fixture = createFixture()

        assertThrows(IllegalArgumentException::class.java) {
            Player(
                catalog = fixture.catalog,
                videoTrackName = "video/unknown",
                audioTrackName = null,
                parentScope = CoroutineScope(SupervisorJob()),
            )
        }

        assertFalse(fixture.owner.isClosed())
        fixture.broadcast.close()
        assertTrue(fixture.owner.isClosed())
    }

    @Test
    fun playerSupportsVideoOnlyAndAudioOnlySelections() {
        val videoOnlyFixture = createFixture()
        val videoOnlyPlayer = Player(
            catalog = videoOnlyFixture.catalog,
            videoTrackName = "video/main",
            audioTrackName = null,
            parentScope = CoroutineScope(SupervisorJob()),
        )
        videoOnlyPlayer.close()
        videoOnlyFixture.broadcast.close()
        assertTrue(videoOnlyFixture.owner.isClosed())

        val audioOnlyFixture = createFixture()
        val audioOnlyPlayer = Player(
            catalog = audioOnlyFixture.catalog,
            videoTrackName = null,
            audioTrackName = "audio/main",
            parentScope = CoroutineScope(SupervisorJob()),
        )
        audioOnlyPlayer.close()
        audioOnlyFixture.broadcast.close()
        assertTrue(audioOnlyFixture.owner.isClosed())
    }

    @Test
    fun playerRetainsBroadcastUntilClosed() {
        val fixture = createFixture()
        val player = Player(
            catalog = fixture.catalog,
            videoTrackName = "video/main",
            audioTrackName = null,
            parentScope = CoroutineScope(SupervisorJob()),
        )

        fixture.broadcast.close()
        assertFalse(fixture.owner.isClosed())

        player.close()
        assertTrue(fixture.owner.isClosed())
    }

    @Test
    fun playerCloseIsIdempotent() {
        val fixture = createFixture()
        val player = Player(
            catalog = fixture.catalog,
            videoTrackName = "video/main",
            audioTrackName = null,
            parentScope = CoroutineScope(SupervisorJob()),
        )

        fixture.broadcast.close()
        assertFalse(fixture.owner.isClosed())

        player.close()
        player.close()

        assertTrue(fixture.owner.isClosed())
    }

    private fun createFixture(): Fixture {
        val owner = BroadcastOwner(
            path = "live/test",
            consumer = MoqBroadcastConsumer(NoHandle),
        )
        val videoRawConfig = MoqVideo(
            codec = "avc1",
            description = null,
            coded = MoqDimensions(1920u, 1080u),
            displayRatio = null,
            bitrate = 3_000_000uL,
            framerate = 30.0,
            container = Container.Legacy,
        )
        val audioRawConfig = MoqAudio(
            codec = "opus",
            description = null,
            sampleRate = 48_000u,
            channelCount = 2u,
            bitrate = 128_000uL,
            container = Container.Legacy,
        )
        val catalog = Catalog(
            path = "live/test",
            videoTracks = listOf(
                VideoTrackInfo(
                    name = "video/main",
                    config = VideoTrackConfig(
                        codec = "avc1",
                        coded = VideoSize(1920u, 1080u),
                        displayRatio = null,
                        bitrate = 3_000_000uL,
                        framerate = 30.0,
                    ),
                    rawConfig = videoRawConfig,
                ),
            ),
            audioTracks = listOf(
                AudioTrackInfo(
                    name = "audio/main",
                    config = AudioTrackConfig(
                        codec = "opus",
                        sampleRate = 48_000u,
                        channelCount = 2u,
                        bitrate = 128_000uL,
                    ),
                    rawConfig = audioRawConfig,
                ),
            ),
            owner = owner,
        )
        return Fixture(
            owner = owner,
            broadcast = Broadcast(path = "live/test", owner = owner),
            catalog = catalog,
        )
    }

    private data class Fixture(
        val owner: BroadcastOwner,
        val broadcast: Broadcast,
        val catalog: Catalog,
    )
}
