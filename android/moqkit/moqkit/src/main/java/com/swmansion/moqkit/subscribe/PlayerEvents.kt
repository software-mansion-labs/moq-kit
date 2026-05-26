package com.swmansion.moqkit.subscribe

import java.time.Duration
import java.time.Instant

/**
 * Stable event names emitted by [Player.events].
 *
 * Events represent player lifecycle transitions. Periodic quality samples are exposed
 * through [Player.statsUpdates].
 */
enum class PlayerEventName(val value: String) {
    PLAYER_INIT("player.init"),
    PLAYER_DESTROY("player.destroy"),
    PLAYBACK_REQUEST("playback.request"),
    PLAYBACK_START("playback.start"),
    PLAYBACK_PAUSE("playback.pause"),
    PLAYBACK_RESUME("playback.resume"),
    PLAYBACK_END("playback.end"),
    TRACK_SUBSCRIBE_START("track.subscribe.start"),
    TRACK_READY("track.ready"),
    TRACK_PLAYING("track.playing"),
    TRACK_SUBSCRIBE_ERROR("track.subscribe.error"),
    TRACK_SUBSCRIBE_END("track.subscribe.end"),
    TRACK_SELECT("track.select"),
    TRACK_SWITCH("track.switch"),
    TRACK_STALL_START("track.stall.start"),
    TRACK_STALL_END("track.stall.end"),
    REBUFFER_START("rebuffer.start"),
    REBUFFER_END("rebuffer.end"),
    DECODE_ERROR("decode.error"),
}

/** Media kind carried by player events. */
enum class PlayerTrackKind(val value: String) {
    AUDIO("audio"),
    VIDEO("video"),
}

/** Session-level context shared by player lifecycle events. */
data class PlayerSessionEvent(
    val catalogPath: String,
    val targetBuffering: Duration,
    val videoTrackName: String?,
    val audioTrackName: String?,
)

/** Track reference shared by track lifecycle events. */
data class PlayerTrackEvent(
    val kind: PlayerTrackKind,
    val trackName: String? = null,
    val epoch: Long = 0L,
)

/** Selected-track state after a selection change. */
data class PlayerTrackSelectionEvent(
    val kind: PlayerTrackKind,
    val trackName: String?,
) {
    val isEnabled: Boolean
        get() = trackName != null
}

/** First accepted or decoded frame for a subscribed track. */
data class PlayerTrackReadyEvent(
    val track: PlayerTrackEvent,
    val sourceTimestampUs: Long,
    val targetBuffering: Duration,
    val keyframe: Boolean,
    val payloadBytes: Long,
)

/** First audible or visible playback for a subscribed track. */
data class PlayerTrackPlayingEvent(
    val track: PlayerTrackEvent,
    val sourceTimestampUs: Long,
    val targetBuffering: Duration,
    val output: PlayerTrackPlaybackOutput,
)

sealed class PlayerTrackPlaybackOutput {
    data class Audio(val output: PlayerAudioPlaybackOutput) : PlayerTrackPlaybackOutput()
    data class Video(val output: PlayerVideoPlaybackOutput) : PlayerTrackPlaybackOutput()
}

data class PlayerAudioPlaybackOutput(
    val timestampUs: Long,
    val hostTime: Long?,
)

data class PlayerVideoPlaybackOutput(
    val presentationTimeUs: Long,
    val clockTimeUs: Long,
    val buffer: Duration,
)

/** Error associated with a specific track. */
data class PlayerTrackErrorEvent(
    val track: PlayerTrackEvent,
    val message: String,
)

/** Playback end context. */
data class PlayerPlaybackEndEvent(
    val reason: String?,
)

/** Strongly typed payload for each player event. */
sealed class PlayerEventType {
    abstract val name: PlayerEventName

    data class PlayerInit(val session: PlayerSessionEvent) : PlayerEventType() {
        override val name: PlayerEventName = PlayerEventName.PLAYER_INIT
    }

    object PlayerDestroy : PlayerEventType() {
        override val name: PlayerEventName = PlayerEventName.PLAYER_DESTROY
    }

    data class PlaybackRequest(val session: PlayerSessionEvent) : PlayerEventType() {
        override val name: PlayerEventName = PlayerEventName.PLAYBACK_REQUEST
    }

    data class PlaybackStart(val playback: PlayerTrackPlayingEvent) : PlayerEventType() {
        override val name: PlayerEventName = PlayerEventName.PLAYBACK_START
    }

    data class PlaybackPause(val session: PlayerSessionEvent) : PlayerEventType() {
        override val name: PlayerEventName = PlayerEventName.PLAYBACK_PAUSE
    }

    data class PlaybackResume(val session: PlayerSessionEvent) : PlayerEventType() {
        override val name: PlayerEventName = PlayerEventName.PLAYBACK_RESUME
    }

    data class PlaybackEnd(val end: PlayerPlaybackEndEvent) : PlayerEventType() {
        override val name: PlayerEventName = PlayerEventName.PLAYBACK_END
    }

    data class TrackSubscribeStart(val track: PlayerTrackEvent) : PlayerEventType() {
        override val name: PlayerEventName = PlayerEventName.TRACK_SUBSCRIBE_START
    }

    data class TrackReady(val ready: PlayerTrackReadyEvent) : PlayerEventType() {
        override val name: PlayerEventName = PlayerEventName.TRACK_READY
    }

    data class TrackPlaying(val playing: PlayerTrackPlayingEvent) : PlayerEventType() {
        override val name: PlayerEventName = PlayerEventName.TRACK_PLAYING
    }

    data class TrackSubscribeError(val error: PlayerTrackErrorEvent) : PlayerEventType() {
        override val name: PlayerEventName = PlayerEventName.TRACK_SUBSCRIBE_ERROR
    }

    data class TrackSubscribeEnd(val track: PlayerTrackEvent) : PlayerEventType() {
        override val name: PlayerEventName = PlayerEventName.TRACK_SUBSCRIBE_END
    }

    data class TrackSelect(val selection: PlayerTrackSelectionEvent) : PlayerEventType() {
        override val name: PlayerEventName = PlayerEventName.TRACK_SELECT
    }

    data class TrackSwitch(val track: PlayerTrackEvent) : PlayerEventType() {
        override val name: PlayerEventName = PlayerEventName.TRACK_SWITCH
    }

    data class TrackStallStart(val track: PlayerTrackEvent) : PlayerEventType() {
        override val name: PlayerEventName = PlayerEventName.TRACK_STALL_START
    }

    data class TrackStallEnd(val track: PlayerTrackEvent) : PlayerEventType() {
        override val name: PlayerEventName = PlayerEventName.TRACK_STALL_END
    }

    data class RebufferStart(val track: PlayerTrackEvent) : PlayerEventType() {
        override val name: PlayerEventName = PlayerEventName.REBUFFER_START
    }

    data class RebufferEnd(val track: PlayerTrackEvent) : PlayerEventType() {
        override val name: PlayerEventName = PlayerEventName.REBUFFER_END
    }

    data class DecodeError(val error: PlayerTrackErrorEvent) : PlayerEventType() {
        override val name: PlayerEventName = PlayerEventName.DECODE_ERROR
    }
}

/** A player event envelope. */
data class PlayerEvent(
    val type: PlayerEventType,
    val timestamp: Instant,
    val sequence: Long,
) {
    val name: PlayerEventName
        get() = type.name
}
