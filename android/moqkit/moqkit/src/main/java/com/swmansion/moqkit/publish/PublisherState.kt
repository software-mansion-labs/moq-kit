package com.swmansion.moqkit.publish

/**
 * Lifecycle state for a [Publisher].
 */
sealed class PublisherState {
    /** Tracks can still be added and publishing has not started. */
    object Idle : PublisherState()

    /** At least one track is actively publishing or starting. */
    object Publishing : PublisherState()

    /** Publishing has ended and this publisher should not be reused. */
    object Stopped : PublisherState()

    /**
     * Publishing failed.
     *
     * @property message Human-readable error description.
     */
    data class Error(val message: String) : PublisherState()
}

/**
 * Track-level publishing events emitted by [Publisher.events].
 */
sealed class PublisherEvent {
    /**
     * A track became active.
     *
     * @property name Track name passed to `addVideoTrack`, `addAudioTrack`, or `addDataTrack`.
     */
    data class TrackStarted(val name: String) : PublisherEvent()

    /**
     * A track stopped publishing.
     *
     * @property name Track name.
     */
    data class TrackStopped(val name: String) : PublisherEvent()

    /**
     * A track failed while starting or publishing.
     *
     * @property name Track name.
     * @property message Human-readable error description.
     */
    data class TrackError(val name: String, val message: String) : PublisherEvent()
}

/** Lifecycle state for an individual [PublishedTrack]. */
enum class PublishedTrackState {
    /** The publisher has not started this track yet. */
    Idle,

    /** The track is connecting its source and encoder. */
    Starting,

    /** The track is publishing. */
    Active,

    /** The track has stopped. */
    Stopped,
}
